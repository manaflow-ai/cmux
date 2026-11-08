import type { OwnerFrame, Principal, RejectFrame, RowReader } from "@cmux/ownership"
import { TeamAgentKeyRemove, TeamAgentKeySet } from "@cmux/protocol"
import { decodeParams } from "./domains/common.ts"
import { can, memberOf } from "./domains/team-members.ts"
import { teamDeleted } from "./domains/team-stack.ts"
import type { TeamState } from "./domains/team.ts"
import type { Env } from "./env.ts"
import { openSecretText, sealSecretText, type CredentialAddress } from "./integrations/credentials.ts"
import type { Http } from "./integrations/provider-core.ts"
import type { DomainReply } from "./team-domain-external.ts"

/**
 * Team shared agent keys (Cloud multiplayer, contract C4). One sealed key per team and agent, in a
 * TeamDO side table, written only by an owner or admin in a person's session
 * (`team.agent_key.set`, `team.agent_key.remove`, POST /v1/ops) and read back only by the Worker's
 * model route (`resolveTeamSharedKey`, contract C2). `team.agent_key.status` says whether a key is
 * set, never the key; its last four characters only to owners and admins.
 *
 * The key is sealed like an integration credential (integrations/credentials.ts: a fresh data key
 * per seal, wrapped by KMS when configured, else by INTEGRATIONS_KEK), bound to team, agent and
 * generation, so a sealed row moved to another team, agent or generation does not open. It never
 * enters an op param, event, snapshot, ledger row or log: the audit op carries the agent, kind and
 * generation only.
 *
 * A removal clears the seal and raises the row's generation like a set, so a later set never reuses
 * one and the status revision moves on every change; every set
 * and removal compares and swaps on it across the seal's await, so two admins at once never
 * interleave (the later one answers revision.conflict and retries).
 */

export type TeamAgent = "claude" | "codex"
export type TeamAgentKeyKind = "api_key" | "oauth"
export const TEAM_AGENTS: ReadonlyArray<TeamAgent> = ["claude", "codex"]

/** What the model route sends upstream for a team's machines. */
export interface TeamSharedKey {
  readonly kind: TeamAgentKeyKind
  readonly secret: string
}

export interface TeamAgentKeyState {
  readonly agent: TeamAgent
  readonly set: boolean
  readonly kind: TeamAgentKeyKind | null
  readonly generation: number
  readonly updated_at: number | null
  readonly updated_by: string | null
  readonly hint: string | null
}

interface Row {
  agent: string
  kind: string | null
  generation: number
  sealed: string | null
  hint: string | null
  updated_at: number | null
  updated_by: string | null
  last_key: string | null
}

export const ensureAgentKeyTable = (sql: SqlStorage) =>
  sql.exec(
    `CREATE TABLE IF NOT EXISTS team_agent_keys (agent TEXT PRIMARY KEY, kind TEXT, generation INTEGER NOT NULL, sealed TEXT, hint TEXT, updated_at INTEGER, updated_by TEXT, last_key TEXT)`
  )

const rowOf = (sql: SqlStorage, agent: string): Row | undefined => {
  ensureAgentKeyTable(sql)
  const r = sql.exec<Record<string, SqlStorageValue>>(`SELECT * FROM team_agent_keys WHERE agent = ?`, agent).toArray()[0]
  if (!r) return undefined
  return {
    agent: String(r.agent),
    kind: r.kind === null ? null : String(r.kind),
    generation: Number(r.generation),
    sealed: r.sealed === null ? null : String(r.sealed),
    hint: r.hint === null ? null : String(r.hint),
    updated_at: r.updated_at === null ? null : Number(r.updated_at),
    updated_by: r.updated_by === null ? null : String(r.updated_by),
    last_key: r.last_key === null ? null : String(r.last_key)
  }
}

/** The seal's address: the team owns it, and agent plus generation name the row (KMS context, AES-GCM AAD). */
const addressOf = (team: string, agent: string, generation: number): CredentialAddress => ({ connection: `team-agent-key:${agent}`, owner: team, provider: `agent-key:${agent}`, generation })

const stateOf = (agent: TeamAgent, row: Row | undefined, manager: boolean): TeamAgentKeyState => {
  const set = Boolean(row?.sealed)
  return {
    agent,
    set,
    kind: set ? ((row!.kind as TeamAgentKeyKind | null) ?? null) : null,
    generation: row?.generation ?? 0,
    updated_at: row?.updated_at ?? null,
    updated_by: row?.updated_by ?? null,
    hint: set && manager ? row!.hint : null
  }
}

