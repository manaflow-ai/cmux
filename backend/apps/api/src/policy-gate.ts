import type { Principal } from "@cmux/ownership"
import type { Env } from "./env.ts"
import type { SignInRules } from "./team-do.ts"

/**
 * Server-side team policy at sign-in (enterprise P17-4, coordinator decisions 2026-10-03):
 * - sso.enforce: a Stack session counts only when this team's OIDC callback created it (TeamDO
 *   records it by Stack's refresh_token_id; no token claim is trusted); owners are exempt unless
 *   sso.enforceForOwners.
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
export const clearSignInRules = () => {
  cache.clear()
  ssoSessions.clear()
}

const ssoSessions = new Map<string, number>()

/**
 * The principal with `sso_team` set when the team enforces SSO and its OIDC callback created this
 * Stack session (TeamDO's record, keyed by the Stack-signed refresh_token_id). Only confirmed
 * sessions are cached (30 s per isolate); a refusal is asked again on the next request.
 */
export const withSsoSession = async (env: Env, principal: Principal, rules: SignInRules): Promise<Principal> => {
  if (principal.kind !== "session" || !rules.sso_required || !principal.team || !principal.stack_session || !principal.stack_user_id) return principal
  const key = `${principal.team}\u0000${principal.stack_session}\u0000${principal.stack_user_id}`
  const at = ssoSessions.get(key)
  if (at !== undefined && Date.now() - at < TTL_MS) return { ...principal, sso_team: principal.team }
  const stub = env.TEAM_DO.get(env.TEAM_DO.idFromName(principal.team)) as unknown as { ssoSession(e: string, s: string, u: string): Promise<boolean> }
  if (!(await stub.ssoSession(principal.team, principal.stack_session, principal.stack_user_id))) return principal
  if (ssoSessions.size > 5000) ssoSessions.clear()
  ssoSessions.set(key, Date.now())
  return { ...principal, sso_team: principal.team }
}

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

/**
 * When the team enforces SSO, a session needs the team's SSO claim and an install token needs an
 * install registered from such a session (its token carries sso_team); others are refused.
 */
export const ssoRefusal = (principal: Principal, rules: SignInRules): GateRefusal | undefined =>
  (principal.kind === "session" || principal.kind === "install") && rules.sso_required && principal.sso_team !== principal.team
    ? { code: "auth.sso_required", message: "this team requires sign-in with its SSO" }
    : undefined

/** The client version gate for token mint and wire connects. */
export const versionRefusal = (header: string | null, rules: SignInRules): GateRefusal | undefined =>
  rules.minimum_version && !versionAtLeast(header, rules.minimum_version)
    ? { code: "client.too_old", message: `this team requires cmux ${rules.minimum_version} or newer`, minimum_version: rules.minimum_version }
    : undefined
