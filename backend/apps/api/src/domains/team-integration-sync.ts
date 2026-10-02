import { createHash } from "node:crypto"
import { canonicalJson, type Reject, type ReduceContext } from "@cmux/ownership"
import { policyValueSchema, type PolicyKey } from "@cmux/protocol"
import { Exit, Schema } from "effect"
import { currentPolicy, integrationSlice, MAX_POLICY_BYTES, POLICY_HISTORY_LIMIT, policyBytes, type PolicyState, type PolicyValues, type PolicyVersion } from "./team-policy.ts"

/**
 * TeamDO -> ConnectionDO integration projection (spec/enterprise.md 4.6).
 *
 * Before its first push, TeamDO adopts ConnectionDO's policy: one ConnectionDO
 * RPC returns the current values and locks them (source team_policy), so no
 * admin edit can land between the read and the push and ConnectionDO has one
 * writer from then on (review P1-1). TeamDO copies those values into TeamPolicy
 * (keys the admin has not set there), so the first version never widens
 * repository access (review HIGH 1, P1-2), then pushes once. After that it
 * pushes only when the integration slice changes.
 */
export interface IntegrationSyncState extends PolicyState {
  readonly integration_seeded?: boolean
  /** Hash of the slice ConnectionDO last acknowledged (or held when seeded). */
  readonly integration_synced_hash?: string
  readonly integration_synced_version?: number
  /** ConnectionDO is locked by SSO or MDM, which wins over TeamPolicy (reported, never replaced). */
  readonly integration_managed_by?: "sso" | "mdm" | null
  /** ConnectionDO's lock version TeamDO last recorded (notices may arrive out of order). */
  readonly integration_lock_version?: number
  /** Admin release requests (team.integration.release_lock) and the last one ConnectionDO carried out. */
  readonly integration_release_requested?: number
  readonly integration_release_done?: number
}

export type IntegrationFields = ReturnType<typeof integrationSlice>

export const sliceHash = (slice: IntegrationFields): string => createHash("sha256").update(canonicalJson(slice)).digest("base64url")

/** True when TeamDO owes ConnectionDO work: seeding first, then any slice change. */
export const integrationSyncPending = (state: IntegrationSyncState): boolean => {
  const policy = currentPolicy(state)
  if (policy.version === 0) return false
  if (!state.integration_seeded) return true
  return sliceHash(integrationSlice(policy.values)) !== state.integration_synced_hash
}

const decode = (key: PolicyKey, value: unknown) => {
  const exit = Schema.decodeUnknownExit(policyValueSchema(key) as unknown as Schema.Codec<unknown, unknown>)({ value, mode: "enforced" })
  return Exit.isSuccess(exit) ? exit.value : undefined
}

/** TeamPolicy keys equivalent to ConnectionDO fields that differ from the product default. */
export const keysFromConnectionPolicy = (fields: IntegrationFields): Partial<Record<PolicyKey, unknown>> => {
  const out: Partial<Record<PolicyKey, unknown>> = {}
  const set = (key: PolicyKey, value: unknown) => {
    const v = decode(key, value)
    if (v !== undefined) out[key] = v
  }
  if (fields.allowed_providers !== null) set("integrations.allowedProviders", fields.allowed_providers)
  if (fields.github.scope !== "linking_user_repos") set("github.repoScope", fields.github.scope)
  if (fields.github.require_org_admin) set("github.requireOrgAdmin", true)
  // [] in ConnectionDO denies every repository: copy it as "none", never drop it.
  if (fields.github.repo_allowlist) set("github.repoAllowList", fields.github.repo_allowlist.length === 0 ? "none" : fields.github.repo_allowlist)
  return out
}

type Result<S> = { ok: true; state: S; value: unknown; changed?: boolean; audit?: { summary: string; detail: unknown } } | ({ ok: false } & Reject)