/**
 * A key's shape check: printable ASCII with no whitespace for an API key or a token; a sign-in file
 * (JSON) for a subscription may hold whitespace. Never names a provider: the model route and the
 * provider tell a wrong key from a right one.
 */
export const agentKeyProblem = (kind: TeamAgentKeyKind, secret: string): string | undefined => {
  if (secret !== secret.trim()) return "the key has leading or trailing whitespace"
  if (/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(secret)) return "the key holds control characters"
  if (kind === "api_key" && !/^[\x21-\x7e]+$/.test(secret)) return "an API key is printable characters with no spaces"
  if (kind === "oauth" && !secret.startsWith("{") && !/^[\x21-\x7e]+$/.test(secret)) return "a subscription token is printable characters with no spaces, or a sign-in file"
  if (kind === "oauth" && secret.startsWith("{")) {
    try {
      if (typeof JSON.parse(secret) !== "object") return "a sign-in file is a JSON object"
    } catch {
      return "a sign-in file is a JSON object"
    }
  }
  return undefined
}

/** The last four characters of a key with at least 12, else none (a short key would leak too much). */
const hintOf = (secret: string) => (secret.length >= 12 ? secret.slice(-4) : null)

export interface AgentKeyDeps {
  readonly state: () => TeamState
  readonly rows?: RowReader
  readonly team: string
  readonly stream: string
  readonly env: Env
  readonly http: Http
  readonly sql: SqlStorage
  readonly now: () => number
  readonly submitSystem: (op: string, params: unknown, key: string) => { frames: ReadonlyArray<OwnerFrame> }
}

const teamGone = (state: TeamState) => !state.team || teamDeleted(state)

/** `team.agent_key.set` and `team.agent_key.remove` (module docs). */
export const agentKeyExternal = async (deps: AgentKeyDeps, p: Principal, frame: { op: string; params: unknown; idempotency_key: string }): Promise<DomainReply> => {
  const base = { op: frame.op, transaction: "", idempotency_key: frame.idempotency_key, stream: deps.stream, sequence: 0, replayed: false }
  const fail = (code: string, message: string, retryable = false): DomainReply => ({ ...base, ok: false, error: { code, message, retryable } })
  const state = deps.state()
  if (p.kind !== "session" || p.agent) return fail("auth.forbidden", "team shared keys are changed by a person, in their own session")
  if (p.team !== deps.team || !memberOf(state, deps.rows, p.user)) return fail("auth.forbidden", "not a member of this team")
  if (teamGone(state)) return fail("auth.forbidden", "this team was deleted")
  if (!can(state, deps.rows, p.user, "team.manage")) return fail("auth.forbidden", "only team owners and admins may change shared keys")
  const by = p.user!
  const audit = (action: "set" | "replaced" | "removed", agent: TeamAgent, generation: number, kind?: TeamAgentKeyKind) => {
    const rej = deps.submitSystem("team.agent_key.audit", { action, agent, generation, by, ...(kind ? { kind } : {}) }, `agent-key:${agent}:${generation}:${action}`).frames.find((f): f is RejectFrame => f.t === "reject")
    if (rej) console.error(JSON.stringify({ msg: "team agent key audit refused", team: deps.team, agent, code: rej.code }))
  }

  if (frame.op === TeamAgentKeyRemove.name) {
    const d = decodeParams<{ agent: TeamAgent }>(TeamAgentKeyRemove, frame.params)
    if (!d.ok) return fail(d.code, d.message)
    const row = rowOf(deps.sql, d.value.agent)
    if (!row?.sealed) return { ...base, ok: true, value: { agent: d.value.agent, removed: false } }
    deps.sql.exec(
      `UPDATE team_agent_keys SET sealed = NULL, kind = NULL, hint = NULL, generation = generation + 1, updated_at = ?, updated_by = ?, last_key = NULL WHERE agent = ? AND generation = ?`,
      deps.now(),
      by,
      d.value.agent,
      row.generation
    )
    audit("removed", d.value.agent, row.generation)
    return { ...base, ok: true, value: { agent: d.value.agent, removed: true } }
  }

  const d = decodeParams<{ agent: TeamAgent; kind: TeamAgentKeyKind; secret: string }>(TeamAgentKeySet, frame.params)
  if (!d.ok) return fail(d.code, "invalid params")
  const { agent, kind, secret } = d.value
  const problem = agentKeyProblem(kind, secret)
  if (problem) return fail("validation.invalid", problem)
  const prior = rowOf(deps.sql, agent)
  // A retry of the same request (a lost answer) is answered from the row it wrote, not sealed again.
  if (prior?.sealed && prior.last_key === `${by}|${frame.idempotency_key}`) return { ...base, ok: true, replayed: true, value: stateOf(agent, prior, true) }
  const before = prior?.generation ?? 0
  const generation = before + 1
  let sealed: string
  try {
    sealed = JSON.stringify(await sealSecretText(deps.env, deps.http, addressOf(deps.team, agent, generation), secret))
  } catch (e) {
    console.error(JSON.stringify({ msg: "team agent key seal failed", team: deps.team, agent, error: e instanceof Error ? e.name : "unknown" }))
    if (!deps.env.INTEGRATIONS_KEK && !deps.env.INTEGRATIONS_KMS_KEY_ARN) return fail("team_agent_key.not_configured", "shared keys are not configured on this deployment")
    return fail("owner.unreachable", "the key could not be sealed; try again", true)
  }
  const now = deps.now()
  // Compare-and-swap across the seal's await: an admin who wrote first wins; this one retries.
  const written =
    before === 0
      ? deps.sql.exec(
          `INSERT INTO team_agent_keys (agent, kind, generation, sealed, hint, updated_at, updated_by, last_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (agent) DO NOTHING`,
          agent, kind, generation, sealed, hintOf(secret), now, by, `${by}|${frame.idempotency_key}`
        )
      : deps.sql.exec(
          `UPDATE team_agent_keys SET kind = ?, generation = ?, sealed = ?, hint = ?, updated_at = ?, updated_by = ?, last_key = ? WHERE agent = ? AND generation = ?`,
          kind, generation, sealed, hintOf(secret), now, by, `${by}|${frame.idempotency_key}`, agent, before
        )
  if (written.rowsWritten === 0) return fail("revision.conflict", "another admin changed this key at the same time; try again", true)
  audit(prior?.sealed ? "replaced" : "set", agent, generation, kind)
  return { ...base, ok: true, value: stateOf(agent, rowOf(deps.sql, agent), true) }
}

