import type { Domain, OutboxItem, Principal } from "@cmux/ownership"
import {
  connectionInternalOps,
  DEFAULT_INTEGRATION_POLICY,
  IntegrationConnect,
  IntegrationPolicySet,
  IntegrationRevoke,
  EXPIRED_CONNECTION_RETENTION_MS,
  GITHUB_INSTALL_REQUEST_TTL_MS,
  PENDING_CONNECTION_TTL_MS,
  type Connection,
  type TeamIntegrationPolicy
} from "@cmux/protocol"
import { admit, decodeParams, reject, requirePersonalTeamAdmin } from "./common.ts"
import { personalTeamIdFor } from "./user.ts"
import { MAX_LINKED_REPOS } from "../integrations/provider-core.ts"

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
  /**
   * Organization members' GitHub App install requests waiting for an owner (`setup_action=request`), by the
   * connection id an approval links. Absent in objects created before them.
   */
  readonly github_requests?: Readonly<Record<string, GithubInstallRequest>>
}

/**
 * One member's install request to an organization's owners. GitHub's request callback names no organization,
 * so the account is known only once an owner approves (`approved_account`, when that approval could not link).
 */
export interface GithubInstallRequest {
  readonly id: string
  readonly requested_by: string
  readonly sharing: Connection["sharing"]
  readonly scopes_requested: ReadonlyArray<string>
  /** The requester's GitHub user, proven by the callback's OAuth code; null when GitHub sent no code (no approval can link then). */
  readonly github_user: { readonly id: number; readonly login: string } | null
  readonly requested_at: number
  readonly approved_account?: string
  readonly approved_detail?: string
}

/** Requests kept per team; a newer one from the same person replaces theirs. */
export const MAX_GITHUB_REQUESTS = 20

/** Pending connections past their lifetime read as expired even before the expiry alarm runs. */
export const asSeen = (c: Connection, now: number): Connection =>
  c.status === "pending" && now >= c.created_at + PENDING_CONNECTION_TTL_MS ? { ...c, status: "expired" } : c

/** Install requests, oldest first, with the instant each leaves owner state. */
export const githubRequestExpiries = (s: ConnectionsState): Array<{ request: string; at: number }> =>
  Object.values(s.github_requests ?? {})
    .map((r) => ({ request: r.id, at: r.requested_at + GITHUB_INSTALL_REQUEST_TTL_MS }))
    .sort((a, b) => a.at - b.at)

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

/** The App installation id of a GitHub connection's account key (`github:installation:<id>`), or undefined. */
export const githubInstallationOf = (c: Connection): number | undefined => {
  const id = Number(/^github:installation:(\d+)$/.exec(c.account?.key ?? "")?.[1])
  return Number.isSafeInteger(id) && id > 0 ? id : undefined
}

/**
 * Does this active GitHub connection let a token be minted for `repo`: the repository's owner is the
 * installation's account and the scope and allowlist include it? One predicate for the token route and
 * for Connect's reuse, so Connect never answers "connected" for a repository the next mint refuses.
 */
export const githubCovers = (c: Connection, policy: TeamIntegrationPolicy, repo: string): boolean =>
  c.provider === "github" && c.status === "active" && c.account?.name.toLowerCase() === repo.split("/")[0]!.toLowerCase() && githubInstallationOf(c) !== undefined && githubRepoAllowed(c, policy, repo)

