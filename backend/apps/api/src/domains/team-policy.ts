import type { Reject, ReduceContext } from "@cmux/ownership"
import {
  policyProductDefaults,
  policyValueSchema,
  TeamPolicyRollback,
  TeamPolicyUpdate,
  type PolicyKey,
  type TeamPolicy,
  type TeamPolicyValues,
  type TeamPolicyVersion
} from "@cmux/protocol"
import { Exit, Schema } from "effect"
import { canonicalJson } from "@cmux/ownership"
import { decodeParams, reject } from "./common.ts"
import type { SsoState } from "./team-sso.ts"

export type Policy = typeof TeamPolicy.Type
export type PolicyValues = typeof TeamPolicyValues.Type
export type PolicyVersion = typeof TeamPolicyVersion.Type

/** Versions kept in TeamDO state (and so in every snapshot) for get and rollback; the full history is the audit projection (audit_events). */
export const POLICY_HISTORY_LIMIT = 20
/** All TeamDO state is one SQLite row (2 MB); the policy and its 20 history copies must stay far below it. */
export const MAX_POLICY_BYTES = 64 * 1024
/** UTF-8 bytes of the canonical JSON (not UTF-16 code units). */
export const policyBytes = (values: unknown): number => new TextEncoder().encode(canonicalJson(values)).length

export const initialPolicy = (): Policy => ({ version: 0, values: {}, updated_at: null, updated_by: null })

export interface PolicyState {
  readonly policy?: Policy
  readonly policy_history?: ReadonlyArray<PolicyVersion>
}

/** Objects written before team policy existed have no policy field. */
export const currentPolicy = (state: PolicyState): Policy => state.policy ?? initialPolicy()

/** The link services this team lets members reach on its Cloud machines (cloud.connectServices; a team nobody created has the product default). */
export const connectServicesOf = (state: PolicyState | undefined): ReadonlyArray<string> => {
  const v = (state ? currentPolicy(state).values : {}) as Record<string, { value?: unknown } | undefined>
  const set = v["cloud.connectServices"]?.value
  return Array.isArray(set) ? (set as Array<string>) : (policyProductDefaults["cloud.connectServices"] ?? [])
}

type Result<S> = { ok: true; state: S; value: unknown; changed?: boolean } | ({ ok: false } & Reject)

const invalid = (message: string, details?: unknown) => reject("policy.invalid", message, details)

/**
 * Whether the team can serve SSO sign-in now: an active connection that serves at least one of the
 * team's verified domains (the condition sign-in discovery and the OIDC callback need). Enforced SSO
 * is accepted only while this holds. The sign-in gate applies it to a user bound by email domain
 * only while a connection serves that very domain (TeamDO.signInRules), so a disabled connection or
 * a lapsed or unserved domain never locks its users out.
 */
export const ssoServable = (state: SsoState): boolean =>
  Object.values(state.sso_connections ?? {}).some((c) => c.state === "active" && c.domains.some((d) => state.domains?.[d]?.state === "verified"))

/** A team-scoped boolean key is on only with mode `enforced`; a recommended (default) value enforces nothing. */
export const enforcedOn = (values: PolicyValues, key: "sso.enforce" | "sso.enforceForOwners"): boolean => values[key]?.value === true && values[key]?.mode === "enforced"

/** Cross-key invariants the schema alone cannot express (spec/enterprise.md 4.3). */
const checkInvariants = (values: PolicyValues, state: SsoState): Reject | undefined => {
  if ((enforcedOn(values, "sso.enforce") || enforcedOn(values, "sso.enforceForOwners")) && !ssoServable(state)) {
    return { code: "policy.invalid", message: "sso.enforce needs an active SSO connection that serves a verified domain" }
  }
  if (enforcedOn(values, "sso.enforceForOwners") && !enforcedOn(values, "sso.enforce")) {
    return { code: "policy.invalid", message: "sso.enforceForOwners needs sso.enforce" }
  }
  return undefined
}

/** Applies a validated values document as the next version; no-op when nothing changes. */
const commitVersion = <S extends PolicyState>(
  state: S,
  next: PolicyValues,
  ctx: ReduceContext,
  meta: { reason: string | null; rollback_of: number | null }
): Result<S> => {
  const current = currentPolicy(state)
  const keys = new Set([...Object.keys(current.values), ...Object.keys(next)]) as Set<PolicyKey>
  const changed = [...keys]
    .filter((k) => canonicalJson(current.values[k] ?? null) !== canonicalJson(next[k] ?? null))
    .sort()
  if (changed.length === 0) return { ok: true, state, value: current, changed: false }
  const actor = ctx.principal.user ?? ctx.principal.identity
  const policy: Policy = { version: current.version + 1, values: next, updated_at: ctx.now, updated_by: actor }
  const entry: PolicyVersion = { version: policy.version, values: next, changed, actor, at: ctx.now, reason: meta.reason, rollback_of: meta.rollback_of }
  const history = [entry, ...(state.policy_history ?? [])].slice(0, POLICY_HISTORY_LIMIT)
  return { ok: true, state: { ...state, policy, policy_history: history }, value: policy }
}

