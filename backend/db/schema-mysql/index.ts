/**
 * cmux-next PlanetScale MySQL (Vitess) schema, Drizzle mysql-core (plans/cmux-next/state-placement.md
 * section 4). Same tables and columns as the Postgres projection (schema/index.ts) during the move.
 * Vitess rules: no foreign keys, a primary key on every table, no partitions, triggers or checks
 * (the owning Durable Object is the single writer and enforces the domain). Types: ids and hashes are
 * ASCII byte strings (ascii_bin), human text is utf8mb4 (the database default utf8mb4_0900_ai_ci),
 * times are datetime(3) in UTC (the connection sets time_zone '+00:00'), opaque payloads are json.
 * The drain writes every row through the (source_stream, source_seq) guard (projection-mysql.ts).
 */
import { sql } from "drizzle-orm"
import { bigint, boolean, customType, datetime, index, int, json, mysqlTable, primaryKey, text, uniqueIndex, varchar } from "drizzle-orm/mysql-core"

/** An ASCII byte-compared string: ids, hashes, enum-like kinds, stream names. */
const ascii = (name: string, length = 64) =>
  customType<{ data: string; driverData: string }>({ dataType: () => `varchar(${length}) CHARACTER SET ascii COLLATE ascii_bin` })(name)
/** Human text short enough to index (names, titles, emails). */
const label = (name: string, length = 512) => varchar(name, { length })
const at = (name: string) => datetime(name, { mode: "string", fsp: 3 })
const now3 = sql`(CURRENT_TIMESTAMP(3))`
const seq = (name: string) => bigint(name, { mode: "number" })
/** The single-writer guard columns every projected row carries. */
const source = () => ({ sourceStream: ascii("source_stream", 128).notNull(), sourceSeq: seq("source_seq").notNull() })

export const users = mysqlTable("users", {
  id: ascii("id").primaryKey(),
  stackUserId: ascii("stack_user_id", 128).notNull(),
  email: label("email", 320),
  displayName: label("display_name").notNull(),
  personalTeam: ascii("personal_team").notNull(),
  ...source(),
  createdAt: at("created_at").notNull().default(now3),
  updatedAt: at("updated_at").notNull().default(now3)
}, (t) => [uniqueIndex("users_stack_user_id_key").on(t.stackUserId)])

export const teams = mysqlTable("teams", {
  id: ascii("id").primaryKey(),
  kind: ascii("kind", 16).notNull(),
  stackTeamId: ascii("stack_team_id", 128),
  displayName: label("display_name").notNull(),
  ...source(),
  createdAt: at("created_at").notNull().default(now3),
  updatedAt: at("updated_at").notNull().default(now3)
}, (t) => [uniqueIndex("teams_stack_team_id_key").on(t.stackTeamId)])

export const automations = mysqlTable("automations", {
  id: ascii("id").primaryKey(),
  teamId: ascii("team_id").notNull(),
  name: label("name").notNull(),
  enabled: boolean("enabled").notNull(),
  version: int("version").notNull(),
  definition: json("definition").notNull(),
  createdBy: ascii("created_by").notNull(),
  createdAt: at("created_at").notNull(),
  updatedAt: at("updated_at").notNull(),
  nextRunAt: at("next_run_at"),
  deletedAt: at("deleted_at"),
  ...source()
}, (t) => [index("automations_team").on(t.teamId, t.deletedAt)])

export const installs = mysqlTable("installs", {
  id: ascii("id").primaryKey(),
  userId: ascii("user_id").notNull(),
  deviceId: ascii("device_id", 128).notNull(),
  kind: ascii("kind", 32).notNull(),
  name: label("name").notNull(),
  deviceName: label("device_name").notNull(),
  platform: ascii("platform", 32).notNull(),
  thumbprint: ascii("thumbprint", 128).notNull(),
  grantId: ascii("grant_id").notNull(),
  createdAt: at("created_at").notNull(),
  revokedAt: at("revoked_at"),
  ...source(),
  updatedAt: at("updated_at").notNull().default(now3)
}, (t) => [index("installs_user").on(t.userId)])

export const hosts = mysqlTable("hosts", {
  id: ascii("id").primaryKey(),
  teamId: ascii("team_id").notNull(),
  ownerUser: ascii("owner_user").notNull(),
  enrolledBy: ascii("enrolled_by").notNull(),
  name: label("name").notNull(),
  platform: ascii("platform", 32).notNull(),
  enrolledAt: at("enrolled_at").notNull(),
  deletedAt: at("deleted_at"),
  ...source(),
  updatedAt: at("updated_at").notNull().default(now3)
}, (t) => [index("hosts_team").on(t.teamId, t.deletedAt)])

export const automationRuns = mysqlTable("automation_runs", {
  id: ascii("id").primaryKey(),
  teamId: ascii("team_id").notNull(),
  automationId: ascii("automation_id").notNull(),
  automationVersion: int("automation_version").notNull(),
  triggerType: ascii("trigger_type", 32).notNull(),
  trigger: json("trigger").notNull(),
  state: ascii("state", 32).notNull(),
  step: int("step").notNull(),
  error: json("error"),
  outcome: json("outcome"),
  createdAt: at("created_at").notNull(),
  startedAt: at("started_at"),
  finishedAt: at("finished_at"),
  ...source(),
  updatedAt: at("updated_at").notNull().default(now3)
}, (t) => [index("automation_runs_automation").on(t.automationId, t.createdAt), index("automation_runs_team").on(t.teamId, t.createdAt)])

