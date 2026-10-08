import type { Principal } from "@cmux/ownership"
import { emailDomainOf, withLiveSsoTeam } from "./auth.ts"
import { unclaimableReason } from "./domains/team-domains.ts"
import type { Env } from "./env.ts"
import type { SignInRules } from "./team-do.ts"

/**
 * Server-side team policy at sign-in (enterprise P17-4, coordinator decisions 2026-10-03):
 * - sso.enforce: a Stack session counts only when this team's OIDC callback created it (TeamDO
 *   records it by Stack's refresh_token_id; no token claim is trusted); owners are exempt unless
 *   sso.enforceForOwners. It binds the principal's own team AND the team that owns the user's email
 *   domain (DomainDO; spec/enterprise.md 3.6), because every token names the personal team.
 * - updates.minimumVersion: /v1/auth/token and wire connects send `x-cmux-client-version`; an
 *   older or (only when the key is set) missing version answers `client.too_old`.
 * - agents.allowedClasses: grants are minted only for listed classes (mux = chief creation and
 *   its MuxDO bind; agent = install.register for agent kinds; run = automation run grants).
 * Rules come from each team's TeamDO and are cached per isolate for 30 s.
 */
const TTL_MS = 30_000
const cache = new Map<string, { at: number; rules: SignInRules }>()

export const signInRules = async (env: Env, team: string, user: string, domain?: string): Promise<SignInRules> => {
  const key = `${team}\u0000${user}\u0000${domain ?? ""}`
  const hit = cache.get(key)
  if (hit && Date.now() - hit.at < TTL_MS) return hit.rules
  const stub = env.TEAM_DO.get(env.TEAM_DO.idFromName(team)) as unknown as { signInRules(e: string, u: string, d?: string): Promise<SignInRules> }
  const rules = await stub.signInRules(team, user, domain)
  if (cache.size > 5000) cache.clear()
  cache.set(key, { at: Date.now(), rules })
  return rules
}

/** Test hook: forget cached rules. */
export const clearSignInRules = () => {
  cache.clear()
  ssoSessions.clear()
  domainOwners.clear()
}

const domainOwners = new Map<string, { at: number; team: string | null }>()

/** The team that owns a verified email domain (DomainDO, the single writer), cached per isolate for 30 s. */
const domainOwner = async (env: Env, domain: string): Promise<string | null> => {
  // Public mail and public suffixes are never claimable: no object to wake.
  if (unclaimableReason(domain)) return null
  const hit = domainOwners.get(domain)
  if (hit && Date.now() - hit.at < TTL_MS) return hit.team
  const team = await env.DOMAIN_DO.get(env.DOMAIN_DO.idFromName(domain)).owner()
  if (domainOwners.size > 5000) domainOwners.clear()
  domainOwners.set(domain, { at: Date.now(), team })
  return team
}

/**
 * Teams whose sso.enforce binds this principal: its own team (the target of team-scoped ops) and
 * the team that owns the user's email domain. A session's email comes from the Stack-signed token;
 * an install's from our signed token (UserDO's record at mint). Any email counts, verified or not:
 * an unverified address in the domain only makes its holder stricter, never looser.
 */
export const ssoTeams = async (env: Env, p: Principal): Promise<Array<{ team: string; domain?: string }>> => {
  const teams: Array<{ team: string; domain?: string }> = p.team ? [{ team: p.team }] : []
  const domain = p.kind === "install" ? p.email_domain : p.kind === "session" ? emailDomainOf(p.email) : undefined
  const owner = domain ? await domainOwner(env, domain) : null
  if (owner && owner !== p.team) teams.push({ team: owner, domain: domain! })
  return teams
}

const ssoSessions = new Map<string, number>()

/**
 * The principal with `sso_team` set to `team` when that team's OIDC callback created this Stack
 * session (TeamDO's record, keyed by the Stack-signed refresh_token_id). Only confirmed sessions are
 * cached (30 s per isolate); a refusal is asked again on the next request.
 */
export const withSsoSession = async (env: Env, principal: Principal, team: string): Promise<Principal> => {
  if (principal.kind !== "session" || !principal.stack_session || !principal.stack_user_id) return principal
  const key = `${team}\u0000${principal.stack_session}\u0000${principal.stack_user_id}`
  const at = ssoSessions.get(key)
  if (at !== undefined && Date.now() - at < TTL_MS) return { ...principal, sso_team: team }
  const stub = env.TEAM_DO.get(env.TEAM_DO.idFromName(team)) as unknown as { ssoSession(e: string, s: string, u: string): Promise<boolean> }
  if (!(await stub.ssoSession(team, principal.stack_session, principal.stack_user_id))) return principal
  if (ssoSessions.size > 5000) ssoSessions.clear()
  ssoSessions.set(key, Date.now())
  return { ...principal, sso_team: team }
}

/**
 * For install.register: the session with sso_team set to the team (own or email domain's) whose SSO
 * created it, even while that team does not enforce SSO yet, so turning enforcement on later keeps
 * the installs registered through SSO.
 */
export const withAnySsoSession = async (env: Env, principal: Principal): Promise<Principal> => {
  if (principal.kind !== "session" || principal.sso_team !== undefined || !principal.stack_session) return principal
  for (const { team } of await ssoTeams(env, principal)) {
    const p = await withSsoSession(env, principal, team)
    if (p.sso_team !== undefined) return p
  }
  return principal
}

/**
 * The SSO gate for a session or install: every team in ssoTeams that requires SSO must be the one
 * whose SSO created the session (TeamDO record) or registered the install (its token's sso_team).
 * Returns the principal with sso_team resolved, so install.register can bind installs to it.
 */
export const ssoGate = async (env: Env, principal: Principal): Promise<{ principal: Principal; refusal?: GateRefusal }> => {
  if ((principal.kind !== "session" && principal.kind !== "install") || !principal.user) return { principal }
  let p = await withLiveSsoTeam(env, principal)
  for (const { team, domain } of await ssoTeams(env, principal)) {
    const rules = await signInRules(env, team, principal.user, domain)
    if (!rules.sso_required) continue
    if (p.kind === "session" && p.sso_team === undefined) p = await withSsoSession(env, p, team)
    const refusal = ssoRefusal(p, rules, team)
    if (refusal) return { principal: p, refusal }
  }
  return { principal: p }
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
 * When `team` (by default the principal's own) enforces SSO, a session needs that team's SSO record
 * and an install token needs an install registered from such a session (its token carries
 * sso_team); others are refused.
 */
export const ssoRefusal = (principal: Principal, rules: SignInRules, team: string | undefined = principal.team): GateRefusal | undefined =>
  (principal.kind === "session" || principal.kind === "install") && rules.sso_required && (team === undefined || principal.sso_team !== team)
    ? { code: "auth.sso_required", message: "this team requires sign-in with its SSO" }
    : undefined

/** The client version gate for token mint and wire connects. */
export const versionRefusal = (header: string | null, rules: SignInRules): GateRefusal | undefined =>
  rules.minimum_version && !versionAtLeast(header, rules.minimum_version)
    ? { code: "client.too_old", message: `this team requires cmux ${rules.minimum_version} or newer`, minimum_version: rules.minimum_version }
    : undefined