/** `team.agent_key.status`: members see whether each agent has a key; owners and admins also its hint. */
export const agentKeyStatus = (deps: Pick<AgentKeyDeps, "state" | "rows" | "team" | "sql">, p: Principal) => {
  const state = deps.state()
  if (p.team !== deps.team || !memberOf(state, deps.rows, p.user)) return { ok: false as const, code: "auth.forbidden", message: "not a member of this team" }
  // Only a person's own session manages or sees a hint; their agents and other principals see set or not.
  const manager = can(state, deps.rows, p.user, "team.manage") && p.kind === "session" && !p.agent
  return {
    ok: true as const,
    value: { team: deps.team, can_manage: manager, agents: TEAM_AGENTS.map((agent) => stateOf(agent, rowOf(deps.sql, agent), manager)) },
    // Decimal (ReadResponse.revision): a set and a removal each raise a generation, so the sum only grows.
    revision: String(TEAM_AGENTS.reduce((sum, agent) => sum + (rowOf(deps.sql, agent)?.generation ?? 0), 0))
  }
}

/**
 * The key itself, for the model route only (TeamDO RPC, never a client read). With `user`, only
 * while that person is still a member of the team: a member removed mid-session stops spending the
 * team's key on the very next request.
 */
export const agentKeyOpen = async (deps: Pick<AgentKeyDeps, "state" | "rows" | "team" | "sql" | "env" | "http">, agent: TeamAgent, user?: string): Promise<TeamSharedKey | null> => {
  if (!TEAM_AGENTS.includes(agent)) return null
  const state = deps.state()
  if (teamGone(state)) return null
  if (user !== undefined && !memberOf(state, deps.rows, user)) return null
  const row = rowOf(deps.sql, agent)
  if (!row?.sealed || (row.kind !== "api_key" && row.kind !== "oauth")) return null
  const secret = await openSecretText(deps.env, deps.http, addressOf(deps.team, agent, row.generation), row.sealed)
  return { kind: row.kind, secret }
}

/**
 * Contract C4: the team's shared key for `agent`, or null when it has none (or `options.user` is
 * not a current member). For the Worker's model route (contract C2); never answer a client with it.
 * cmux-platform reaches the same answer through its TEAM_DO binding: `TeamDO.agentKeyResolve(team, agent, user?)`.
 */
export const resolveTeamSharedKey = async (env: Pick<Env, "TEAM_DO">, teamId: string, agent: TeamAgent, options: { readonly user?: string } = {}): Promise<TeamSharedKey | null> => {
  const stub = env.TEAM_DO.get(env.TEAM_DO.idFromName(teamId)) as unknown as { agentKeyResolve(team: string, agent: TeamAgent, user?: string): Promise<TeamSharedKey | null> }
  return stub.agentKeyResolve(teamId, agent, options.user)
}
