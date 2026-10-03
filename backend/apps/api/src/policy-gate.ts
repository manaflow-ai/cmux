import type { Principal } from "@cmux/ownership"
import type { Env } from "./env.ts"
import type { SignInRules } from "./team-do.ts"

/**
 * Server-side team policy at sign-in (enterprise P17-4, coordinator decisions 2026-10-03):
 * - sso.enforce: a Stack session needs this team's SSO claim (`cmux_sso_team`, stamped by the
 *   enterprise OIDC callback); owners are exempt unless sso.enforceForOwners.
 * - updates.minimumVersion: /v1/auth/token and wire connects send `x-cmux-client-version`; an
 *   older or (only when the key is set) missing version answers `client.too_old`.
 * - agents.allowedClasses: grants are minted only for listed classes (mux = chief creation and
 *   its MuxDO bind; agent = install.register for agent kinds; run = automation run grants).
 * Rules come from the principal's TeamDO and are cached per isolate for 30 s.
 */
const TTL_MS = 30_000
const cache = new Map<string, { at: number; rules: SignInRules }>()

export const signInRules = async (env: Env, team: string, user: string): Promise<SignInRules> => {
  const key = `${team}\u0000${user}`
  const hit = cache.get(key)
  if (hit && Date.now() - hit.at < TTL_MS) return hit.rules
  const stub = env.TEAM_DO.get(env.TEAM_DO.idFromName(team)) as unknown as { signInRules(e: string, u: string): Promise<SignInRules> }
  const rules = await stub.signInRules(team, user)
  if (cache.size > 5000) cache.clear()
  cache.set(key, { at: Date.now(), rules })
  return rules
}

/** Test hook: forget cached rules. */
export const clearSignInRules = () => cache.clear()

const parse = (v: string): Array<number> | null => {
  const m = /^(\d+)\.(\d+)\.(\d+)/.exec(v.trim())
  return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null
}

/** True when `client` is at least `minimum` (semver major.minor.patch; pre-release tags ignored). */
export const versionAtLeast = (client: string | null, minimum: string): boolean => {
  const c = client ? parse(client) : null
  const m = parse(minimum)
  if (!m) return true
  if (!c) return false
  for (let i = 0; i < 3; i++) if (c[i]! !== m[i]!) return c[i]! > m[i]!
  return true
}

export type GateRefusal = { readonly code: "auth.sso_required" | "client.too_old"; readonly message: string; readonly minimum_version?: string }

/** A session must carry the team's SSO claim when the team enforces SSO. */
export const ssoRefusal = (principal: Principal & { sso_team?: string }, rules: SignInRules): GateRefusal | undefined =>
  principal.kind === "session" && rules.sso_required && principal.sso_team !== principal.team ? { code: "auth.sso_required", message: "this team requires sign-in with its SSO" } : undefined

/** The client version gate for token mint and wire connects. */
export const versionRefusal = (header: string | null, rules: SignInRules): GateRefusal | undefined =>
  rules.minimum_version && !versionAtLeast(header, rules.minimum_version)
    ? { code: "client.too_old", message: `this team requires cmux ${rules.minimum_version} or newer`, minimum_version: rules.minimum_version }
    : undefined