/** System op `team.policy.integration_seed {policy}`: copies ConnectionDO's values once. */
export const reduceIntegrationSeed = <S extends IntegrationSyncState>(state: S, params: unknown, ctx: ReduceContext): Result<S> => {
  if (state.integration_seeded) return { ok: true, state, value: { seeded: false }, changed: false }
  const fields = (params as { policy?: IntegrationFields })?.policy
  if (!fields || typeof fields !== "object" || !fields.github) return { ok: false, code: "validation.invalid", message: "policy required" }
  // Values held by an SSO or MDM lock are not admin choices: nothing is copied into TeamPolicy.
  const managedBy = (params as { managed_by?: unknown }).managed_by
  if (managedBy === "sso" || managedBy === "mdm") {
    return { ok: true, state: { ...state, integration_seeded: true, integration_synced_hash: undefined, integration_managed_by: managedBy }, value: { seeded: true, copied: [] } }
  }
  const current = currentPolicy(state)
  const copied = keysFromConnectionPolicy(fields)
  const added = (Object.keys(copied) as Array<PolicyKey>).filter((k) => current.values[k] === undefined).sort()
  const values = { ...current.values } as Record<string, unknown>
  for (const k of added) values[k] = copied[k]
  // No acknowledged hash: the first push always follows, so ConnectionDO holds exactly TeamPolicy's slice.
  const seededState = { ...state, integration_seeded: true, integration_synced_hash: undefined }
  if (added.length === 0) return { ok: true, state: seededState, value: { seeded: true, copied: [] } }
  // An oversized copy is a visible reject (the sync stays pending and backs off), never a failed commit.
  if (policyBytes(values) > MAX_POLICY_BYTES) return { ok: false, code: "policy.invalid", message: "the integration policy copied into the team policy exceeds the size limit" }
  const actor = ctx.principal.identity
  const policy = { version: current.version + 1, values: values as PolicyValues, updated_at: ctx.now, updated_by: actor }
  const entry: PolicyVersion = { version: policy.version, values: policy.values, changed: added, actor, at: ctx.now, reason: "copied from the integration policy before the first push", rollback_of: null }
  return {
    ok: true,
    state: { ...seededState, policy, policy_history: [entry, ...(state.policy_history ?? [])].slice(0, POLICY_HISTORY_LIMIT) },
    value: { seeded: true, copied: added },
    audit: { summary: `policy v${policy.version}: copied ${added.join(", ")} from the integration policy`, detail: { version: policy.version, changed: added, values: policy.values } }
  }
}

/** System op `team.policy.integration_synced {version, slice_hash}`. */
export const reduceIntegrationSynced = <S extends IntegrationSyncState>(state: S, params: unknown): Result<S> => {
  const p = params as { version?: unknown; slice_hash?: unknown; managed_by?: unknown }
  const managedBy = p?.managed_by === "sso" || p?.managed_by === "mdm" ? p.managed_by : null
  if (typeof p?.version !== "number" || !Number.isInteger(p.version) || typeof p.slice_hash !== "string") {
    return { ok: false, code: "validation.invalid", message: "version and slice_hash required" }
  }
  if (p.version < (state.integration_synced_version ?? 0)) return { ok: true, state, value: { version: p.version }, changed: false }
  if (p.version === state.integration_synced_version && p.slice_hash === state.integration_synced_hash && managedBy === (state.integration_managed_by ?? null)) {
    return { ok: true, state, value: { version: p.version }, changed: false }
  }
  return { ok: true, state: { ...state, integration_synced_version: p.version, integration_synced_hash: p.slice_hash, integration_managed_by: managedBy }, value: { version: p.version } }
}

/** System op `team.policy.integration_lock {managed_by, version}`: ConnectionDO's notice. */
export const reduceIntegrationLock = <S extends IntegrationSyncState>(state: S, params: unknown): Result<S> => {
  const p = params as { managed_by?: unknown; version?: unknown }
  const managedBy = p?.managed_by === "sso" || p?.managed_by === "mdm" ? p.managed_by : null
  if (typeof p?.version !== "number" || !Number.isInteger(p.version)) return { ok: false, code: "validation.invalid", message: "version required" }
  if (p.version <= (state.integration_lock_version ?? 0)) return { ok: true, state, value: { version: p.version }, changed: false }
  // A changed lock invalidates the acknowledged slice, so TeamDO pushes its policy again
  // (a no-op under a lock, the team policy once the lock is gone).
  return { ok: true, state: { ...state, integration_lock_version: p.version, integration_managed_by: managedBy, integration_synced_hash: undefined }, value: { version: p.version } }
}

/** Admin op `team.integration.release_lock`: records the request (audited by the caller). */
export const reduceReleaseLock = <S extends IntegrationSyncState>(state: S): Result<S> => {
  const held = state.integration_managed_by
  if (held !== "sso" && held !== "mdm") return { ok: false, code: "selector.not_found", message: "the integration policy has no SSO or MDM lock" }
  const request = (state.integration_release_requested ?? 0) + 1
  return {
    ok: true,
    state: { ...state, integration_release_requested: request },
    value: { released: held },
    audit: { summary: `released the ${held} lock on the integration policy`, detail: { released: held, request } }
  }
}

/** System op `team.integration.release_done {request}`. */
export const reduceReleaseDone = <S extends IntegrationSyncState>(state: S, params: unknown): Result<S> => {
  const r = (params as { request?: unknown })?.request
  if (typeof r !== "number" || r <= (state.integration_release_done ?? 0)) return { ok: true, state, value: { request: r }, changed: false }
  return { ok: true, state: { ...state, integration_release_done: r }, value: { request: r } }
}

export const releasePending = (state: IntegrationSyncState) => (state.integration_release_requested ?? 0) > (state.integration_release_done ?? 0)