export const reducePolicyUpdate = <S extends PolicyState & SsoState>(state: S, params: unknown, ctx: ReduceContext): Result<S> => {
  const d = decodeParams<typeof TeamPolicyUpdate.params.Type>(TeamPolicyUpdate, params)
  if (!d.ok) return d
  const current = currentPolicy(state)
  if (d.value.expected_version !== current.version) {
    return reject("revision.conflict", `team policy is at version ${current.version}`, { version: current.version })
  }
  const seen = new Set<string>()
  const next: Record<string, unknown> = { ...current.values }
  for (const change of d.value.changes) {
    if (seen.has(change.key)) return invalid(`${change.key} appears twice`)
    seen.add(change.key)
    if (change.value === null) {
      delete next[change.key]
      continue
    }
    const exit = Schema.decodeUnknownExit(policyValueSchema(change.key) as unknown as Schema.Codec<unknown, unknown>)(change.value)
    if (!Exit.isSuccess(exit)) return invalid(`${change.key}: invalid value`, { key: change.key, cause: String(exit.cause) })
    // A Record silently drops keys that fail its key check; refuse instead.
    if (change.key === "device.settings") {
      const given = Object.keys(((change.value as { value?: unknown }).value ?? {}) as object)
      const kept = Object.keys(((exit.value as { value?: unknown }).value ?? {}) as object)
      if (given.length !== kept.length) return invalid("device.settings keys must be cmux.json key paths such as ui.animationSpeed", { key: change.key })
    }
    next[change.key] = exit.value
  }
  const size = policyBytes(next)
  if (size > MAX_POLICY_BYTES) return invalid(`team policy is ${size} bytes; the limit is ${MAX_POLICY_BYTES}`)
  const values = next as PolicyValues
  const bad = checkInvariants(values, state)
  if (bad) return { ok: false, ...bad }
  return commitVersion(state, values, ctx, { reason: d.value.reason ?? null, rollback_of: null })
}

export const reducePolicyRollback = <S extends PolicyState & SsoState>(state: S, params: unknown, ctx: ReduceContext): Result<S> => {
  const d = decodeParams<typeof TeamPolicyRollback.params.Type>(TeamPolicyRollback, params)
  if (!d.ok) return d
  const current = currentPolicy(state)
  if (d.value.expected_version !== current.version) {
    return reject("revision.conflict", `team policy is at version ${current.version}`, { version: current.version })
  }
  const target = d.value.version === 0 ? { values: {} as PolicyValues } : (state.policy_history ?? []).find((v) => v.version === d.value.version)
  if (!target) return reject("selector.not_found", `policy version ${d.value.version} is not retained`)
  // Invariants are rechecked: a version valid then may lock the team out now.
  const bad = checkInvariants(target.values, state)
  if (bad) return { ok: false, ...bad }
  return commitVersion(state, target.values, ctx, { reason: d.value.reason ?? null, rollback_of: d.value.version })
}

/** Read of a version for team.policy.get. */
export const policyAt = (state: PolicyState, version?: number): Policy | undefined => {
  const current = currentPolicy(state)
  if (version === undefined || version === current.version) return current
  const v = (state.policy_history ?? []).find((h) => h.version === version)
  return v ? { version: v.version, values: v.values, updated_at: v.at, updated_by: v.actor } : undefined
}

/**
 * The integration slice of a policy, in ConnectionDO's TeamIntegrationPolicy
 * fields. TeamDO is the single writer of these values; ConnectionDO holds them
 * as an enforcement projection (spec/enterprise.md 4.6). Team-scoped keys have
 * no user override, so `default` and `enforced` both apply team-wide.
 */
export const integrationSlice = (values: PolicyValues) => {
  const providers = values["integrations.allowedProviders"]?.value
  const allow = values["github.repoAllowList"]?.value
  return {
    allowed_providers: providers === undefined || providers === "all" ? null : [...providers],
    github: {
      scope: values["github.repoScope"]?.value ?? "linking_user_repos",
      require_org_admin: values["github.requireOrgAdmin"]?.value ?? false,
      // "none" denies every repository ([] in ConnectionDO); an empty list adds no limit (null).
      repo_allowlist: allow === "none" ? [] : allow === undefined || allow.length === 0 ? null : [...allow]
    }
  }
}
