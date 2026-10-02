import type { OutboxItem, Principal, ReduceContext, ReduceResult } from "@cmux/ownership"
import {
  AppApprovalDecide,
  AppGrantSet,
  AppHide,
  AppInstallOp,
  AppPolicySet,
  AppRemove,
  AppUpdate,
  ResolvedRelease,
  type AppApproval,
  type AppInstall,
  type AppPolicy,
  type AppTier
} from "@cmux/protocol"
import { Exit, Schema } from "effect"
import { decodeParams, reject } from "./common.ts"

/**
 * Installs, app grants and agent approvals (spec app-platform.md sections 10
 * to 12, D48). One pure reducer for both owners: UserDO holds personal
 * installs, TeamDO team installs plus the team app policy. Each owner keeps
 * this slice inside its own state and is the single writer of its
 * `app_installs` rows.
 *
 * Releases come from AppDO. The owner asks AppDO before deciding (OwnerDO
 * `resolve` hook) and the engine hands the answer to this reducer as
 * `params.resolved` (recorded in the event, not in the idempotency hash). So
 * the reducer is pure, a replayed request returns its first decision, and a
 * client can never supply the release it is granted.
 */

export interface AppsSlice {
  readonly installs: Readonly<Record<string, AppInstall>>
  readonly approvals: Readonly<Record<string, AppApproval>>
  /** Team owners only. */
  readonly policy?: AppPolicy
  /**
   * User owners only: the user's changes to first-party apps installed by
   * default (removed, hidden). Nothing is recorded for a default app the user
   * never touched.
   */
  readonly defaults?: Readonly<Record<string, DefaultPref>>
}

export interface DefaultPref {
  readonly removed_at: number | null
  readonly hidden: boolean
}

export const emptyApps: AppsSlice = { installs: {}, approvals: {} }
export const defaultPolicy: AppPolicy = { allowed_tiers: null, allowlist: null, blocklist: [] }

export interface InstallsOwner {
  readonly scope: "user" | "team"
  /** The user id (personal) or the team id. */
  readonly scopeId: string
  /** May this principal change the set? (the user themself; for a team, an owner or admin) */
  readonly canManage: boolean
}

/** How long an agent's request waits for the human (spec section 12: default 10 minutes). */
export const APPROVAL_TTL_MS = 10 * 60_000
/** Decided and expired approvals kept for display; pending ones are never dropped before they expire. */
const MAX_FINISHED_APPROVALS = 50

/**
 * Is the actor an agent? Agent principals (grant/agent class) and any request
 * from an MCP client. Gap: until the actor stamp lands (identity spec section
 * 6), a local agent using the CLI with origin `cli` is indistinguishable from
 * the user's own CLI; `origin` is client-declared.
 */
export const isAgentActor = (p: Principal, origin: string): boolean => p.kind === "agent" || p.agent !== undefined || origin === "mcp"

/** Which release the owner must resolve before deciding this op, or null for none. */
export const releaseSelector = (slice: AppsSlice | undefined, op: string, params: unknown): { app: string; version?: string; range?: string } | null => {
  const p = (params ?? {}) as { app?: unknown; version?: unknown; version_range?: unknown; approval?: unknown }
  const s = slice ?? emptyApps
  switch (op) {
    case "app.install":
      return typeof p.app === "string" ? { app: p.app, range: typeof p.version_range === "string" ? p.version_range : "*" } : null
    case "app.update": {
      if (typeof p.app !== "string") return null
      if (typeof p.version === "string") return { app: p.app, version: p.version }
      const cur = s.installs[p.app]
      return { app: p.app, range: cur?.version_range ?? "*" }
    }
    case "app.approval.decide": {
      const a = typeof p.approval === "string" ? s.approvals[p.approval] : undefined
      return a ? { app: a.app, version: a.version } : null
    }
    default:
      return null
  }
}

/**
 * For app.hide, app.unhide, app.remove and app.install on a user owner: is the
 * app one of the deployment's default first-party apps? The owner answers
 * (`resolved.default`), never the client.
 */