export const connections = mysqlTable("connections", {
  id: ascii("id").primaryKey(),
  teamId: ascii("team_id").notNull(),
  createdBy: ascii("created_by").notNull(),
  provider: ascii("provider", 64).notNull(),
  accountKey: ascii("account_key", 255),
  accountName: label("account_name"),
  scopesRequested: json("scopes_requested").notNull(),
  scopesGranted: json("scopes_granted").notNull(),
  status: ascii("status", 32).notNull(),
  sharing: ascii("sharing", 32).notNull(),
  createdAt: at("created_at").notNull(),
  updatedAt: at("updated_at").notNull(),
  ...source()
}, (t) => [index("connections_account").on(t.accountKey), index("connections_team").on(t.teamId)])

export const homeConversations = mysqlTable("home_conversations", {
  id: ascii("id").primaryKey(),
  kind: ascii("kind", 16).notNull(),
  teamId: ascii("team_id"),
  title: label("title"),
  createdBy: ascii("created_by"),
  createdAt: at("created_at").notNull(),
  lastSeq: seq("last_seq").notNull(),
  lastAt: at("last_at").notNull(),
  participantCount: int("participant_count").notNull(),
  state: ascii("state", 16).notNull(),
  ...source(),
  updatedAt: at("updated_at").notNull().default(now3)
}, (t) => [index("home_conversations_team").on(t.teamId, t.lastAt)])

export const homeInvites = mysqlTable("home_invites", {
  id: ascii("id").primaryKey(),
  conversationId: ascii("conversation_id").notNull(),
  invitedBy: ascii("invited_by").notNull(),
  addressId: ascii("address_id", 128).notNull(),
  channel: ascii("channel", 16).notNull(),
  status: ascii("status", 32).notNull(),
  deliveryState: ascii("delivery_state", 32).notNull(),
  copyVariant: ascii("copy_variant", 64).notNull(),
  createdAt: at("created_at").notNull(),
  expiresAt: at("expires_at").notNull(),
  acceptedBy: ascii("accepted_by"),
  acceptedAt: at("accepted_at"),
  ...source(),
  updatedAt: at("updated_at").notNull().default(now3)
}, (t) => [
  index("home_invites_address").on(t.addressId, t.createdAt),
  index("home_invites_conversation").on(t.conversationId),
  index("home_invites_inviter").on(t.invitedBy, t.createdAt)
])

export const memberships = mysqlTable("memberships", {
  teamId: ascii("team_id").notNull(),
  userId: ascii("user_id").notNull(),
  role: ascii("role", 16).notNull(),
  ...source(),
  updatedAt: at("updated_at").notNull().default(now3)
}, (t) => [primaryKey({ columns: [t.teamId, t.userId], name: "memberships_pkey" }), index("memberships_user").on(t.userId)])

export const homeParticipants = mysqlTable("home_participants", {
  conversationId: ascii("conversation_id").notNull(),
  participantId: ascii("participant_id").notNull(),
  kind: ascii("kind", 16).notNull(),
  visibleFromSeq: seq("visible_from_seq").notNull().default(0),
  joinedAt: at("joined_at").notNull(),
  leftAt: at("left_at"),
  ...source(),
  updatedAt: at("updated_at").notNull().default(now3)
}, (t) => [
  primaryKey({ columns: [t.conversationId, t.participantId], name: "home_participants_pkey" }),
  index("home_participants_member").on(t.participantId, t.leftAt, t.conversationId)
])

export const auditEvents = mysqlTable("audit_events", {
  teamId: ascii("team_id").notNull(),
  n: seq("n").notNull(),
  op: ascii("op", 128).notNull(),
  actor: ascii("actor", 128).notNull(),
  onBehalfOf: ascii("on_behalf_of", 128),
  transaction: ascii("transaction", 128).notNull(),
  at: at("at").notNull(),
  summary: text("summary").notNull(),
  detail: json("detail").notNull(),
  prevHash: ascii("prev_hash", 128).notNull(),
  hash: ascii("hash", 128).notNull(),
  ...source(),
  createdAt: at("created_at").notNull().default(now3)
}, (t) => [
  primaryKey({ columns: [t.teamId, t.n], name: "audit_events_pkey" }),
  uniqueIndex("audit_events_source").on(t.sourceStream, t.sourceSeq),
  index("audit_events_team_at").on(t.teamId, t.at)
])

/** Message search (home.search). Hash partitions are gone (Vitess shards by keyspace instead). */
export const homeMessageSearch = mysqlTable("home_message_search", {
  conversationId: ascii("conversation_id").notNull(),
  seq: seq("seq").notNull(),
  messageId: ascii("message_id").notNull(),
  authorId: ascii("author_id").notNull(),
  authorKind: ascii("author_kind", 16).notNull(),
  createdAt: at("created_at").notNull(),
  editedAt: at("edited_at"),
  body: text("body").notNull(),
  ...source()
}, (t) => [
  primaryKey({ columns: [t.conversationId, t.seq], name: "home_message_search_pkey" }),
  index("home_message_search_recent").on(t.conversationId, t.createdAt)
])
