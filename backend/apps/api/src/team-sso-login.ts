import type { OwnerFrame, RejectFrame } from "@cmux/ownership"
import { createLocalJWKSet, jwtVerify, type JSONWebKeySet } from "jose"
import type { TeamState } from "./domains/team.ts"
import { connectionForDomain } from "./domains/team-sso.ts"
import type { StackServer } from "./stack-server.ts"
import type { Http } from "./team-domain-external.ts"
import { openCurrentClientSecret } from "./team-sso-external.ts"

/**
 * Enterprise SSO sign-in, slice 2c-2b (spec/enterprise.md 3.3): OIDC
 * authorization code flow with PKCE, state and nonce, run by the TeamDO that
 * owns the connection. The callback validates the ID token, finds or creates
 * the Stack user (Stack stays the identity source, D4), records the IdP
 * identity, and opens a Stack session. The tokens never travel in a URL: the
 * client gets a one-time code and redeems it (POST /v1/sso/redeem).
 *
 * Until shared teams exist (coordinator decision 2026-10-02), sign-in adds no
 * team membership.
 */
const LOGIN_TTL_MS = 10 * 60_000
const REDEEM_TTL_MS = 2 * 60_000
const enc = new TextEncoder()

export const ensureLoginTables = (sql: SqlStorage) => {
  sql.exec(`CREATE TABLE IF NOT EXISTS sso_logins (state TEXT PRIMARY KEY, connection TEXT NOT NULL, nonce TEXT NOT NULL, verifier TEXT NOT NULL, redirect_uri TEXT NOT NULL, return_to TEXT NOT NULL, expires_at INTEGER NOT NULL)`)
  sql.exec(`CREATE TABLE IF NOT EXISTS sso_redeem (code TEXT PRIMARY KEY, access_token TEXT NOT NULL, refresh_token TEXT NOT NULL, expires_at INTEGER NOT NULL)`)
  sql.exec(`CREATE TABLE IF NOT EXISTS sso_identities (connection TEXT NOT NULL, subject TEXT NOT NULL, stack_user TEXT NOT NULL, email TEXT NOT NULL, linked_at INTEGER NOT NULL, PRIMARY KEY (connection, subject))`)
}

const b64u = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const random = (n = 32) => b64u(crypto.getRandomValues(new Uint8Array(n)))
const sha256 = async (s: string) => b64u(new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode(s))))

export interface LoginDeps {
  readonly state: TeamState
  readonly team: string
  readonly sql: SqlStorage
  readonly http: Http
  readonly kek: string | undefined
  readonly stack: StackServer | undefined
  readonly now: number
  readonly submitSystem: (op: string, params: unknown, key: string) => { frames: ReadonlyArray<OwnerFrame> }
}

export type LoginError = { ok: false; code: string; message: string }

/** GET /v1/sso/start: the IdP authorization URL for an email in one of this team's verified domains. */
export const ssoStart = async (deps: LoginDeps, email: string, redirectUri: string, returnTo: string): Promise<{ ok: true; url: string } | LoginError> => {
  const domain = email.slice(email.lastIndexOf("@") + 1).toLowerCase()
  const c = connectionForDomain(deps.state, domain)
  if (!c || !c.oidc.authorization_endpoint) return { ok: false, code: "sso.not_configured", message: "this email does not sign in with SSO" }
  ensureLoginTables(deps.sql)
  deps.sql.exec(`DELETE FROM sso_logins WHERE expires_at <= ?`, deps.now)
  // The team rides in the state so the callback reaches this TeamDO; the random part is the secret.
  const state = `${deps.team}.${random()}`
  const nonce = random()
  const verifier = random()
  deps.sql.exec(
    `INSERT INTO sso_logins (state, connection, nonce, verifier, redirect_uri, return_to, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)`,
    state, c.id, nonce, verifier, redirectUri, returnTo, deps.now + LOGIN_TTL_MS
  )
  const url = new URL(c.oidc.authorization_endpoint)
  url.searchParams.set("response_type", "code")
  url.searchParams.set("client_id", c.oidc.client_id)
  url.searchParams.set("redirect_uri", redirectUri)
  url.searchParams.set("scope", c.oidc.scopes.join(" "))
  url.searchParams.set("state", state)
  url.searchParams.set("nonce", nonce)
  url.searchParams.set("code_challenge", await sha256(verifier))
  url.searchParams.set("code_challenge_method", "S256")
  url.searchParams.set("login_hint", email)
  return { ok: true, url: url.toString() }
}

