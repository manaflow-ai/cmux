import type { Domain, OutboxItem, Principal } from "@cmux/ownership"
import {
  connectionInternalOps,
  DEFAULT_INTEGRATION_POLICY,
  IntegrationConnect,
  IntegrationPolicySet,
  IntegrationRevoke,
  EXPIRED_CONNECTION_RETENTION_MS,
  PENDING_CONNECTION_TTL_MS,
  type Connection,
  type TeamIntegrationPolicy
} from "@cmux/protocol"
import { admit, decodeParams, reject, requirePersonalTeamAdmin } from "./common.ts"
import { personalTeamIdFor } from "./user.ts"

/**
 * ConnectionDO's reducer (spec integrations.md): the integration connections
 * of one owner team. Credentials are not here (they are sealed in a DO table
 * outside entity state); this holds only what every team member may see.
 */

export interface ConnectionsState {
  readonly owner: string | null
  readonly connections: Readonly<Record<string, Connection>>
  /** Absent in objects created before policies; read through `policyOf`. */
  readonly policy?: TeamIntegrationPolicy
  /** Counts changes of the SSO/MDM lock (appears, changes source, released); TeamDO is told each one. */
  readonly lock_version?: number
  /** The last lock_version TeamDO acknowledged. */
  readonly lock_acked?: number
  /**
   * Identifies this object's lock count. A recreated ConnectionDO starts a new
   * epoch at version 1, and TeamDO accepts a notice from a new epoch even when
   * its version is lower than the last one it recorded.
   */
  readonly lock_epoch?: string
}

/** The SSO or MDM source holding the policy, or null. */
export const lockOf = (p: TeamIntegrationPolicy): "sso" | "mdm" | null => (p.source === "sso" || p.source === "mdm" ? p.source : null)
/** True while TeamDO has not acknowledged the latest lock change. */
export const lockNoticePending = (s: ConnectionsState) => (s.lock_version ?? 0) > (s.lock_acked ?? 0)
const withLockChange = (state: ConnectionsState, next: TeamIntegrationPolicy, newId: (prefix: string) => string): ConnectionsState =>
  lockOf(policyOf(state)) === lockOf(next)
    ? { ...state, policy: next }
    : { ...state, policy: next, lock_version: (state.lock_version ?? 0) + 1, lock_epoch: state.lock_epoch ?? newId("lck") }

export const policyOf = (s: ConnectionsState): TeamIntegrationPolicy => s.policy ?? DEFAULT_INTEGRATION_POLICY

const repoMatches = (pattern: string, repo: string) => {
  const [po, pr] = pattern.toLowerCase().split("/")
  const [ro, rr] = repo.toLowerCase().split("/")
  return po === ro && (pr === "*" || pr === rr)
}

/**
 * May this GitHub connection act on (or hear events from) `repo`? The stored
 * repository list (what the linking user could access) applies unless the
 * policy scope is the whole installation; the allowlist always applies.
 */
export const githubRepoAllowed = (c: Connection, policy: TeamIntegrationPolicy, repo: string): boolean => {
  const repos = c.resources?.repos
  // Under the default scope a connection needs its recorded list: one linked under installation
  // scope (null) or before policies (undefined) is narrowed to nothing until it is re-linked.
  if (policy.github.scope === "linking_user_repos" && !repos?.some((r) => r.toLowerCase() === repo.toLowerCase())) return false
  const allow = policy.github.repo_allowlist
  return allow === null || allow.some((p) => repoMatches(p, repo))
}

type PolicyFields = { allowed_providers?: TeamIntegrationPolicy["allowed_providers"]; github?: Partial<TeamIntegrationPolicy["github"]> }
const merged = (base: TeamIntegrationPolicy, f: PolicyFields, source: TeamIntegrationPolicy["source"], by: string, now: number): TeamIntegrationPolicy => ({
  allowed_providers: f.allowed_providers !== undefined ? f.allowed_providers : base.allowed_providers,
  github: { ...base.github, ...(f.github ?? {}) },
  source,
  locked: source === "sso" || source === "mdm" || source === "team_policy",
  updated_at: now,
  updated_by: by
})

export const MAX_CONNECTIONS = 50
const internalByName = new Map(connectionInternalOps.map((d) => [d.name, d]))

/** Whether the team policy allows this connection's provider (checked on every use, not only at link time). */
export const providerAllowed = (policy: TeamIntegrationPolicy, provider: Connection["provider"]) =>
  policy.allowed_providers === null || policy.allowed_providers.includes(provider)

/** Who may see and use a connection: private ones only their creator; team ones every member. */
export const mayUse = (c: Connection, p: Principal) => c.sharing === "team" || c.created_by === p.user

const outbox = (c: Connection): OutboxItem => ({ kind: "connection.upsert", entity: c.id, payload: c })

