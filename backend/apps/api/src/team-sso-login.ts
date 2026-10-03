import type { OwnerFrame, RejectFrame } from "@cmux/ownership"
import { createLocalJWKSet, decodeJwt, jwtVerify, type JSONWebKeySet } from "jose"
import type { TeamState } from "./domains/team.ts"
import { connectionForDomain } from "./domains/team-sso.ts"
import type { StackServer } from "./stack-server.ts"
import type { Http } from "./team-domain-external.ts"
import { openCurrentClientSecret } from "./team-sso-external.ts"
import { open, seal, type SealedSecret } from "./integrations/crypto.ts"

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
  sql.exec(`CREATE TABLE IF NOT EXISTS sso_logins2 (state TEXT PRIMARY KEY, connection TEXT NOT NULL, nonce TEXT NOT NULL, verifier TEXT NOT NULL, client_challenge TEXT NOT NULL, redirect_uri TEXT NOT NULL, return_to TEXT NOT NULL, expires_at INTEGER NOT NULL)`)
  // Keyed by a hash of the code; the tokens are sealed and bound to the starting client's challenge.
  sql.exec(`CREATE TABLE IF NOT EXISTS sso_redeem2 (code_hash TEXT PRIMARY KEY, client_challenge TEXT NOT NULL, sealed TEXT NOT NULL, expires_at INTEGER NOT NULL)`)
  // Keyed by a hash of the IdP issuer and subject: the same person through a recreated connection stays linked.
  sql.exec(`CREATE TABLE IF NOT EXISTS sso_identities2 (idp_key TEXT PRIMARY KEY, connection TEXT NOT NULL, stack_user TEXT NOT NULL, email TEXT NOT NULL, linked_at INTEGER NOT NULL)`)
  // Sessions this team's SSO created, keyed by Stack's refresh token id (sso.enforce, P17-4).
  sql.exec(`CREATE TABLE IF NOT EXISTS sso_sessions2 (refresh_token_id TEXT PRIMARY KEY, stack_user TEXT NOT NULL, connection TEXT NOT NULL, expires_at INTEGER NOT NULL)`)
}

/** Longest an SSO session record lives without sso.sessionMaxAgeHours (Stack's refresh tokens are long-lived). */
const SSO_SESSION_MAX_MS = 365 * 24 * 3_600_000

/**
 * The connection whose sign-in created the Stack session `refreshTokenId` for `stackUser`, while
 * the record lives. A Stack refresh
 * token keeps its id across access-token refreshes, and Stack mints no access token for a revoked
 * refresh token, so the record covers exactly that session until it expires.
 */
export const ssoSessionConnection = (sql: SqlStorage, refreshTokenId: string, stackUser: string, now: number): string | undefined => {
  ensureLoginTables(sql)
  return sql.exec<{ connection: string }>(
    `SELECT connection FROM sso_sessions2 WHERE refresh_token_id = ? AND stack_user = ? AND expires_at > ?`, refreshTokenId, stackUser, now
  ).toArray()[0]?.connection
}

/** Drops expired session records (on each new SSO sign-in, so a lookup never writes). */
const pruneSsoSessions = (sql: SqlStorage, now: number) => sql.exec(`DELETE FROM sso_sessions2 WHERE expires_at <= ?`, now)

const b64u = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const random = (n = 32) => b64u(crypto.getRandomValues(new Uint8Array(n)))
const sha256 = async (s: string) => b64u(new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode(s))))

/**
 * In-flight first links per IdP identity, so concurrent first sign-ins of one
 * person (the TeamDO interleaves at each await) share one Stack lookup or
 * creation. One TeamDO serves all sign-ins of its team, so this map sees them
 * all; a restart only drops in-flight work, and the INSERT OR IGNORE plus
 * re-read below keeps the first stored link.
 */
