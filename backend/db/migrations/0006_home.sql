-- phase: expand
-- Home messaging projections (plans/cmux-next/home-messaging.md section 7). Written only by
-- ConversationDO outbox drains (projection.ts); the DOs stay the single writers. Every row
-- carries the (source_stream, source_seq) of the owner event that produced it, and upserts
-- never move a row backwards. No row holds a raw address, an invite secret or a token hash:
-- address_id is the HMAC id (HOME_ADDRESS_KEY) of the normalized address.

CREATE EXTENSION IF NOT EXISTS pg_trgm;    -- substring and CJK search (body ILIKE)
CREATE EXTENSION IF NOT EXISTS btree_gin;  -- conversation_id inside the GIN indexes

CREATE TABLE home_conversations (
  id                 text PRIMARY KEY,
  kind               text NOT NULL CHECK (kind IN ('chief', 'dm', 'group')),
  team_id            text,
  title              text,
  created_by         text,
  created_at         timestamptz NOT NULL,
  last_seq           bigint NOT NULL,
  last_at            timestamptz NOT NULL,
  participant_count  integer NOT NULL,
  state              text NOT NULL CHECK (state IN ('active', 'archived')),
  source_stream      text NOT NULL,
  source_seq         bigint NOT NULL,
  updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX home_conversations_team ON home_conversations (team_id, last_at DESC) WHERE team_id IS NOT NULL;

-- Membership is the search permission: one row per (conversation, participant).
CREATE TABLE home_participants (
  conversation_id   text NOT NULL,
  participant_id    text NOT NULL,
  kind              text NOT NULL CHECK (kind IN ('human', 'agent', 'address')),
  visible_from_seq  bigint NOT NULL DEFAULT 0,
  joined_at         timestamptz NOT NULL,
  left_at           timestamptz,
  source_stream     text NOT NULL,
  source_seq        bigint NOT NULL,
  updated_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (conversation_id, participant_id)
);
CREATE INDEX home_participants_member ON home_participants (participant_id, conversation_id) WHERE left_at IS NULL;

-- Search rows, hash-partitioned by conversation (64 partitions, fixed forever: the
-- partition count is part of the key layout).
CREATE TABLE home_message_search (
  conversation_id  text NOT NULL,
  seq              bigint NOT NULL,
  message_id       text NOT NULL,
  author_id        text NOT NULL,
  author_kind      text NOT NULL CHECK (author_kind IN ('human', 'agent')),
  created_at       timestamptz NOT NULL,
  edited_at        timestamptz,
  body             text NOT NULL,
  tsv              tsvector GENERATED ALWAYS AS (to_tsvector('simple', body)) STORED,
  source_stream    text NOT NULL,
  source_seq       bigint NOT NULL,
  PRIMARY KEY (conversation_id, seq)
) PARTITION BY HASH (conversation_id);
CREATE TABLE home_message_search_p00 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 0);
CREATE TABLE home_message_search_p01 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 1);
CREATE TABLE home_message_search_p02 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 2);
CREATE TABLE home_message_search_p03 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 3);
CREATE TABLE home_message_search_p04 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 4);
CREATE TABLE home_message_search_p05 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 5);
CREATE TABLE home_message_search_p06 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 6);
CREATE TABLE home_message_search_p07 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 7);
CREATE TABLE home_message_search_p08 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 8);
CREATE TABLE home_message_search_p09 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 9);
CREATE TABLE home_message_search_p10 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 10);
CREATE TABLE home_message_search_p11 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 11);
CREATE TABLE home_message_search_p12 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 12);
CREATE TABLE home_message_search_p13 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 13);
CREATE TABLE home_message_search_p14 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 14);
CREATE TABLE home_message_search_p15 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 15);
CREATE TABLE home_message_search_p16 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 16);
CREATE TABLE home_message_search_p17 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 17);
CREATE TABLE home_message_search_p18 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 18);
CREATE TABLE home_message_search_p19 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 19);
CREATE TABLE home_message_search_p20 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 20);
CREATE TABLE home_message_search_p21 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 21);
CREATE TABLE home_message_search_p22 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 22);
CREATE TABLE home_message_search_p23 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 23);
CREATE TABLE home_message_search_p24 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 24);
CREATE TABLE home_message_search_p25 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 25);
CREATE TABLE home_message_search_p26 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 26);
CREATE TABLE home_message_search_p27 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 27);
CREATE TABLE home_message_search_p28 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 28);
CREATE TABLE home_message_search_p29 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 29);
CREATE TABLE home_message_search_p30 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 30);
CREATE TABLE home_message_search_p31 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 31);
CREATE TABLE home_message_search_p32 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 32);
CREATE TABLE home_message_search_p33 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 33);
CREATE TABLE home_message_search_p34 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 34);
CREATE TABLE home_message_search_p35 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 35);
CREATE TABLE home_message_search_p36 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 36);
CREATE TABLE home_message_search_p37 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 37);
CREATE TABLE home_message_search_p38 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 38);
CREATE TABLE home_message_search_p39 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 39);
CREATE TABLE home_message_search_p40 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 40);
CREATE TABLE home_message_search_p41 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 41);
CREATE TABLE home_message_search_p42 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 42);
CREATE TABLE home_message_search_p43 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 43);
CREATE TABLE home_message_search_p44 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 44);
CREATE TABLE home_message_search_p45 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 45);
CREATE TABLE home_message_search_p46 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 46);
CREATE TABLE home_message_search_p47 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 47);
CREATE TABLE home_message_search_p48 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 48);
CREATE TABLE home_message_search_p49 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 49);
CREATE TABLE home_message_search_p50 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 50);
CREATE TABLE home_message_search_p51 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 51);
CREATE TABLE home_message_search_p52 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 52);
CREATE TABLE home_message_search_p53 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 53);
CREATE TABLE home_message_search_p54 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 54);
CREATE TABLE home_message_search_p55 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 55);
CREATE TABLE home_message_search_p56 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 56);
CREATE TABLE home_message_search_p57 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 57);
CREATE TABLE home_message_search_p58 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 58);
CREATE TABLE home_message_search_p59 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 59);
CREATE TABLE home_message_search_p60 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 60);
CREATE TABLE home_message_search_p61 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 61);
CREATE TABLE home_message_search_p62 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 62);
CREATE TABLE home_message_search_p63 PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER 63);