export const connectionsDomain: Domain<ConnectionsState> = {
  initial: () => ({ owner: null, connections: {} }),

  authorize: (state, op, _params, principal) => {
    if (principal.kind === "system") {
      if (!internalByName.has(op)) return { code: "auth.forbidden", message: `${op} is not an internal op` }
      return admit("cloud:ConnectionDO", op, principal, () => undefined, Date.now())
    }
    if (!principal.team) return { code: "auth.forbidden", message: "needs a team" }
    if (state.owner && state.owner !== principal.team) return { code: "auth.forbidden", message: "not this team's connections" }
    return admit("cloud:ConnectionDO", op, principal, (p) => (p.grant_classes ? { op_classes: p.grant_classes, revoked_at: null, expires_at: null } : undefined), Date.now())
  },

  reduce: (state, op, params, ctx) => {
    const p = ctx.principal
    switch (op) {
      case "integration.connect": {
        const d = decodeParams<typeof IntegrationConnect.params.Type>(IntegrationConnect, params)
        if (!d.ok) return d
        const owner = state.owner ?? p.team
        if (!owner || !p.user) return reject("auth.forbidden", "integration.connect needs a user in a team")
        const allowed = policyOf(state).allowed_providers
        if (allowed !== null && !allowed.includes(d.value.provider)) return reject("policy.denied", `the team policy does not allow ${d.value.provider}`)
        // A mailbox is personal: a team-shared Gmail connection would let teammates' agents read one person's mail (plan decision I4).
        if (d.value.provider === "gmail" && d.value.sharing === "team") return reject("validation.invalid", "a Gmail connection is always private")
        if (Object.values(state.connections).filter((c) => c.status !== "revoked" && c.status !== "expired").length >= MAX_CONNECTIONS) {
          return reject("integration.limit", `at most ${MAX_CONNECTIONS} connections per team`)
        }
        const c: Connection = {
          id: ctx.newId("conn"),
          owner,
          created_by: p.user,
          provider: d.value.provider,
          account: null,
          scopes_requested: [...(d.value.scopes ?? [])],
          scopes_granted: [],
          status: "pending",
          sharing: d.value.sharing ?? "private",
          created_at: ctx.now,
          updated_at: ctx.now
        }
        return { ok: true, state: { ...state, owner, connections: { ...state.connections, [c.id]: c } }, value: c, outbox: [outbox(c)] }
      }

      case "integration.revoke": {
        const d = decodeParams<typeof IntegrationRevoke.params.Type>(IntegrationRevoke, params)
        if (!d.ok) return d
        const c = state.connections[d.value.connection]
        if (!c || !mayUse(c, p)) return reject("selector.not_found", "connection not found")
        // Phase 1 knows no team roles here: only the creator disconnects (team admins come with Stack teams).
        if (c.created_by !== p.user) return reject("auth.forbidden", "only the person who connected it may disconnect it")
        if (c.status === "revoked" || c.status === "expired") return { ok: true, state, value: c, changed: false }
        const next: Connection = { ...c, status: "revoked", updated_at: ctx.now }
        return { ok: true, state: { ...state, connections: { ...state.connections, [c.id]: next } }, value: next, outbox: [outbox(next)] }
      }

      case "connection.activate": {
        const d = decodeParams<{ connection: string; account: { key: string; name: string; url?: string }; scopes_granted: Array<string>; resources?: { repos: Array<string> | null } }>(
          internalByName.get(op)!,
          params
        )
        if (!d.ok) return d
        const c = state.connections[d.value.connection]
        if (!c) return reject("selector.not_found", "connection not found")
        if (c.status === "revoked") return reject("validation.invalid", "connection was revoked")
        if (c.status === "expired") return reject("validation.invalid", "the connection link expired")
        if (c.account && c.account.key !== d.value.account.key) return reject("validation.invalid", "a connection cannot move to another provider account")
        const next: Connection = {
          ...c,
          account: d.value.account,
          scopes_granted: d.value.scopes_granted,
          ...(d.value.resources ? { resources: d.value.resources } : {}),
          status: "active",
          updated_at: ctx.now
        }
        const { status_detail: _sd, ...clean } = next as Connection & { status_detail?: string }
        return { ok: true, state: { ...state, connections: { ...state.connections, [c.id]: clean } }, value: clean, outbox: [outbox(clean)] }
      }

      case "connection.status": {
        const d = decodeParams<{ connection: string; status: "active" | "needs_reauth" | "error"; detail?: string }>(internalByName.get(op)!, params)
        if (!d.ok) return d
        const c = state.connections[d.value.connection]
        if (!c) return reject("selector.not_found", "connection not found")
        if (c.status === "revoked" || c.status === "pending" || c.status === "expired") return { ok: true, state, value: c, changed: false }
        if (c.status === d.value.status && c.status_detail === d.value.detail) return { ok: true, state, value: c, changed: false }
        const { status_detail: _old, ...rest } = c
        const next: Connection = { ...rest, status: d.value.status, ...(d.value.detail ? { status_detail: d.value.detail } : {}), updated_at: ctx.now }
        return { ok: true, state: { ...state, connections: { ...state.connections, [c.id]: next } }, value: next, outbox: [outbox(next)] }
      }

      case "connection.expire": {
        const d = decodeParams<{ connection: string; at: number }>(internalByName.get(op)!, params)
        if (!d.ok) return d
        const c = state.connections[d.value.connection]
        const at = Math.max(ctx.now, d.value.at)
        // Only a pending connection past its lifetime expires; anything else is a no-op (a replayed or early alarm).
        if (!c || c.status !== "pending" || at < c.created_at + PENDING_CONNECTION_TTL_MS) return { ok: true, state, value: c ?? null, changed: false }
        const next: Connection = { ...c, status: "expired", updated_at: ctx.now }
        return { ok: true, state: { ...state, connections: { ...state.connections, [c.id]: next } }, value: next, outbox: [outbox(next)] }
      }

      case "connection.forget": {
        const d = decodeParams<{ connection: string; at: number }>(internalByName.get(op)!, params)
        if (!d.ok) return d
        const c = state.connections[d.value.connection]
        if (!c || c.status !== "expired" || Math.max(ctx.now, d.value.at) < c.updated_at + EXPIRED_CONNECTION_RETENTION_MS) return { ok: true, state, value: null, changed: false }
        const { [c.id]: _gone, ...rest } = state.connections
        return { ok: true, state: { ...state, connections: rest }, value: { connection: c.id } }
      }

      case "integration.policy.set": {
        const d = decodeParams<PolicyFields>(IntegrationPolicySet, params)
        if (!d.ok) return d
        const owner = state.owner ?? p.team
        if (!owner || !p.user) return reject("auth.forbidden", "needs a user in a team")
        if (owner !== p.team) return reject("auth.forbidden", "only a team admin may change the policy")
        const notAdmin = requirePersonalTeamAdmin(p, personalTeamIdFor)
        if (notAdmin) return { ok: false, ...notAdmin }
        const cur = policyOf(state)
        if (cur.locked) return reject("policy.locked", `the policy is managed by ${cur.source} and cannot be changed here`)
        const next = merged(cur, d.value, "admin", p.user, ctx.now)
        return { ok: true, state: { ...state, owner, policy: next }, value: next }
      }

      case "integration.policy.apply_managed": {
        const d = decodeParams<{ source: "sso" | "mdm" | "team_policy"; policy: PolicyFields; applied_by: string }>(internalByName.get(op)!, params)
        if (!d.ok) return d
        // SSO- and MDM-managed locks always win over TeamPolicy (decision, consistent with E2):
        // a team_policy push or adopt leaves them as they are; TeamDO reports the conflict.
        const held = policyOf(state)
        if (d.value.source === "team_policy" && (held.source === "sso" || held.source === "mdm")) return { ok: true, state, value: held, changed: false }
        // A managed policy starts from the default (not from admin edits) and locks.
        const next = merged(DEFAULT_INTEGRATION_POLICY, d.value.policy, d.value.source, d.value.applied_by, ctx.now)
        return { ok: true, state: withLockChange(state, next, ctx.newId), value: next }
      }

      case "integration.policy.release_managed": {
        const held = policyOf(state)
        if (!lockOf(held)) return { ok: true, state, value: held, changed: false }
        const by = (params as { requested_by?: unknown })?.requested_by
        // The values stay; only the lock goes. TeamDO then pushes its policy (source team_policy).
        const next: TeamIntegrationPolicy = { ...held, source: "admin", locked: false, updated_at: ctx.now, updated_by: typeof by === "string" ? by : "team admin" }
        return { ok: true, state: withLockChange(state, next, ctx.newId), value: next }
      }

      case "integration.policy.lock_acked": {
        const v = (params as { version?: unknown })?.version
        if (typeof v !== "number" || v <= (state.lock_acked ?? 0)) return { ok: true, state, value: { version: v }, changed: false }
        return { ok: true, state: { ...state, lock_acked: Math.min(v, state.lock_version ?? 0) }, value: { version: v } }
      }

      default:
        return reject("validation.invalid", `unknown op ${op}`)
    }
  }
}

/** Pending connections, oldest first, with the instant each expires. */
export const pendingExpiries = (s: ConnectionsState): Array<{ connection: string; at: number }> =>
  Object.values(s.connections)
    .filter((c) => c.status === "pending")
    .map((c) => ({ connection: c.id, at: c.created_at + PENDING_CONNECTION_TTL_MS }))
    .sort((a, b) => a.at - b.at)

/** Expired connections, oldest first, with the instant each leaves owner state. */
export const expiredForgets = (s: ConnectionsState): Array<{ connection: string; at: number }> =>
  Object.values(s.connections)
    .filter((c) => c.status === "expired")
    .map((c) => ({ connection: c.id, at: c.updated_at + EXPIRED_CONNECTION_RETENTION_MS }))
    .sort((a, b) => a.at - b.at)