const isDefaultApp = (params: unknown, owner: InstallsOwner): boolean =>
  owner.scope === "user" && (params as { resolved?: { default?: unknown } } | null)?.resolved?.default === true

const resolvedOf = (params: unknown): ResolvedRelease | null | "invalid" => {
  const r = (params as { resolved?: unknown } | null)?.resolved
  if (r === null || r === undefined) return null
  const exit = Schema.decodeUnknownExit(ResolvedRelease)(r)
  return Exit.isSuccess(exit) ? exit.value : "invalid"
}

/** Tiers a team admits when its policy names none: unverified apps need the tier listed explicitly. */
const DEFAULT_TEAM_TIERS: ReadonlyArray<AppTier> = ["first-party", "verified"]
/** Pending agent requests per owner; more are refused until some are decided or expire. */
export const MAX_PENDING_APPROVALS = 20

const tierAllowed = (policy: AppPolicy, tier: AppTier, acceptUnverified: boolean): boolean => {
  if (tier === "unverified" && !acceptUnverified) return false
  return (policy.allowed_tiers ?? DEFAULT_TEAM_TIERS).includes(tier)
}

/** The team app policy and the unverified warning, for an install, update or approval. */
const policyProblem = (owner: InstallsOwner, policy: AppPolicy | undefined, app: string, tier: AppTier, acceptUnverified: boolean) => {
  if (tier === "unverified" && !acceptUnverified) return reject("app.unverified", `${app} is unverified; install it only with accept_unverified after warning the user`)
  if (owner.scope === "team") {
    const p: AppPolicy = policy ?? defaultPolicy
    if (p.blocklist.includes(app)) return reject("policy.denied", `the team app policy blocks ${app}`)
    if (p.allowlist && !p.allowlist.includes(app)) return reject("policy.denied", `the team app policy allows only listed apps`)
    if (!tierAllowed(p, tier, acceptUnverified)) return reject("policy.denied", `the team app policy does not allow ${tier} apps`)
  }
  return undefined
}

/** granted must hold every required scope and nothing outside required + optional. */
export const scopeProblem = (granted: ReadonlyArray<string>, required: ReadonlyArray<string>, optional: ReadonlyArray<string>) => {
  const missing = required.filter((s) => !granted.includes(s))
  const unknown = granted.filter((s) => !required.includes(s) && !optional.includes(s))
  if (missing.length === 0 && unknown.length === 0) return undefined
  return reject("scope.invalid", `${missing.length ? `missing required ${missing.join(", ")}` : ""}${missing.length && unknown.length ? "; " : ""}${unknown.length ? `not requested by this version: ${unknown.join(", ")}` : ""}`, { missing, unknown })
}

const uniqSorted = (xs: ReadonlyArray<string>) => [...new Set(xs)].sort()
const sameSet = (a: ReadonlyArray<string>, b: ReadonlyArray<string>) => JSON.stringify(uniqSorted(a)) === JSON.stringify(uniqSorted(b))

const installOutbox = (owner: InstallsOwner, i: AppInstall, removedAt: number | null): OutboxItem => ({
  kind: "app_install.upsert",
  entity: `${i.app}:${owner.scope}:${owner.scopeId}`,
  // Counts, not contents: the projection never sees granted scopes.
  payload: { app: i.app, scope_kind: owner.scope, scope_id: owner.scopeId, version: i.version, installed_at: i.installed_at, removed_at: removedAt, hidden: i.hidden ?? false }
})

const makeInstall = (owner: InstallsOwner, r: ResolvedRelease, scopes: ReadonlyArray<string>, range: string, prev: AppInstall | undefined, by: string, now: number): AppInstall => ({
  app: r.app,
  scope: owner.scope,
  version: r.version,
  version_range: range,
  tier: r.tier,
  scopes_granted: uniqSorted(scopes),
  version_scopes: [...r.scopes],
  version_optional_scopes: [...r.optional_scopes],
  bundle_url: r.bundle_url,
  bundle_sha256: r.bundle_sha256,
  app_revision: r.app_revision,
  installed_by: prev?.installed_by ?? by,
  installed_at: prev?.installed_at ?? now,
  updated_at: now,
  hidden: prev?.hidden ?? false
})