/** A GitHub connection this principal may use that already covers `repo` (Connect then has nothing to open). */
export const githubConnectionFor = (state: ConnectionsState, p: Principal, repo: string): Connection | undefined => {
  const policy = policyOf(state)
  if (!providerAllowed(policy, "github")) return undefined
  return Object.values(state.connections)
    .filter((c) => mayUse(c, p) && githubCovers(c, policy, repo))
    .sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))[0]
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
        if (d.value.repo !== undefined && d.value.provider !== "github") return reject("validation.invalid", "repo applies only to GitHub")
        // Reuse before asking: a connection this person may use already covers the repository, so there is nothing to approve.
        const reused = d.value.repo === undefined ? undefined : githubConnectionFor(state, p, d.value.repo)
        if (reused) return { ok: true, state, value: reused, changed: false }
        // One pending connect per person and provider: a new Connect ends the earlier one, whose page the person no
        // longer has (an install cancelled on GitHub, a relaunch); a callback for it is then refused as expired.
        const superseded = Object.values(state.connections)
          .filter((x) => x.status === "pending" && x.provider === d.value.provider && x.created_by === p.user)
          .map((x): Connection => ({ ...x, status: "expired", updated_at: ctx.now }))
        if (Object.values(state.connections).filter((c) => c.status !== "revoked" && c.status !== "expired").length - superseded.length >= MAX_CONNECTIONS) {
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
        const connections = { ...state.connections, ...Object.fromEntries(superseded.map((x) => [x.id, x])), [c.id]: c }
        return { ok: true, state: { ...state, owner, connections }, value: c, outbox: [...superseded.map(outbox), outbox(c)] }
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

      case "connection.github.sync": {
        const d = decodeParams<{ connection: string; scopes_granted?: Array<string>; repos_removed?: Array<string>; repos_added?: Array<string> }>(internalByName.get(op)!, params)
        if (!d.ok) return d
        const c = state.connections[d.value.connection]
        if (!c) return reject("selector.not_found", "connection not found")
        if (c.provider !== "github" || c.status === "revoked" || c.status === "pending" || c.status === "expired") return { ok: true, state, value: c, changed: false }
        const gone = new Set((d.value.repos_removed ?? []).map((r) => r.toLowerCase()))
        const repos = c.resources?.repos
        // A recorded list loses the repositories that left the installation and gains the ones the linking user is
        // proven to reach (connection-do.ts githubReposAdded), up to the cap; `null` (the whole installation) stays.
        const byName = new Map<string, string>()
        for (const r of [...(repos ?? []), ...(d.value.repos_added ?? [])]) if (!gone.has(r.toLowerCase()) && !byName.has(r.toLowerCase())) byName.set(r.toLowerCase(), r)
        const kept = Array.isArray(repos) ? [...byName.values()].sort().slice(0, MAX_LINKED_REPOS) : repos
        const scopes = d.value.scopes_granted ? [...d.value.scopes_granted].sort() : c.scopes_granted
        const same = (a: ReadonlyArray<string> | null | undefined, b: ReadonlyArray<string> | null | undefined) => a === b || (!!a && !!b && a.length === b.length && a.every((s, i) => s === b[i]))
        if (same(scopes, c.scopes_granted) && same(kept, repos)) return { ok: true, state, value: c, changed: false }
        const next: Connection = { ...c, scopes_granted: scopes, ...(c.resources ? { resources: { repos: kept ?? null } } : {}), updated_at: ctx.now }
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

      case "connection.github.requested": {
        const d = decodeParams<{ connection: string; request: string; github_user: { id: number; login: string } | null }>(internalByName.get(op)!, params)
        if (!d.ok) return d
        const c = state.connections[d.value.connection]
        if (!c || c.provider !== "github") return reject("selector.not_found", "connection not found")
        if (c.status !== "pending") return reject("validation.invalid", `this connection is ${c.status}`)
        const requests = state.github_requests ?? {}
        if (requests[d.value.request] || state.connections[d.value.request]) return reject("validation.invalid", "request id in use")
        const r: GithubInstallRequest = { id: d.value.request, requested_by: c.created_by, sharing: c.sharing, scopes_requested: [...c.scopes_requested], github_user: d.value.github_user, requested_at: ctx.now }
        // A person's newer request replaces theirs (an approval links one); the team keeps the newest MAX_GITHUB_REQUESTS.
        const others = Object.values(requests).sort((a, b) => a.requested_at - b.requested_at)
        const kept = others.filter((x) => !(x.requested_by === r.requested_by && (x.github_user?.id ?? null) === (r.github_user?.id ?? null))).slice(-(MAX_GITHUB_REQUESTS - 1))
        const dropped = others.filter((x) => !kept.includes(x)).map((x) => x.id)
        const ended: Connection = { ...c, status: "expired", updated_at: ctx.now }
        return {
          ok: true,
          state: { ...state, connections: { ...state.connections, [c.id]: ended }, github_requests: Object.fromEntries([...kept, r].map((x) => [x.id, x])) },
          value: { request: r, dropped: dropped.map((id) => requests[id]!) },
          outbox: [outbox(ended)]
        }
      }

      case "connection.github.approved": {
        const d = decodeParams<{ request: string; account: { key: string; name: string; url?: string }; scopes_granted: Array<string>; resources: { repos: Array<string> | null } }>(internalByName.get(op)!, params)
        if (!d.ok) return d
        const r = state.github_requests?.[d.value.request]
        const linked = state.connections[d.value.request]
        if (!r) return linked ? { ok: true, state, value: linked, changed: false } : reject("selector.not_found", "request not found")
        if (linked || !state.owner) return reject("validation.invalid", "request id in use")
        if (!providerAllowed(policyOf(state), "github")) return reject("policy.denied", "the team policy does not allow github")
        if (Object.values(state.connections).filter((x) => x.status !== "revoked" && x.status !== "expired").length >= MAX_CONNECTIONS) return reject("integration.limit", `at most ${MAX_CONNECTIONS} connections per team`)
        const c: Connection = {
          id: r.id,
          owner: state.owner,
          created_by: r.requested_by,
          provider: "github",
          account: d.value.account,
          scopes_requested: [...r.scopes_requested],
          scopes_granted: [...d.value.scopes_granted].sort(),
          status: "active",
          sharing: r.sharing,
          resources: { repos: d.value.resources.repos === null ? null : [...d.value.resources.repos].sort() },
          created_at: ctx.now,
          updated_at: ctx.now
        }
        const { [r.id]: _done, ...rest } = state.github_requests ?? {}
        return { ok: true, state: { ...state, connections: { ...state.connections, [c.id]: c }, github_requests: rest }, value: c, outbox: [outbox(c)] }
      }

      case "connection.github.request_seen": {
        const d = decodeParams<{ request: string; account: string; reason: string }>(internalByName.get(op)!, params)
        if (!d.ok) return d
        const r = state.github_requests?.[d.value.request]
        if (!r || (r.approved_account === d.value.account && r.approved_detail === d.value.reason)) return { ok: true, state, value: r ?? null, changed: false }
        const next: GithubInstallRequest = { ...r, approved_account: d.value.account, approved_detail: d.value.reason }
        return { ok: true, state: { ...state, github_requests: { ...state.github_requests, [r.id]: next } }, value: next }
      }

      case "connection.github.request_expire": {
        const d = decodeParams<{ request: string; at: number }>(internalByName.get(op)!, params)
        if (!d.ok) return d
        const r = state.github_requests?.[d.value.request]
        if (!r || Math.max(ctx.now, d.value.at) < r.requested_at + GITHUB_INSTALL_REQUEST_TTL_MS) return { ok: true, state, value: null, changed: false }
        const { [r.id]: _gone, ...rest } = state.github_requests ?? {}
        return { ok: true, state: { ...state, github_requests: rest }, value: r }
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

      case "integration.github.token_minted": {
        // The mint's audit record (integrations/github-tokens.ts): state stays; TeamDO appends it to the team's audit chain.
        const d = decodeParams<{ team: string; token_id: string }>(internalByName.get(op)!, params)
        if (!d.ok) return d
        if (p.kind !== "system" || !state.owner || d.value.team !== state.owner) return reject("auth.forbidden", "internal op of this team's ConnectionDO")
        return { ok: true, state, value: d.value, outbox: [{ kind: "team.github.token_minted", entity: `ghtok:${d.value.token_id}`, payload: d.value, target: { class: "TeamDO", name: state.owner } }] }
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

/**
 * GET /v1/integrations/github/status `pending_approval`: this principal's newest visible install request to an
 * organization's owners, or null. `links_on_approval`: the approval connects it with no further click (the
 * requester's GitHub user is known and the policy lets a member link); `approved_account` and `detail`: an owner
 * approved but it could not link by itself, so the person chooses Connect GitHub again.
 */
export const pendingApprovalOf = (s: ConnectionsState, p: Principal) => {
  const r = Object.values(s.github_requests ?? {})
    .filter((x) => x.sharing === "team" || x.requested_by === p.user)
    .sort((a, b) => b.requested_at - a.requested_at)[0]
  if (!r) return null
  return {
    requested_at: r.requested_at,
    expires_at: r.requested_at + GITHUB_INSTALL_REQUEST_TTL_MS,
    requested_by: r.requested_by,
    github_login: r.github_user?.login ?? null,
    links_on_approval: r.github_user !== null && r.approved_account === undefined && !policyOf(s).github.require_org_admin,
    approved_account: r.approved_account ?? null,
    detail: r.approved_detail ?? null
  }
}