-- Composite GIN (btree_gin): one bitmap scan applies the membership (conversation_id) and
-- the text condition together. Indexes on the parent propagate to every partition.
CREATE INDEX home_message_search_fts ON home_message_search USING gin (conversation_id, tsv);
CREATE INDEX home_message_search_trgm ON home_message_search USING gin (conversation_id, body gin_trgm_ops);
CREATE INDEX home_message_search_recent ON home_message_search (conversation_id, created_at DESC);

CREATE TABLE home_invites (
  id               text PRIMARY KEY,
  conversation_id  text NOT NULL,
  invited_by       text NOT NULL,
  address_id       text NOT NULL,
  channel          text NOT NULL CHECK (channel IN ('email', 'sms')),
  status           text NOT NULL CHECK (status IN ('pending', 'pending_approval', 'accepted', 'revoked', 'expired')),
  delivery_state   text NOT NULL,
  copy_variant     text NOT NULL,
  created_at       timestamptz NOT NULL,
  expires_at       timestamptz NOT NULL,
  accepted_by      text,
  accepted_at      timestamptz,
  source_stream    text NOT NULL,
  source_seq       bigint NOT NULL,
  updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX home_invites_inviter ON home_invites (invited_by, created_at DESC);
CREATE INDEX home_invites_address ON home_invites (address_id, created_at DESC);
CREATE INDEX home_invites_conversation ON home_invites (conversation_id);
