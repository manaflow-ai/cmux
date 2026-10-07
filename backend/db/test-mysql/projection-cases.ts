/** Projection inputs shared by the MySQL statement tests and the Postgres/MySQL parity test. */
export const T0 = Date.parse("2026-10-03T00:00:00Z")
export const iso = (ms: number) => new Date(ms).toISOString()

export interface Case {
  readonly kind: string
  readonly payload: (v: number) => Record<string, unknown>
  readonly read: string
  readonly field: string
  readonly expect: (v: number) => unknown
}
export const cases: ReadonlyArray<Case> = [
  {
    kind: "user.upsert",
    payload: (v) => ({ id: "user_p1", stack_user_id: "s1", email: `v${v}@example.com`, display_name: `User ${v}`, personal_team: "team_p1" }),
    read: "SELECT display_name AS f FROM users WHERE id = 'user_p1'",
    field: "f",
    expect: (v) => `User ${v}`
  },
  {
    kind: "install.upsert",
    payload: (v) => ({ id: "inst_p1", user: "user_p1", device: "dev_1", kind: "mac", name: `mac ${v}`, device_name: "d", platform: "macos", thumbprint: "tp", grant: "grant_1", created_at: T0, revoked_at: v > 5 ? T0 + 1000 : null }),
    read: "SELECT name AS f FROM installs WHERE id = 'inst_p1'",
    field: "f",
    expect: (v) => `mac ${v}`
  },
  {
    kind: "team.upsert",
    payload: (v) => ({ id: "team_p1", kind: "personal", display_name: `Team ${v}` }),
    read: "SELECT display_name AS f FROM teams WHERE id = 'team_p1'",
    field: "f",
    expect: (v) => `Team ${v}`
  },
  {
    kind: "membership.upsert",
    payload: (v) => ({ team: "team_p1", user: "user_p1", role: v > 5 ? "admin" : "owner" }),
    read: "SELECT role AS f FROM memberships WHERE team_id = 'team_p1' AND user_id = 'user_p1'",
    field: "f",
    expect: (v) => (v > 5 ? "admin" : "owner")
  },
  {
    kind: "host.upsert",
    payload: (v) => ({ id: "host_p1", team: "team_p1", owner_user: "user_p1", enrolled_by: "user_p1", name: `host ${v}`, platform: "linux", enrolled_at: T0 }),
    read: "SELECT name AS f FROM hosts WHERE id = 'host_p1'",
    field: "f",
    expect: (v) => `host ${v}`
  },
  {
    kind: "automation.upsert",
    payload: (v) => ({ id: "auto_p1", owner: "team_p1", name: `auto ${v}`, enabled: true, version: v, created_by: "user_p1", created_at: T0, updated_at: T0 + v, next_run_at: null }),
    read: "SELECT name AS f FROM automations WHERE id = 'auto_p1'",
    field: "f",
    expect: (v) => `auto ${v}`
  },
  {
    kind: "automation_run.upsert",
    payload: (v) => ({ id: "run_p1", owner: "team_p1", automation: "auto_p1", automation_version: 1, trigger: { type: "manual" }, state: v > 5 ? "done" : "running", step: v, error: null, outcome: null, created_at: T0, started_at: T0, finished_at: v > 5 ? T0 + 9 : null }),
    read: "SELECT state AS f FROM automation_runs WHERE id = 'run_p1'",
    field: "f",
    expect: (v) => (v > 5 ? "done" : "running")
  },
  {
    kind: "connection.upsert",
    payload: (v) => ({ id: "conn_p1", owner: "team_p1", created_by: "user_p1", provider: "github", account: { key: "github:1", name: `acct ${v}` }, scopes_requested: [], scopes_granted: ["repo"], status: "active", sharing: "team", created_at: T0, updated_at: T0 + v }),
    read: "SELECT account_name AS f FROM connections WHERE id = 'conn_p1'",
    field: "f",
    expect: (v) => `acct ${v}`
  },
  {
    kind: "home.conversation.upsert",
    payload: (v) => ({ id: "conv_P1", kind: "group", team_id: null, title: `Title ${v}`, created_by: "user_p1", created_at: iso(T0), last_seq: v, last_at: iso(T0 + v), participant_count: 2, state: "active" }),
    read: "SELECT title AS f FROM home_conversations WHERE id = 'conv_P1'",
    field: "f",
    expect: (v) => `Title ${v}`
  },
  {
    kind: "home.participant.upsert",
    payload: (v) => ({ conversation_id: "conv_P1", participant_id: "user_p1", kind: "human", visible_from_seq: v, joined_at: iso(T0), left_at: null }),
    read: "SELECT visible_from_seq AS f FROM home_participants WHERE conversation_id = 'conv_P1' AND participant_id = 'user_p1'",
    field: "f",
    expect: (v) => v
  },
  {
    kind: "home.invite.upsert",
    payload: (v) => ({ id: "inv_P1", conversation_id: "conv_P1", invited_by: "user_p1", address_id: "addr_P1", channel: "email", status: v > 5 ? "accepted" : "pending", delivery_state: "queued", copy_variant: "A", created_at: iso(T0), expires_at: iso(T0 + 86_400_000), accepted_by: v > 5 ? "user_p2" : null, accepted_at: v > 5 ? iso(T0 + 5) : null }),
    read: "SELECT status AS f FROM home_invites WHERE id = 'inv_P1'",
    field: "f",
    expect: (v) => (v > 5 ? "accepted" : "pending")
  },
  {
    kind: "home.message.upsert",
    payload: (v) => ({ conversation_id: "conv_P1", seq: 1, message_id: "msg_p1", author_id: "user_p1", author_kind: "human", created_at: iso(T0), edited_at: v > 5 ? iso(T0 + 5) : null, body: `body ${v}` }),
    read: "SELECT body AS f FROM home_message_search WHERE conversation_id = 'conv_P1' AND seq = 1",
    field: "f",
    expect: (v) => `body ${v}`
  }
]