const inflightLinks = new Map<string, Promise<{ ok: true; stackUser: string; linked: boolean } | LoginError>>()

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
export const ssoStart = async (deps: LoginDeps, email: string, callbackBase: string, returnTo: string, clientChallenge: string): Promise<{ ok: true; url: string } | LoginError> => {
  const domain = email.slice(email.lastIndexOf("@") + 1).toLowerCase()
  const c = connectionForDomain(deps.state, domain)
  if (!c || !c.oidc.authorization_endpoint) return { ok: false, code: "sso.not_configured", message: "this email does not sign in with SSO" }
  ensureLoginTables(deps.sql)
  deps.sql.exec(`DELETE FROM sso_logins2 WHERE expires_at <= ?`, deps.now)
  deps.sql.exec(`DELETE FROM sso_redeem2 WHERE expires_at <= ?`, deps.now)
  // One redirect_uri per connection (mix-up defense: the callback path names the connection).
  const redirectUri = `${callbackBase}/${c.id}`
  // The team rides in the state so the callback reaches this TeamDO; the random part is the secret.
  const state = `${deps.team}.${random()}`
  const nonce = random()
  const verifier = random()
  deps.sql.exec(
    `INSERT INTO sso_logins2 (state, connection, nonce, verifier, client_challenge, redirect_uri, return_to, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
    state, c.id, nonce, verifier, clientChallenge, redirectUri, returnTo, deps.now + LOGIN_TTL_MS
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
export const ssoCallback = async (deps: LoginDeps, state: string, code: string, pathConnection: string, iss: string | null): Promise<{ ok: true; returnTo: string; redeem: string } | LoginError> => {
  ensureLoginTables(deps.sql)
  const fail = (c: string, message: string): LoginError => ({ ok: false, code: c, message })
  // One use only, whatever happens next (replay protection).
  const row = deps.sql.exec<{ connection: string; nonce: string; verifier: string; client_challenge: string; redirect_uri: string; return_to: string; expires_at: number }>(
    `DELETE FROM sso_logins2 WHERE state = ? RETURNING connection, nonce, verifier, client_challenge, redirect_uri, return_to, expires_at`, state
  ).toArray()[0]
  if (!row || row.expires_at <= deps.now) return fail("sso.state_invalid", "the sign-in link expired; start again")
  // Mix-up defense: the callback arrived on this connection's own path, and the IdP named itself (RFC 9207) correctly.
  if (pathConnection !== row.connection) return fail("sso.state_invalid", "the sign-in link does not belong to this connection")
  const c = deps.state.sso_connections?.[row.connection]
  if (c && iss !== null && iss !== c.oidc.issuer) return fail("sso.state_invalid", "the identity provider is not the one this sign-in started with")
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
    const { payload } = await jwtVerify(idToken, jwks, {
      issuer: c.oidc.issuer,
      audience: c.oidc.client_id,
      clockTolerance: 60,
      algorithms: ["RS256", "PS256", "ES256", "EdDSA"],
      requiredClaims: ["exp", "iat", "sub"],
      maxTokenAge: "10m"
    })
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
  const subject = await sha256(`${c.oidc.issuer}\n${claims.sub}`)
  const stored = () => deps.sql.exec<{ stack_user: string }>(`SELECT stack_user FROM sso_identities2 WHERE idp_key = ?`, subject).toArray()[0]?.stack_user
  const stack = deps.stack
  try {
    let stackUser = stored()
    let linked = false
    if (!stackUser) {
      let pending = inflightLinks.get(`${deps.team}|${subject}`)
      if (!pending) {
        pending = (async () => {
          const existing = await stack.findUserByEmail(claims.email)
          // Pre-hijacking defense: link only to an account whose email Stack verified. Linking a verified-email
          // account is accepted: the team controls the domain's DNS, so it could already reset that account by mail.
          if (existing && !existing.email_verified) return fail("sso.account_conflict", "an unverified cmux account already uses this email; verify that account's email or ask support")
          const id = existing?.id ?? (await stack.createUser(claims.email, claims.name)).id
          deps.sql.exec(`INSERT OR IGNORE INTO sso_identities2 (idp_key, connection, stack_user, email, linked_at) VALUES (?, ?, ?, ?, ?)`, subject, c.id, id, claims.email, Date.now())
          return { ok: true as const, stackUser: stored() ?? id, linked: true }
        })().finally(() => inflightLinks.delete(`${deps.team}|${subject}`))
        inflightLinks.set(`${deps.team}|${subject}`, pending)
      }
      const r = await pending
      if (!r.ok) return r
      stackUser = r.stackUser
      linked = r.linked
    }
    const maxHours = deps.state.policy?.values["sso.sessionMaxAgeHours"]?.value
    const ttl = typeof maxHours === "number" ? maxHours * 3_600_000 : undefined
    const session = await deps.stack.createSession(stackUser, ttl)
    // Record the session server-side: sso.enforce trusts this record, never a token claim.
    const refreshTokenId = decodeJwt(session.access_token).refresh_token_id
    if (typeof refreshTokenId !== "string" || !refreshTokenId) return fail("sso.unavailable", "sign-in could not be completed; try again")
    pruneSsoSessions(deps.sql, deps.now)
    deps.sql.exec(`INSERT OR REPLACE INTO sso_sessions2 (refresh_token_id, stack_user, connection, expires_at) VALUES (?, ?, ?, ?)`,
      refreshTokenId, stackUser, c.id, deps.now + (ttl ?? SSO_SESSION_MAX_MS))
    if (!deps.kek) return fail("sso.not_configured", "SSO needs INTEGRATIONS_KEK on this deployment")
    const redeem = `${deps.team}.${random()}`
    const codeHash = await sha256(redeem)
    const sealed = await seal(deps.kek, JSON.stringify(session), enc.encode(`cmux-sso-redeem-v1|${deps.team}|${codeHash}`))
    deps.sql.exec(`INSERT INTO sso_redeem2 (code_hash, client_challenge, sealed, expires_at) VALUES (?, ?, ?, ?)`, codeHash, row.client_challenge, JSON.stringify(sealed), deps.now + REDEEM_TTL_MS)
    const audit = deps.submitSystem("sso.signed_in", { connection: c.id, subject, stack_user: stackUser, linked }, `sso-signin:${state}`)
    if (audit.frames.some((f): f is RejectFrame => f.t === "reject")) console.error(JSON.stringify({ msg: "sso sign-in audit refused", connection: c.id }))
    return { ok: true, returnTo: row.return_to, redeem }
  } catch (e) {
    console.error(JSON.stringify({ msg: "sso sign-in failed at Stack", connection: c.id, error: String(e) }))
    return fail("sso.unavailable", "sign-in could not be completed; try again")
  }
}

/**
 * POST /v1/sso/redeem: the Stack tokens, once, and only to the client that
 * started the flow (it proves the verifier of the challenge it sent to
 * /start). A forwarded callback link (login CSRF) or a code caught by another
 * app that claims the cmux:// scheme is useless without that verifier.
 */
export const ssoRedeem = async (sql: SqlStorage, kek: string | undefined, team: string, code: string, clientVerifier: string, now: number): Promise<{ ok: true; access_token: string; refresh_token: string } | LoginError> => {
  ensureLoginTables(sql)
  const bad: LoginError = { ok: false, code: "sso.state_invalid", message: "the sign-in code expired, was used, or belongs to another client" }
  if (!kek) return bad
  const codeHash = await sha256(code)
  const row = sql.exec<{ client_challenge: string; sealed: string; expires_at: number }>(`SELECT client_challenge, sealed, expires_at FROM sso_redeem2 WHERE code_hash = ?`, codeHash).toArray()[0]
  if (!row || row.expires_at <= now) return bad
  // Wrong verifier: refused without consuming the code (the rightful client can still redeem).
  if ((await sha256(clientVerifier)) !== row.client_challenge) return bad
  sql.exec(`DELETE FROM sso_redeem2 WHERE code_hash = ?`, codeHash)
  const session = JSON.parse(await open(kek, JSON.parse(row.sealed) as SealedSecret, enc.encode(`cmux-sso-redeem-v1|${team}|${codeHash}`))) as { access_token: string; refresh_token: string }
  return { ok: true, access_token: session.access_token, refresh_token: session.refresh_token }
}