/** GET /v1/sso/callback: code -> ID token -> Stack user and session -> one-time redeem code. */
export const ssoCallback = async (deps: LoginDeps, state: string, code: string): Promise<{ ok: true; returnTo: string; redeem: string } | LoginError> => {
  ensureLoginTables(deps.sql)
  const fail = (c: string, message: string): LoginError => ({ ok: false, code: c, message })
  // One use only, whatever happens next (replay protection).
  const row = deps.sql.exec<{ connection: string; nonce: string; verifier: string; redirect_uri: string; return_to: string; expires_at: number }>(
    `DELETE FROM sso_logins WHERE state = ? RETURNING connection, nonce, verifier, redirect_uri, return_to, expires_at`, state
  ).toArray()[0]
  if (!row || row.expires_at <= deps.now) return fail("sso.state_invalid", "the sign-in link expired; start again")
  const c = deps.state.sso_connections?.[row.connection]
  if (!c || c.state !== "active" || !c.oidc.token_endpoint || !c.oidc.jwks_uri) return fail("sso.not_configured", "this SSO connection is not active")
  const secret = await openCurrentClientSecret({ team: deps.team, kek: deps.kek, sql: deps.sql, state: deps.state }, c.id)
  if (!secret) return fail("sso.not_configured", "the connection has no client secret")
  if (!deps.stack) return fail("sso.not_configured", "Stack server access is not configured on this deployment")

  let idToken: string
  try {
    const res = await deps.http(new Request(c.oidc.token_endpoint, {
      method: "POST",
      redirect: "manual",
      signal: AbortSignal.timeout(10_000),
      headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json", authorization: `Basic ${btoa(`${encodeURIComponent(c.oidc.client_id)}:${encodeURIComponent(secret)}`)}` },
      body: new URLSearchParams({ grant_type: "authorization_code", code, redirect_uri: row.redirect_uri, code_verifier: row.verifier }).toString()
    }))
    if (!res.ok) return fail("sso.idp_error", `the identity provider refused the code (${res.status})`)
    const body = (await res.json()) as { id_token?: unknown }
    if (typeof body.id_token !== "string") return fail("sso.idp_error", "the identity provider returned no ID token")
    idToken = body.id_token
  } catch {
    return fail("sso.idp_error", "the identity provider did not answer")
  }

  let claims: { sub: string; email: string; name?: string }
  try {
    const jwksRes = await deps.http(new Request(c.oidc.jwks_uri, { redirect: "manual", signal: AbortSignal.timeout(5000) }))
    if (!jwksRes.ok) return fail("sso.idp_error", "the identity provider's keys are unavailable")
    const jwks = createLocalJWKSet((await jwksRes.json()) as JSONWebKeySet)
    // OIDC Core 3.1.3.7: issuer and audience exact, signature by the IdP's keys, not expired, our nonce.
    const { payload } = await jwtVerify(idToken, jwks, { issuer: c.oidc.issuer, audience: c.oidc.client_id, clockTolerance: 60 })
    if (payload.nonce !== row.nonce) return fail("sso.token_invalid", "the ID token's nonce does not match this sign-in")
    if (Array.isArray(payload.aud) && payload.aud.length > 1 && payload.azp !== c.oidc.client_id) return fail("sso.token_invalid", "the ID token's authorized party is not cmux")
    if (typeof payload.sub !== "string" || !payload.sub) return fail("sso.token_invalid", "the ID token has no subject")
    if (typeof payload.email !== "string") return fail("sso.token_invalid", "the ID token has no email; add the email scope at the identity provider")
    if (payload.email_verified === false) return fail("sso.token_invalid", "the identity provider says the email is not verified")
    claims = { sub: payload.sub, email: payload.email.toLowerCase(), ...(typeof payload.name === "string" ? { name: payload.name } : {}) }
  } catch {
    return fail("sso.token_invalid", "the ID token did not verify")
  }
  // The team vouches only for its verified domains served by this connection.
  const domain = claims.email.slice(claims.email.lastIndexOf("@") + 1)
  if (!c.domains.includes(domain) || deps.state.domains?.[domain]?.state !== "verified") return fail("sso.domain_mismatch", "this account's email domain is not served by this SSO connection")

  // Account link: the IdP subject is the stable key; the first sign-in links by the verified email.
  const subject = await sha256(`${c.id}:${claims.sub}`)
  let stackUser = deps.sql.exec<{ stack_user: string }>(`SELECT stack_user FROM sso_identities WHERE connection = ? AND subject = ?`, c.id, subject).toArray()[0]?.stack_user
  let linked = false
  try {
    if (!stackUser) {
      stackUser = (await deps.stack.findUserByEmail(claims.email))?.id ?? (await deps.stack.createUser(claims.email, claims.name)).id
      deps.sql.exec(`INSERT OR IGNORE INTO sso_identities (connection, subject, stack_user, email, linked_at) VALUES (?, ?, ?, ?, ?)`, c.id, subject, stackUser, claims.email, deps.now)
      linked = true
    }
    const maxHours = deps.state.policy?.values["sso.sessionMaxAgeHours"]?.value
    const session = await deps.stack.createSession(stackUser, typeof maxHours === "number" ? maxHours * 3_600_000 : undefined)
    const redeem = `${deps.team}.${random()}`
    deps.sql.exec(`DELETE FROM sso_redeem WHERE expires_at <= ?`, deps.now)
    deps.sql.exec(`INSERT INTO sso_redeem (code, access_token, refresh_token, expires_at) VALUES (?, ?, ?, ?)`, redeem, session.access_token, session.refresh_token, deps.now + REDEEM_TTL_MS)
    const audit = deps.submitSystem("sso.signed_in", { connection: c.id, subject, stack_user: stackUser, linked }, `sso-signin:${state}`)
    if (audit.frames.some((f): f is RejectFrame => f.t === "reject")) console.error(JSON.stringify({ msg: "sso sign-in audit refused", connection: c.id }))
    return { ok: true, returnTo: row.return_to, redeem }
  } catch (e) {
    console.error(JSON.stringify({ msg: "sso sign-in failed at Stack", connection: c.id, error: String(e) }))
    return fail("sso.unavailable", "sign-in could not be completed; try again")
  }
}

/** POST /v1/sso/redeem: the Stack tokens, once. */
export const ssoRedeem = (sql: SqlStorage, code: string, now: number): { ok: true; access_token: string; refresh_token: string } | LoginError => {
  ensureLoginTables(sql)
  const row = sql.exec<{ access_token: string; refresh_token: string; expires_at: number }>(`DELETE FROM sso_redeem WHERE code = ? RETURNING access_token, refresh_token, expires_at`, code).toArray()[0]
  if (!row || row.expires_at <= now) return { ok: false, code: "sso.state_invalid", message: "the sign-in code expired or was used" }
  return { ok: true, access_token: row.access_token, refresh_token: row.refresh_token }
}
