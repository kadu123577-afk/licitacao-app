-- ════════════════════════════════════════════════════════
--  LICITE.AI — BANCO DE DADOS SUPABASE
--  Execute no SQL Editor do Supabase
--  https://supabase.com/dashboard/project/oputbtpimowgxpsmfamn/sql
-- ════════════════════════════════════════════════════════

-- 1. PREFEITURAS (multi-tenant — cada prefeitura é isolada)
CREATE TABLE IF NOT EXISTS prefeituras (
  id              UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  nome            TEXT NOT NULL,
  municipio       TEXT NOT NULL,
  uf              CHAR(2) NOT NULL DEFAULT 'GO',
  cnpj            TEXT,
  logo_url        TEXT,
  ativo           BOOLEAN DEFAULT true,
  plano           TEXT DEFAULT 'basico', -- basico | profissional | municipal
  validade        DATE,
  formato_protocolo TEXT DEFAULT '0001/AAAA', -- padrão do nº de protocolo
  criado_em       TIMESTAMPTZ DEFAULT NOW()
);

-- 2. USUÁRIOS (vinculados à prefeitura + perfil por setor)
-- Nota: a tabela 'usuarios' já existe no schema de auth do Supabase
-- Aqui criamos a extensão com dados extras
CREATE TABLE IF NOT EXISTS usuarios (
  id              UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  prefeitura_id   UUID REFERENCES prefeituras(id),
  nome            TEXT NOT NULL,
  email           TEXT NOT NULL,
  perfil          TEXT NOT NULL DEFAULT 'requisitante',
  -- perfis: admin | requisitante | protocolo | compras | contabilidade | gestor | licitacao | juridico
  setor           TEXT,
  ativo           BOOLEAN DEFAULT true,
  role            TEXT DEFAULT 'usuario', -- usuario | admin
  organizacao_id  UUID, -- compatibilidade com licit.ai
  criado_em       TIMESTAMPTZ DEFAULT NOW()
);

-- 3. PROCESSOS LICITATÓRIOS
CREATE TABLE IF NOT EXISTS processos (
  id                  UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  prefeitura_id       UUID REFERENCES prefeituras(id) NOT NULL,
  numero_protocolo    TEXT NOT NULL,
  tipo_contratacao    TEXT NOT NULL,
  -- tipos: aquisicao_bens | servicos_comuns | obras_engenharia | locacao_maquinas | dispensa | inexigibilidade
  objeto              TEXT NOT NULL,
  setor_requisitante  TEXT NOT NULL,
  etapa_atual         INT NOT NULL DEFAULT 1,
  status              TEXT NOT NULL DEFAULT 'em_andamento',
  -- status: rascunho | em_andamento | devolvido | suspenso | concluido
  valor_estimado      NUMERIC(14,2),
  criado_por          UUID REFERENCES usuarios(id),
  atualizado_em       TIMESTAMPTZ DEFAULT NOW(),
  criado_em           TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(prefeitura_id, numero_protocolo)
);

-- 4. DOCUMENTOS (um por tipo por processo, versionado)
CREATE TABLE IF NOT EXISTS documentos (
  id              UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  processo_id     UUID REFERENCES processos(id) ON DELETE CASCADE NOT NULL,
  tipo            TEXT NOT NULL,
  -- tipos: DFD | ETP | MAPA_RISCO | TR | PP | DO | AUTH | MINUTA | PARECER | EDITAL | PUBLICACAO
  dados           JSONB NOT NULL DEFAULT '{}',
  versao          INT NOT NULL DEFAULT 1,
  status          TEXT NOT NULL DEFAULT 'rascunho',
  -- status: rascunho | enviado | aprovado | rejeitado
  arquivos        JSONB DEFAULT '[]', -- links de anexos no Storage
  criado_por      UUID REFERENCES usuarios(id),
  criado_em       TIMESTAMPTZ DEFAULT NOW(),
  atualizado_em   TIMESTAMPTZ DEFAULT NOW()
);

-- 5. MOVIMENTAÇÕES (histórico imutável — NUNCA deletar)
CREATE TABLE IF NOT EXISTS movimentacoes (
  id              UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  processo_id     UUID REFERENCES processos(id) ON DELETE CASCADE NOT NULL,
  documento_id    UUID REFERENCES documentos(id),
  de_etapa        INT,
  para_etapa      INT,
  acao            TEXT NOT NULL,
  -- ações: criacao | avanco | devolucao | aprovacao | rejeicao | suspensao
  observacao      TEXT,
  criado_por      UUID REFERENCES usuarios(id),
  criado_em       TIMESTAMPTZ DEFAULT NOW()
);

