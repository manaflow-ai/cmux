import { createHash } from "node:crypto"
import type { Domain } from "@cmux/ownership"
import type { UserState } from "./user.ts"

/** Reducer-owned epochs, replayed with the JSON head; these are cache metadata, never grants. */
export interface InstallAuthorityState {
  readonly generation: string
  readonly incarnations: Readonly<Record<string, string>>
}

/** Exclude presentation and unrelated account state; include every install/grant admission input. */
const admission = (state: UserState, install: string): string => {
  const u = state.user, i = state.installs[install], g = i ? state.grants[i.grant] : undefined, k = i?.public_jwk
  return JSON.stringify([
    u ? [u.id, u.stack_user_id, u.email, u.email_verified === true, u.personal_team] : null,
    i ? [i.id, i.kind, i.grant, i.revoked_at, i.thumbprint, k?.kty, k?.crv, k?.x, k?.y,
      i.sso_team, i.bound_team, i.bound_machine, [...(i.capabilities ?? [])].sort()] : null,
    g ? [g.id, g.grantee, [...g.op_classes].sort(), g.approval, g.expires_at, g.revoked_at, g.created_from] : null
  ])
}

const generationOf = (state: UserState): bigint => {
  const generation = state.install_authority === undefined ? "0" : state.install_authority.generation
  if (typeof generation !== "string" || !/^(0|[1-9][0-9]{0,63})$/.test(generation)) throw new Error("invalid install authority generation")
  return BigInt(generation)
}

/** Persist changes atomically with the existing user head, preserving JSON-mirror replay. */
export const withInstallAuthority = (domain: Domain<UserState>): Domain<UserState> => ({
  ...domain,
  reduce: (state, op, params, ctx) => {
    const result = domain.reduce(state, op, params, ctx)
    if (!result.ok || result.changed === false) return result
    const next = result.state
    if (state.user === next.user && state.installs === next.installs && state.grants === next.grants) return result
    const changed = [...new Set([...Object.keys(state.installs), ...Object.keys(next.installs)])]
      .filter((install) => admission(state, install) !== admission(next, install))
    if (!changed.length) return result
    const generation = (generationOf(state) + 1n).toString()
    if (generation.length > 64) throw new Error("install authority generation exhausted")
    const incarnations = { ...state.install_authority?.incarnations }
    for (const install of changed) {
      if (next.installs[install]) incarnations[install] = `${generation}:${ctx.tx}`
      else delete incarnations[install]
    }
    // Readers re-derive the version on every call, so no notice is sent: a changed install simply
    // stops matching the version an earlier read returned.
    return { ...result, state: { ...next, install_authority: { generation, incarnations } } }
  }
})

/** Includes both current values and their incarnation, so an A→B→A change cannot replay A. */
export const installAuthorityVersion = (state: UserState, install: string): string => {
  const generation = generationOf(state)
  const incarnation = state.install_authority?.incarnations[install]
  if (incarnation !== undefined) {
    const stamp = /^([1-9][0-9]{0,63}):[A-Za-z0-9_-]{22}$/.exec(incarnation)
    if (!stamp || BigInt(stamp[1]!) > generation) throw new Error("invalid install authority incarnation")
  }
  return createHash("sha256").update(JSON.stringify(["cmux-install-authority-v1", install, admission(state, install), incarnation ?? "legacy"])).digest("hex")
}