/** Keeps every unexpired pending approval and the newest finished ones. */
const pruneApprovals = (approvals: Readonly<Record<string, AppApproval>>, now: number): Record<string, AppApproval> => {
  const all = Object.values(approvals)
  const live = all.filter((a) => a.status === "pending" && a.expires_at > now)
  const finished = all
    .filter((a) => !(a.status === "pending" && a.expires_at > now))
    .sort((a, b) => (b.decided_at ?? b.expires_at) - (a.decided_at ?? a.expires_at))
    .slice(0, MAX_FINISHED_APPROVALS)
  return Object.fromEntries([...live, ...finished].map((a) => [a.id, a]))
}

type Result = ReduceResult<AppsSlice>

/**
 * Lawrence's decision (2026-10-02): until owners stamp the actor (identity
 * spec section 6), only the user's own client installs or grows an app's
 * scopes. `origin` is client-declared, so an agent could otherwise claim to
 * be the user. Every install, scope-growing update and approval decision
 * needs origin `user` from a principal that is not an agent.
 */
export const userOnly = (p: Principal, origin: string) =>
  origin === "user" && !isAgentActor(p, origin)
    ? undefined
    : reject("app.install.user_only", "install apps and grant them new permissions from the cmux App Store (palette) or the web store; agents and the CLI cannot do this yet")

/**
 * The agent approval request (D48). Unreachable while `userOnly` blocks
 * agent-initiated installs; it reopens when the actor stamp lands. Exported
 * so its rules stay tested.
 */
export const requestApproval = (slice: AppsSlice, owner: InstallsOwner, ctx: ReduceContext, kind: AppApproval["kind"], r: ResolvedRelease, scopes: ReadonlyArray<string>, added: ReadonlyArray<string>, range: string): Result => {
  const p = ctx.principal
  const pending = Object.values(slice.approvals).filter((a) => a.status === "pending" && a.expires_at > ctx.now)
  const baseVersion = slice.installs[r.app]?.version ?? null
  // The same request again (a retry with a new key, a looping agent) gets the waiting one back.
  const same = pending.find(
    (a) => a.kind === kind && a.app === r.app && a.version === r.version && a.base_version === baseVersion && a.requested_by.identity === p.identity && sameSet(a.scopes, scopes)
  )
  if (same) return { ok: true, state: slice, value: { status: "approval_required", approval: same }, changed: false }
  if (pending.length >= MAX_PENDING_APPROVALS) return reject("approval.limit", `${MAX_PENDING_APPROVALS} app requests already wait for a decision`, { pending: pending.length })
  const approval: AppApproval = {
    id: ctx.newId("appr"),
    kind,
    app: r.app,
    scope: owner.scope,
    version: r.version,
    version_range: range,
    scopes: uniqSorted(scopes),
    added: uniqSorted(added),
    base_version: baseVersion,
    requested_by: { identity: p.identity, install: p.install ?? null, agent: p.agent ?? null, origin: ctx.origin },
    status: "pending",
    created_at: ctx.now,
    expires_at: ctx.now + APPROVAL_TTL_MS,
    decided_by: null,
    decided_at: null
  }
  return { ok: true, state: { ...slice, approvals: { ...pruneApprovals(slice.approvals, ctx.now), [approval.id]: approval } }, value: { status: "approval_required", approval } }
}

const applyInstall = (slice: AppsSlice, owner: InstallsOwner, install: AppInstall, extra: Partial<AppsSlice> = {}): Result => ({
  ok: true,
  state: { ...slice, ...extra, installs: { ...slice.installs, [install.app]: install } },
  value: { status: "installed", install },
  outbox: [installOutbox(owner, install, null)]
})