-- 6. NOTIFICAÇÕES
CREATE TABLE IF NOT EXISTS notificacoes (
  id              UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  usuario_id      UUID REFERENCES usuarios(id) ON DELETE CASCADE NOT NULL,
  processo_id     UUID REFERENCES processos(id) ON DELETE CASCADE,
  tipo            TEXT NOT NULL,
  -- tipos: nova_etapa | devolucao | aprovacao | prazo_alerta
  mensagem        TEXT NOT NULL,
  lida            BOOLEAN DEFAULT false,
  criado_em       TIMESTAMPTZ DEFAULT NOW()
);

-- ════════════════════════════════════════════════════════
--  ÍNDICES (performance)
-- ════════════════════════════════════════════════════════
CREATE INDEX IF NOT EXISTS idx_processos_prefeitura ON processos(prefeitura_id);
CREATE INDEX IF NOT EXISTS idx_processos_status ON processos(status);
CREATE INDEX IF NOT EXISTS idx_documentos_processo ON documentos(processo_id);
CREATE INDEX IF NOT EXISTS idx_movimentacoes_processo ON movimentacoes(processo_id);
CREATE INDEX IF NOT EXISTS idx_notificacoes_usuario ON notificacoes(usuario_id, lida);
CREATE INDEX IF NOT EXISTS idx_usuarios_prefeitura ON usuarios(prefeitura_id);

-- ════════════════════════════════════════════════════════
--  RLS — Row Level Security (isolamento por prefeitura)
-- ════════════════════════════════════════════════════════
ALTER TABLE prefeituras   ENABLE ROW LEVEL SECURITY;
ALTER TABLE usuarios      ENABLE ROW LEVEL SECURITY;
ALTER TABLE processos     ENABLE ROW LEVEL SECURITY;
ALTER TABLE documentos    ENABLE ROW LEVEL SECURITY;
ALTER TABLE movimentacoes ENABLE ROW LEVEL SECURITY;
ALTER TABLE notificacoes  ENABLE ROW LEVEL SECURITY;

-- Usuários veem apenas sua própria prefeitura
CREATE POLICY "usuarios_propria_prefeitura" ON usuarios
  FOR ALL USING (
    prefeitura_id = (SELECT prefeitura_id FROM usuarios WHERE id = auth.uid())
    OR id = auth.uid()
  );

-- Processos: apenas da mesma prefeitura
CREATE POLICY "processos_mesma_prefeitura" ON processos
  FOR ALL USING (
    prefeitura_id = (SELECT prefeitura_id FROM usuarios WHERE id = auth.uid())
  );

-- Documentos: via processo da mesma prefeitura
CREATE POLICY "documentos_mesma_prefeitura" ON documentos
  FOR ALL USING (
    processo_id IN (
      SELECT id FROM processos
      WHERE prefeitura_id = (SELECT prefeitura_id FROM usuarios WHERE id = auth.uid())
    )
  );

-- Movimentações: via processo da mesma prefeitura
CREATE POLICY "movimentacoes_mesma_prefeitura" ON movimentacoes
  FOR ALL USING (
    processo_id IN (
      SELECT id FROM processos
      WHERE prefeitura_id = (SELECT prefeitura_id FROM usuarios WHERE id = auth.uid())
    )
  );

-- Notificações: apenas do próprio usuário
CREATE POLICY "notificacoes_proprio_usuario" ON notificacoes
  FOR ALL USING (usuario_id = auth.uid());

-- ════════════════════════════════════════════════════════
--  DADOS INICIAIS — Prefeitura de teste + Usuário admin
-- ════════════════════════════════════════════════════════

-- Inserir prefeitura de teste
INSERT INTO prefeituras (id, nome, municipio, uf, cnpj, ativo, plano)
VALUES (
  'a1b2c3d4-e5f6-7890-abcd-ef1234567890',
  'Prefeitura Municipal de Teste',
  'Goiânia',
  'GO',
  '00.000.000/0001-00',
  true,
  'profissional'
) ON CONFLICT DO NOTHING;

-- Vincular usuário zeus@adm.com à prefeitura de teste
-- (Execute após criar o usuário no Supabase Auth)
-- UPDATE usuarios
-- SET prefeitura_id = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890',
--     perfil = 'admin',
--     nome = 'Administrador Licite',
--     setor = 'Administração',
--     role = 'admin'
-- WHERE email = 'zeus@adm.com';

-- ════════════════════════════════════════════════════════
--  FUNÇÃO: atualizar atualizado_em automaticamente
-- ════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION update_atualizado_em()
RETURNS TRIGGER AS $$
BEGIN
  NEW.atualizado_em = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_processos_atualizado
  BEFORE UPDATE ON processos
  FOR EACH ROW EXECUTE FUNCTION update_atualizado_em();

CREATE TRIGGER trigger_documentos_atualizado
  BEFORE UPDATE ON documentos
  FOR EACH ROW EXECUTE FUNCTION update_atualizado_em();
