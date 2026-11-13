import type { OwnerFrame, Principal, RejectFrame, RowReader } from "@cmux/ownership"
import { TeamModelsPolicySet } from "@cmux/protocol"
import { decodeParams } from "./domains/common.ts"
import { can, memberOf } from "./domains/team-members.ts"
import { teamDeleted } from "./domains/team-stack.ts"
import type { TeamState } from "./domains/team.ts"
import type { DomainReply } from "./team-domain-external.ts"

/**
 * The team's members policy for model connections (Settings > Models, cmux-tui/docs/model-connections.md):
 * `own_connections` (members' own subscriptions and keys serve their Cloud threads, default true) and
 * `choose_runout` (members choose what a thread does when its connection runs out, default false).
 *
 * Kept like the shared agent keys (team-agent-keys.ts): one row in a TeamDO side table, written only by
 * an owner or admin in a person's own session (`team.models_policy.set`, POST /v1/ops), read by every
 * member (`team.models_policy.get`). It holds no secret, but a change is a team-wide policy, so it is
 * audited (`team.models_policy.audit`) and compares and swaps on its revision like a key does. The
 * platform route's enforcement is a follow-up outside this repo.
 */

export const MODELS_POLICY_DEFAULTS = { own_connections: true, choose_runout: false } as const

export interface TeamModelsPolicyState {
  readonly team: string
  readonly can_edit: boolean
  readonly own_connections: boolean
  readonly choose_runout: boolean
  readonly revision: number
  readonly updated_at: number | null
  readonly updated_by: string | null
}

interface Row {
  own_connections: boolean
  choose_runout: boolean
  revision: number
  updated_at: number | null
  updated_by: string | null
}

export const ensureModelsPolicyTable = (sql: SqlStorage) =>
  sql.exec(
    `CREATE TABLE IF NOT EXISTS team_models_policy (id INTEGER PRIMARY KEY CHECK (id = 1), own_connections INTEGER NOT NULL, choose_runout INTEGER NOT NULL, revision INTEGER NOT NULL, updated_at INTEGER, updated_by TEXT)`
  )

const rowOf = (sql: SqlStorage): Row | undefined => {
  ensureModelsPolicyTable(sql)
  const r = sql.exec<Record<string, SqlStorageValue>>(`SELECT * FROM team_models_policy WHERE id = 1`).toArray()[0]
  if (!r) return undefined
  return {
    own_connections: Number(r.own_connections) === 1,
    choose_runout: Number(r.choose_runout) === 1,
    revision: Number(r.revision),
    updated_at: r.updated_at === null ? null : Number(r.updated_at),
    updated_by: r.updated_by === null ? null : String(r.updated_by)
  }
}

const stateOf = (team: string, row: Row | undefined, editor: boolean): TeamModelsPolicyState => ({
  team,
  can_edit: editor,
  own_connections: row?.own_connections ?? MODELS_POLICY_DEFAULTS.own_connections,
  choose_runout: row?.choose_runout ?? MODELS_POLICY_DEFAULTS.choose_runout,
  revision: row?.revision ?? 0,
  updated_at: row?.updated_at ?? null,
  updated_by: row?.updated_by ?? null
})

export interface ModelsPolicyDeps {
  readonly state: () => TeamState
  readonly rows?: RowReader
  readonly team: string
  readonly stream: string
  readonly sql: SqlStorage
  readonly now: () => number
  readonly submitSystem: (op: string, params: unknown, key: string) => { frames: ReadonlyArray<OwnerFrame> }
}

/** Only a person's own session edits: never their agents or another principal. */
const editorOf = (deps: Pick<ModelsPolicyDeps, "state" | "rows">, p: Principal) => p.kind === "session" && !p.agent && can(deps.state(), deps.rows, p.user, "team.manage")

/** `team.models_policy.get`: every member reads the policy (the defaults until an owner or admin sets one). */
export const modelsPolicyGet = (deps: Pick<ModelsPolicyDeps, "state" | "rows" | "team" | "sql">, p: Principal) => {
  const state = deps.state()
  if (p.team !== deps.team || !memberOf(state, deps.rows, p.user)) return { ok: false as const, code: "auth.forbidden", message: "not a member of this team" }
  const row = rowOf(deps.sql)
  return { ok: true as const, value: stateOf(deps.team, row, editorOf(deps, p)), revision: String(row?.revision ?? 0) }
}

/** `team.models_policy.set` (module docs). A field left out keeps its value. */
export const modelsPolicyExternal = async (deps: ModelsPolicyDeps, p: Principal, frame: { op: string; params: unknown; idempotency_key: string }): Promise<DomainReply> => {
  const base = { op: frame.op, transaction: "", idempotency_key: frame.idempotency_key, stream: deps.stream, sequence: 0, replayed: false }
  const fail = (code: string, message: string, retryable = false): DomainReply => ({ ...base, ok: false, error: { code, message, retryable } })
  const state = deps.state()
  if (frame.op !== TeamModelsPolicySet.name) return fail("validation.invalid", `${frame.op} is not a members policy op`)
  if (p.kind !== "session" || p.agent) return fail("auth.forbidden", "the members policy is changed by a person, in their own session")
  if (p.team !== deps.team || !memberOf(state, deps.rows, p.user)) return fail("auth.forbidden", "not a member of this team")
  if (!state.team || teamDeleted(state)) return fail("auth.forbidden", "this team was deleted")
  if (!can(state, deps.rows, p.user, "team.manage")) return fail("auth.forbidden", "only team owners and admins may change the members policy")
  const d = decodeParams<{ own_connections?: boolean; choose_runout?: boolean }>(TeamModelsPolicySet, frame.params)
  if (!d.ok) return fail(d.code, "invalid params")
  const prior = rowOf(deps.sql)
  const next = {
    own_connections: d.value.own_connections ?? prior?.own_connections ?? MODELS_POLICY_DEFAULTS.own_connections,
    choose_runout: d.value.choose_runout ?? prior?.choose_runout ?? MODELS_POLICY_DEFAULTS.choose_runout
  }
  // Nothing changes: answered as it is, no revision or audit (a retried request lands here too).
  if (prior && prior.own_connections === next.own_connections && prior.choose_runout === next.choose_runout) return { ...base, ok: true, value: stateOf(deps.team, prior, true) }
  const before = prior?.revision ?? 0
  const revision = before + 1
  const by = p.user!
  const now = deps.now()
  const written =
    before === 0
      ? deps.sql.exec(
          `INSERT INTO team_models_policy (id, own_connections, choose_runout, revision, updated_at, updated_by) VALUES (1, ?, ?, ?, ?, ?) ON CONFLICT (id) DO NOTHING`,
          next.own_connections ? 1 : 0, next.choose_runout ? 1 : 0, revision, now, by
        )
      : deps.sql.exec(
          `UPDATE team_models_policy SET own_connections = ?, choose_runout = ?, revision = ?, updated_at = ?, updated_by = ? WHERE id = 1 AND revision = ?`,
          next.own_connections ? 1 : 0, next.choose_runout ? 1 : 0, revision, now, by, before
        )
  if (written.rowsWritten === 0) return fail("revision.conflict", "another admin changed the members policy at the same time; try again", true)
  const rej = deps.submitSystem("team.models_policy.audit", { ...next, revision, by }, `models-policy:${revision}`).frames.find((f): f is RejectFrame => f.t === "reject")
  if (rej) console.error(JSON.stringify({ msg: "team models policy audit refused", team: deps.team, code: rej.code }))
  return { ...base, ok: true, value: stateOf(deps.team, rowOf(deps.sql), true) }
}