export const reduceApps = (slice: AppsSlice, op: string, params: unknown, ctx: ReduceContext, owner: InstallsOwner): Result => {
  const p = ctx.principal
  const agent = isAgentActor(p, ctx.origin)
  if (!owner.canManage) return reject("auth.forbidden", owner.scope === "team" ? "team installs need a team owner or admin" : "not this user")
  switch (op) {
    case "app.install": {
      const d = decodeParams<typeof AppInstallOp.params.Type>(AppInstallOp, params)
      if (!d.ok) return d
      const v = d.value
      const blocked = userOnly(p, ctx.origin)
      if (blocked) return blocked
      const r = resolvedOf(params)
      if (r === "invalid") return reject("operation.failed", "the release lookup returned an invalid record")
      if (!r) return reject("selector.not_found", v.version_range ? `no published version of ${v.app} matches ${v.version_range}` : `app ${v.app} not found`)
      if (r.app !== v.app) return reject("operation.failed", "the release lookup answered for another app")
      if (r.yanked) return reject("app.yanked", `${r.app}@${r.version} is yanked`)
      const denied = policyProblem(owner, slice.policy, r.app, r.tier, v.accept_unverified === true)
      if (denied) return denied
      const bad = scopeProblem(v.scopes, r.scopes, r.optional_scopes)
      if (bad) return bad
      const range = v.version_range ?? "*"
      const cur = slice.installs[r.app]
      if (cur && cur.version === r.version && sameSet(cur.scopes_granted, v.scopes) && cur.version_range === range) {
        return { ok: true, state: slice, value: { status: "installed", install: cur }, changed: false }
      }
      // Unreachable behind userOnly; reopens with the actor stamp.
      if (agent) return requestApproval(slice, owner, ctx, "install", r, v.scopes, v.scopes.filter((s) => !(cur?.scopes_granted ?? []).includes(s)), range)
      // Installing a removed default app again clears its tombstone; the explicit install now rules.
      const pref = slice.defaults?.[r.app]
      const defaults = pref ? { ...slice.defaults, [r.app]: { removed_at: null, hidden: pref.hidden } } : undefined
      const install: AppInstall = { ...makeInstall(owner, r, v.scopes, range, cur, p.identity, ctx.now), hidden: cur?.hidden ?? pref?.hidden ?? false }
      return applyInstall(slice, owner, install, defaults ? { defaults } : {})
    }
    case "app.update": {
      const d = decodeParams<typeof AppUpdate.params.Type>(AppUpdate, params)
      if (!d.ok) return d
      const v = d.value
      const cur = slice.installs[v.app]
      if (!cur) return reject("selector.not_found", `${v.app} is not installed`)
      const r = resolvedOf(params)
      if (r === "invalid") return reject("operation.failed", "the release lookup returned an invalid record")
      if (!r) return reject("selector.not_found", v.version ? `${v.app}@${v.version} not found` : `no published version of ${v.app} matches ${cur.version_range}`)
      if (r.app !== v.app) return reject("operation.failed", "the release lookup answered for another app")
      if (r.yanked) return reject("app.yanked", `${r.app}@${r.version} is yanked`)
      // An installed unverified app stays updatable: the user accepted the warning at install.
      const denied = policyProblem(owner, slice.policy, r.app, r.tier, cur.tier === "unverified")
      if (denied) return denied
      if (r.version === cur.version && v.accept_scopes === undefined) return { ok: true, state: slice, value: { status: "installed", install: cur }, changed: false }
      const allowed = [...r.scopes, ...r.optional_scopes]
      const accepted = v.accept_scopes ?? []
      const outside = accepted.filter((s) => !allowed.includes(s))
      if (outside.length > 0) return reject("scope.invalid", `not requested by ${r.version}: ${outside.join(", ")}`, { unknown: outside })
      // Scopes the new version still requests carry over; new required ones need consent.
      const granted = uniqSorted([...cur.scopes_granted.filter((s) => allowed.includes(s)), ...accepted])
      const needed = r.scopes.filter((s) => !granted.includes(s))
      if (needed.length > 0) return reject("scope.consent_required", `${r.app}@${r.version} needs ${needed.join(", ")}; pass them in accept_scopes after the user agrees`, { added: needed })
      const growth = granted.filter((s) => !cur.scopes_granted.includes(s))
      if (growth.length > 0) {
        const blocked = userOnly(p, ctx.origin)
        if (blocked) return blocked
      }
      // Unreachable behind userOnly; reopens with the actor stamp.
      if (agent && growth.length > 0) return requestApproval(slice, owner, ctx, "update", r, granted, growth, cur.version_range)
      return applyInstall(slice, owner, makeInstall(owner, r, granted, cur.version_range, cur, p.identity, ctx.now))
    }
    case "app.remove": {
      const d = decodeParams<typeof AppRemove.params.Type>(AppRemove, params)
      if (!d.ok) return d
      const app = d.value.app
      const cur = slice.installs[app]
      // A default first-party app stays removed (a tombstone), also after removing an explicit install of it.
      const pref = slice.defaults?.[app]
      const tombstone = isDefaultApp(params, owner) && (pref?.removed_at ?? null) === null
      const defaults = tombstone ? { ...slice.defaults, [app]: { removed_at: ctx.now, hidden: pref?.hidden ?? false } } : slice.defaults
      if (!cur && !tombstone) return { ok: true, state: slice, value: { app, removed: false }, changed: false }
      const { [app]: _gone, ...rest } = slice.installs
      return {
        ok: true,
        state: { ...slice, installs: rest, ...(defaults ? { defaults } : {}) },
        value: { app, removed: true },
        outbox: cur ? [installOutbox(owner, cur, ctx.now)] : []
      }
    }
    case "app.hide":
    case "app.unhide": {
      // Hiding grants nothing: any origin, agents included.
      const d = decodeParams<typeof AppHide.params.Type>(AppHide, params)
      if (!d.ok) return d
      if (owner.scope !== "user") return reject("validation.invalid", `${op} is for personal installs`)
      const want = op === "app.hide"
      const app = d.value.app
      const cur = slice.installs[app]
      if (cur) {
        if ((cur.hidden ?? false) === want) return { ok: true, state: slice, value: { app, hidden: want }, changed: false }
        const next: AppInstall = { ...cur, hidden: want, updated_at: ctx.now }
        return { ok: true, state: { ...slice, installs: { ...slice.installs, [app]: next } }, value: { app, hidden: want }, outbox: [installOutbox(owner, next, null)] }
      }
      const pref = slice.defaults?.[app] ?? { removed_at: null, hidden: false }
      if (!isDefaultApp(params, owner) || pref.removed_at !== null) return reject("selector.not_found", `${app} is not installed`)
      if (pref.hidden === want) return { ok: true, state: slice, value: { app, hidden: want }, changed: false }
      return { ok: true, state: { ...slice, defaults: { ...slice.defaults, [app]: { ...pref, hidden: want } } }, value: { app, hidden: want } }
    }
    case "app.grant.set": {
      const d = decodeParams<typeof AppGrantSet.params.Type>(AppGrantSet, params)
      if (!d.ok) return d
      if (p.kind !== "session" || ctx.origin !== "user") return reject("auth.forbidden", "app grants change only from the user's own client (origin user)")
      const cur = slice.installs[d.value.app]
      if (!cur) return reject("selector.not_found", `${d.value.app} is not installed`)
      const bad = scopeProblem(d.value.scopes, cur.version_scopes, cur.version_optional_scopes)
      if (bad) return bad
      if (sameSet(cur.scopes_granted, d.value.scopes)) return { ok: true, state: slice, value: cur, changed: false }
      const next: AppInstall = { ...cur, scopes_granted: uniqSorted(d.value.scopes), updated_at: ctx.now }
      return { ok: true, state: { ...slice, installs: { ...slice.installs, [cur.app]: next } }, value: next }
    }
    case "app.approval.decide": {
      const d = decodeParams<typeof AppApprovalDecide.params.Type>(AppApprovalDecide, params)
      if (!d.ok) return d
      const blocked = userOnly(p, ctx.origin)
      if (blocked) return blocked
      if (p.kind !== "session") return reject("auth.forbidden", "approvals are decided by a person in their own client, never by an agent")
      const a = slice.approvals[d.value.approval]
      if (!a) return reject("selector.not_found", "approval not found")
      if (a.status !== "pending") return reject("approval.decided", `this request was already ${a.status}`, { status: a.status })
      if (a.expires_at <= ctx.now) {
        // Recorded, so an agent waiting on the request sees it end.
        const expired: AppApproval = { ...a, status: "expired", decided_by: null, decided_at: ctx.now }
        return { ok: true, state: { ...slice, approvals: { ...slice.approvals, [a.id]: expired } }, value: { approval: expired, install: null } }
      }
      const decided: AppApproval = { ...a, status: d.value.decision === "approve" ? "approved" : "denied", decided_by: p.identity, decided_at: ctx.now }
      const approvals = { ...slice.approvals, [a.id]: decided }
      if (d.value.decision === "deny") return { ok: true, state: { ...slice, approvals }, value: { approval: decided, install: null } }
      // The install it was based on must be unchanged: approving must not undo a newer update or a removal.
      if ((slice.installs[a.app]?.version ?? null) !== a.base_version) {
        return reject("approval.stale", `${a.app} changed since the request (${a.base_version ?? "not installed"} then, ${slice.installs[a.app]?.version ?? "not installed"} now); deny it and let the agent ask again`)
      }
      // Re-check against the release as it is now: yanked since, policy changed since.
      const r = resolvedOf(params)
      if (r === "invalid") return reject("operation.failed", "the release lookup returned an invalid record")
      if (!r || r.app !== a.app || r.version !== a.version) return reject("selector.not_found", `${a.app}@${a.version} is no longer published`)
      if (r.yanked) return reject("app.yanked", `${r.app}@${r.version} was yanked after the request`)
      const cur = slice.installs[a.app]
      // The person approving sees the tier in the consent sheet, so that is the unverified warning.
      const denied = policyProblem(owner, slice.policy, r.app, r.tier, true)
      if (denied) return denied
      const bad = scopeProblem(a.scopes, r.scopes, r.optional_scopes)
      if (bad) return bad
      const install = makeInstall(owner, r, a.scopes, a.version_range, cur, a.requested_by.identity, ctx.now)
      return {
        ok: true,
        state: { ...slice, approvals, installs: { ...slice.installs, [install.app]: install } },
        value: { approval: decided, install },
        outbox: [installOutbox(owner, install, null)]
      }
    }
    case "app.policy.set": {
      if (owner.scope !== "team") return reject("validation.invalid", "app.policy.set is a team op")
      const d = decodeParams<typeof AppPolicySet.params.Type>(AppPolicySet, params)
      if (!d.ok) return d
      const cur = slice.policy ?? defaultPolicy
      const next: AppPolicy = {
        allowed_tiers: d.value.allowed_tiers === undefined ? cur.allowed_tiers : d.value.allowed_tiers === null ? null : uniqSorted(d.value.allowed_tiers) as Array<AppTier>,
        allowlist: d.value.allowlist === undefined ? cur.allowlist : d.value.allowlist === null ? null : uniqSorted(d.value.allowlist),
        blocklist: d.value.blocklist === undefined ? cur.blocklist : uniqSorted(d.value.blocklist)
      }
      if (JSON.stringify(next) === JSON.stringify(cur) && slice.policy) return { ok: true, state: slice, value: cur, changed: false }
      return { ok: true, state: { ...slice, policy: next }, value: next }
    }
    default:
      return reject("validation.invalid", `unknown op ${op}`)
  }
}

/** Read view for app.list: installed apps, unexpired pending approvals, and the team policy. */
export const appsView = (slice: AppsSlice | undefined, now: number, scope: "user" | "team") => {
  const s = slice ?? emptyApps
  return {
    // Records written before `hidden` existed read as not hidden.
    installs: Object.values(s.installs)
      .map((i) => ({ ...i, hidden: i.hidden ?? false }))
      .sort((a, b) => a.app.localeCompare(b.app)),
    approvals: Object.values(s.approvals)
      .filter((a) => a.status === "pending" && a.expires_at > now)
      .sort((a, b) => a.created_at - b.created_at),
    policy: scope === "team" ? (s.policy ?? defaultPolicy) : null,
    /** Internal: the Worker merges default apps with it and drops it from the answer. */
    ...(scope === "user" ? { default_prefs: s.defaults ?? {} } : {})
  }
}
