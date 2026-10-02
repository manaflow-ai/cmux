import { createHash } from "node:crypto"
import { canonicalJson, type Reject, type ReduceContext } from "@cmux/ownership"
import { policyValueSchema, type PolicyKey } from "@cmux/protocol"
import { Exit, Schema } from "effect"
import { currentPolicy, integrationSlice, POLICY_HISTORY_LIMIT, type PolicyState, type PolicyValues, type PolicyVersion } from "./team-policy.ts"

/**
 * TeamDO -> ConnectionDO integration projection (spec/enterprise.md 4.6).
 *
 * Before its first push, TeamDO copies the integration values ConnectionDO
 * enforces today into TeamPolicy (keys the admin has not set there), so the
 * first TeamPolicy version can never widen repository access (review HIGH 1,
 * decision b). After that, TeamDO pushes only when the integration slice
 * changes, so an unrelated key (telemetry.level) never touches ConnectionDO.
 */
export interface IntegrationSyncState extends PolicyState {
  readonly integration_seeded?: boolean
  /** Hash of the slice ConnectionDO last acknowledged (or held when seeded). */
  readonly integration_synced_hash?: string
  readonly integration_synced_version?: number
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
  if (fields.github.repo_allowlist && fields.github.repo_allowlist.length > 0) set("github.repoAllowList", fields.github.repo_allowlist)
  return out
}

type Result<S> = { ok: true; state: S; value: unknown; changed?: boolean; audit?: { summary: string; detail: unknown } } | ({ ok: false } & Reject)

/** System op `team.policy.integration_seed {policy}`: copies ConnectionDO's values once. */
export const reduceIntegrationSeed = <S extends IntegrationSyncState>(state: S, params: unknown, ctx: ReduceContext): Result<S> => {
  if (state.integration_seeded) return { ok: true, state, value: { seeded: false }, changed: false }
  const fields = (params as { policy?: IntegrationFields })?.policy
  if (!fields || typeof fields !== "object" || !fields.github) return { ok: false, code: "validation.invalid", message: "policy required" }
  const current = currentPolicy(state)
  const copied = keysFromConnectionPolicy(fields)
  const added = (Object.keys(copied) as Array<PolicyKey>).filter((k) => current.values[k] === undefined).sort()
  const values = { ...current.values } as Record<string, unknown>
  for (const k of added) values[k] = copied[k]
  const seededState = { ...state, integration_seeded: true, integration_synced_hash: sliceHash(fields) }
  if (added.length === 0) return { ok: true, state: seededState, value: { seeded: true, copied: [] } }
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
  const p = params as { version?: unknown; slice_hash?: unknown }
  if (typeof p?.version !== "number" || !Number.isInteger(p.version) || typeof p.slice_hash !== "string") {
    return { ok: false, code: "validation.invalid", message: "version and slice_hash required" }
  }
  if (p.version < (state.integration_synced_version ?? 0)) return { ok: true, state, value: { version: p.version }, changed: false }
  if (p.version === state.integration_synced_version && p.slice_hash === state.integration_synced_hash) return { ok: true, state, value: { version: p.version }, changed: false }
  return { ok: true, state: { ...state, integration_synced_version: p.version, integration_synced_hash: p.slice_hash }, value: { version: p.version } }
}
