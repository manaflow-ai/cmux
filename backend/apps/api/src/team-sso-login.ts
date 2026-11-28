import type { OwnerFrame, RejectFrame } from "@cmux/ownership"
import { createLocalJWKSet, decodeJwt, jwtVerify, type JSONWebKeySet } from "jose"
import type { TeamState } from "./domains/team.ts"
import { connectionForDomain, type Connection } from "./domains/team-sso.ts"
import { validateSamlResponse } from "@cmux/saml"
import type { StackServer } from "./stack-server.ts"
import type { Http } from "./team-domain-external.ts"
import { openCurrentClientSecret } from "./team-sso-external.ts"
import type { SsoJoin } from "./team-sso-join.ts"
import { open, seal, type SealedSecret } from "./integrations/crypto.ts"

/**
 * Enterprise SSO sign-in, slice 2c-2b (spec/enterprise.md 3.3): OIDC
 * authorization code flow with PKCE, state and nonce, run by the TeamDO that
 * owns the connection. The callback validates the ID token, finds or creates
 * the Stack user (Stack stays the identity source, D4), records the IdP
 * identity, and opens a Stack session. The tokens never travel in a URL: the
 * client gets a one-time code and redeems it (POST /v1/sso/redeem).
 *
 * Once the session is recorded, the person joins the team just in time
 * (cmux-platform POST /v1/teams/{team}/sso/join, team-sso-join.ts): an outage
 * there never fails the sign-in, but a person the team removed or deactivated
 * is refused here too.
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
  // Sessions this team's SSO created, keyed by Stack's refresh token id (sso.enforce, P17-4). signed_in_at lets a
  // lowered sso.sessionMaxAgeHours end older records. sso_sessions2 (no sign-in time) is no longer read: no team
  // could enforce SSO while it was written, so nothing depends on its rows.
  // SAML assertion ids already used (replay, SAML profiles 4.1.4.5), kept until the assertion expires.
  sql.exec(`CREATE TABLE IF NOT EXISTS sso_saml_replay (assertion_key TEXT PRIMARY KEY, until INTEGER NOT NULL)`)
  sql.exec(`CREATE TABLE IF NOT EXISTS sso_sessions3 (refresh_token_id TEXT PRIMARY KEY, stack_user TEXT NOT NULL, connection TEXT NOT NULL, signed_in_at INTEGER NOT NULL, expires_at INTEGER NOT NULL)`)
}

/** sso.sessionMaxAgeHours of the team's current policy, in ms (none: undefined). */
export const ssoMaxAgeMs = (state: TeamState): number | undefined => {
  const hours = state.policy?.values["sso.sessionMaxAgeHours"]?.value
  return typeof hours === "number" ? hours * 3_600_000 : undefined
}

/** Longest an SSO session record lives without sso.sessionMaxAgeHours (Stack's refresh tokens are long-lived). */
const SSO_SESSION_MAX_MS = 365 * 24 * 3_600_000

/**
 * The connection whose sign-in created the Stack session `refreshTokenId` for `stackUser`, while
 * the record lives: before its expiry and, when the team sets sso.sessionMaxAgeHours, younger than
 * that age now (a lowered value ends older records at once). A Stack refresh token keeps its id
 * across access-token refreshes, and Stack mints no access token for a revoked refresh token, so the
 * record covers exactly that session until it expires.
 */
export const ssoSessionConnection = (sql: SqlStorage, refreshTokenId: string, stackUser: string, now: number, maxAgeMs?: number): string | undefined => {
  ensureLoginTables(sql)
  return sql.exec<{ connection: string }>(
    `SELECT connection FROM sso_sessions3 WHERE refresh_token_id = ? AND stack_user = ? AND expires_at > ? AND signed_in_at > ?`,
    refreshTokenId, stackUser, now, maxAgeMs === undefined ? -1 : now - maxAgeMs
  ).toArray()[0]?.connection
}

/** Drops expired session records (on each new SSO sign-in, so a lookup never writes). */
const pruneSsoSessions = (sql: SqlStorage, now: number) => sql.exec(`DELETE FROM sso_sessions3 WHERE expires_at <= ?`, now)

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
  /** JIT membership on cmux-platform as the new session's access token (team-sso-join.ts). */
  readonly join: (accessToken: string) => Promise<SsoJoin>
}

export type LoginError = { ok: false; code: string; message: string }

/** GET /v1/sso/start: the IdP authorization URL for an email in one of this team's verified domains. */
export const ssoStart = async (deps: LoginDeps, email: string, callbackBase: string, returnTo: string, clientChallenge: string): Promise<{ ok: true; url: string } | LoginError> => {
  const domain = email.slice(email.lastIndexOf("@") + 1).toLowerCase()
  const c = connectionForDomain(deps.state, domain)
  if (!c || (c.kind === "oidc" && !c.oidc?.authorization_endpoint) || (c.kind === "saml" && !c.saml)) return { ok: false, code: "sso.not_configured", message: "this email does not sign in with SSO" }
  ensureLoginTables(deps.sql)
  deps.sql.exec(`DELETE FROM sso_logins2 WHERE expires_at <= ?`, deps.now)
  deps.sql.exec(`DELETE FROM sso_redeem2 WHERE expires_at <= ?`, deps.now)
  if (c.kind === "saml") return samlStart(deps, c, email, new URL(callbackBase).origin, returnTo, clientChallenge)
  const oidc = c.oidc!
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
  const url = new URL(oidc.authorization_endpoint!)
  url.searchParams.set("response_type", "code")
  url.searchParams.set("client_id", oidc.client_id)
  url.searchParams.set("redirect_uri", redirectUri)
  url.searchParams.set("scope", oidc.scopes.join(" "))
  url.searchParams.set("state", state)
  url.searchParams.set("nonce", nonce)
  url.searchParams.set("code_challenge", await sha256(verifier))
  url.searchParams.set("code_challenge_method", "S256")
  url.searchParams.set("login_hint", email)
  return { ok: true, url: url.toString() }
}

/**
 * The shared end of an OIDC or SAML sign-in, once the IdP's assertion is verified and its email domain checked:
 * link the IdP subject to a Stack user, open and record the session, join the team just in time, and seal the
 * tokens behind a one-time redeem code.
 */
const finishSignIn = async (
  deps: LoginDeps,
  c: Connection,
  claims: { subject: string; email: string; name?: string },
  row: { client_challenge: string; return_to: string },
  state: string
): Promise<{ ok: true; returnTo: string; redeem: string } | LoginError> => {
  const fail = (code: string, message: string): LoginError => ({ ok: false, code, message })
  if (!deps.stack) return fail("sso.not_configured", "Stack server access is not configured on this deployment")
  const subject = claims.subject
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
    const ttl = ssoMaxAgeMs(deps.state)
    const session = await deps.stack.createSession(stackUser, ttl)
    // Record the session server-side: sso.enforce trusts this record, never a token claim.
    const refreshTokenId = decodeJwt(session.access_token).refresh_token_id
    if (typeof refreshTokenId !== "string" || !refreshTokenId) return fail("sso.unavailable", "sign-in could not be completed; try again")
    pruneSsoSessions(deps.sql, deps.now)
    deps.sql.exec(`INSERT OR REPLACE INTO sso_sessions3 (refresh_token_id, stack_user, connection, signed_in_at, expires_at) VALUES (?, ?, ?, ?, ?)`,
      refreshTokenId, stackUser, c.id, deps.now, deps.now + (ttl ?? SSO_SESSION_MAX_MS))
    if (!deps.kek) return fail("sso.not_configured", "SSO needs INTEGRATIONS_KEK on this deployment")
    // JIT membership (cmux-platform #1957). The platform checks the row above, so it runs after the insert.
    const joined = await deps.join(session.access_token).catch((e): SsoJoin => ({ ok: false, refused: false, status: 0, code: "team_sso.unavailable", message: String(e).slice(0, 200) }))
    if (!joined.ok && joined.refused) {
      // Removed or deactivated: the tokens never leave this object, and the session no longer counts as this team's SSO.
      deps.sql.exec(`DELETE FROM sso_sessions3 WHERE refresh_token_id = ?`, refreshTokenId)
      console.warn(JSON.stringify({ msg: "sso sign-in refused by team membership", connection: c.id, code: joined.code }))
      return fail("sso.removed", "your access to this team was removed; ask a team admin to add you back")
    }
    if (!joined.ok) console.warn(JSON.stringify({ msg: "sso jit join skipped", connection: c.id, status: joined.status, code: joined.code }))
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
  if (c && c.kind !== "oidc") return fail("sso.state_invalid", "the sign-in link does not belong to this connection")
  if (c?.oidc && iss !== null && iss !== c.oidc.issuer) return fail("sso.state_invalid", "the identity provider is not the one this sign-in started with")
  if (!c || c.state !== "active" || !c.oidc?.token_endpoint || !c.oidc.jwks_uri) return fail("sso.not_configured", "this SSO connection is not active")
  const oidc = { ...c.oidc, token_endpoint: c.oidc.token_endpoint, jwks_uri: c.oidc.jwks_uri }
  const secret = await openCurrentClientSecret({ team: deps.team, kek: deps.kek, sql: deps.sql, state: deps.state }, c.id)
  if (!secret) return fail("sso.not_configured", "the connection has no client secret")
  if (!deps.stack) return fail("sso.not_configured", "Stack server access is not configured on this deployment")

  let idToken: string
  try {
    const res = await deps.http(new Request(oidc.token_endpoint, {
      method: "POST",
      redirect: "manual",
      signal: AbortSignal.timeout(10_000),
      headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json", authorization: `Basic ${btoa(`${encodeURIComponent(oidc.client_id)}:${encodeURIComponent(secret)}`)}` },
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
    const jwksRes = await deps.http(new Request(oidc.jwks_uri, { redirect: "manual", signal: AbortSignal.timeout(5000) }))
    if (!jwksRes.ok) return fail("sso.idp_error", "the identity provider's keys are unavailable")
    const jwks = createLocalJWKSet((await jwksRes.json()) as JSONWebKeySet)
    // OIDC Core 3.1.3.7: issuer and audience exact, signature by the IdP's keys, not expired, our nonce.
    const { payload } = await jwtVerify(idToken, jwks, {
      issuer: oidc.issuer,
      audience: oidc.client_id,
      clockTolerance: 60,
      algorithms: ["RS256", "PS256", "ES256", "EdDSA"],
      requiredClaims: ["exp", "iat", "sub"],
      maxTokenAge: "10m"
    })
    if (payload.nonce !== row.nonce) return fail("sso.token_invalid", "the ID token's nonce does not match this sign-in")
    if (Array.isArray(payload.aud) && payload.aud.length > 1 && payload.azp !== oidc.client_id) return fail("sso.token_invalid", "the ID token's authorized party is not cmux")
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
  const subject = await sha256(`${oidc.issuer}\n${claims.sub}`)
  return finishSignIn(deps, c, { subject, email: claims.email, ...(claims.name ? { name: claims.name } : {}) }, row, state)
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

/**
 * SAML 2.0 sign-in (RFD 0211, spec/enterprise.md 3.3): SP-initiated only. Start sends an unsigned
 * AuthnRequest by HTTP-Redirect; the IdP posts a Response to the connection's ACS URL, where
 * @cmux/saml checks the one signed assertion (issuer, audience, recipient, our request id, time,
 * certificate) and the assertion id is spent once. The rest is the OIDC tail (finishSignIn).
 */
const SAML_EMAIL_ATTRIBUTES = ["email", "mail", "emailaddress", "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress", "urn:oid:0.9.2342.19200300.100.1.3"]
const NAMEID_EMAIL = "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress"
const EMAIL = /^[^\s@<>"]{1,200}@[a-z0-9.-]{1,253}$/

const xmlAttr = (v: string) => v.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;")

/** The SP entity id and ACS URL of a SAML connection: both are ours and fixed per connection. */
export const samlEndpoints = (origin: string, team: string, connection: string) => ({
  spEntityId: `${origin}/v1/sso/saml/metadata/${encodeURIComponent(team)}/${connection}`,
  acsUrl: `${origin}/v1/sso/saml/acs/${connection}`
})

const deflateRawBase64 = async (text: string): Promise<string> => {
  const stream = new Blob([enc.encode(text)]).stream().pipeThrough(new CompressionStream("deflate-raw"))
  const bytes = new Uint8Array(await new Response(stream).arrayBuffer())
  let bin = ""
  for (const b of bytes) bin += String.fromCharCode(b)
  return btoa(bin)
}

const samlStart = async (deps: LoginDeps, c: Connection, email: string, origin: string, returnTo: string, clientChallenge: string): Promise<{ ok: true; url: string } | LoginError> => {
  const saml = c.saml!
  const { spEntityId, acsUrl } = samlEndpoints(origin, deps.team, c.id)
  const state = `${deps.team}.${random()}`
  // An xsd:ID must not start with a digit; the request id is the one value the Response must answer.
  const requestId = `_${random(24).replace(/[-_]/g, "x")}`
  deps.sql.exec(
    `INSERT INTO sso_logins2 (state, connection, nonce, verifier, client_challenge, redirect_uri, return_to, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
    state, c.id, requestId, "", clientChallenge, acsUrl, returnTo, deps.now + LOGIN_TTL_MS
  )
  const request =
    `<samlp:AuthnRequest xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol" xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion"` +
    ` ID="${requestId}" Version="2.0" IssueInstant="${new Date(deps.now).toISOString()}" Destination="${xmlAttr(saml.sso_url)}"` +
    ` AssertionConsumerServiceURL="${xmlAttr(acsUrl)}" ProtocolBinding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST">` +
    `<saml:Issuer>${xmlAttr(spEntityId)}</saml:Issuer>` +
    `<samlp:NameIDPolicy Format="${NAMEID_EMAIL}" AllowCreate="true"/>` +
    `</samlp:AuthnRequest>`
  const url = new URL(saml.sso_url)
  url.searchParams.set("SAMLRequest", await deflateRawBase64(request))
  url.searchParams.set("RelayState", state)
  url.searchParams.set("login_hint", email)
  return { ok: true, url: url.toString() }
}

/** The person's email from a SAML identity: an email-format NameID, else a common email attribute. */
const samlEmail = (nameId: string, format: string | null, attributes: Readonly<Record<string, ReadonlyArray<string>>>): string | undefined => {
  const candidates: Array<string | undefined> = []
  if (format === NAMEID_EMAIL) candidates.push(nameId)
  const lower = Object.fromEntries(Object.entries(attributes).map(([k, v]) => [k.toLowerCase(), v]))
  for (const key of SAML_EMAIL_ATTRIBUTES) candidates.push(lower[key.toLowerCase()]?.[0])
  if (format === null || format === "urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified") candidates.push(nameId)
  for (const v of candidates) {
    const e = v?.toLowerCase()
    if (e && EMAIL.test(e)) return e
  }
  return undefined
}

/** POST /v1/sso/saml/acs/:connection: the IdP's Response -> Stack user and session -> one-time redeem code. */
export const ssoSamlAcs = async (deps: LoginDeps, relayState: string, samlResponse: string, pathConnection: string, origin: string): Promise<{ ok: true; returnTo: string; redeem: string } | LoginError> => {
  ensureLoginTables(deps.sql)
  const fail = (code: string, message: string): LoginError => ({ ok: false, code, message })
  // One use only, whatever happens next.
  const row = deps.sql.exec<{ connection: string; nonce: string; client_challenge: string; redirect_uri: string; return_to: string; expires_at: number }>(
    `DELETE FROM sso_logins2 WHERE state = ? RETURNING connection, nonce, client_challenge, redirect_uri, return_to, expires_at`, relayState
  ).toArray()[0]
  if (!row || row.expires_at <= deps.now) return fail("sso.state_invalid", "the sign-in link expired; start again")
  if (pathConnection !== row.connection) return fail("sso.state_invalid", "the sign-in link does not belong to this connection")
  const c = deps.state.sso_connections?.[row.connection]
  if (!c || c.kind !== "saml" || c.state !== "active" || !c.saml) return fail("sso.not_configured", "this SSO connection is not active")
  const { spEntityId, acsUrl } = samlEndpoints(origin, deps.team, c.id)
  // The ACS URL the request named; a different origin (another deployment) is refused.
  if (acsUrl !== row.redirect_uri) return fail("sso.state_invalid", "the sign-in started on another service")
  const result = await validateSamlResponse(samlResponse, {
    idpEntityId: c.saml.idp_entity_id,
    spEntityId,
    acsUrl,
    requestId: row.nonce,
    certificates: c.saml.certificates,
    now: deps.now
  })
  if (!result.ok) return fail(result.code === "saml.idp_error" ? "sso.idp_error" : "sso.token_invalid", result.message)
  const id = result.identity
  // Replay: an assertion id is spent once per IdP, until it expires.
  const assertionKey = await sha256(`${c.saml.idp_entity_id}\n${id.assertionId}`)
  deps.sql.exec(`DELETE FROM sso_saml_replay WHERE until <= ?`, deps.now)
  const spent = deps.sql.exec(`INSERT OR IGNORE INTO sso_saml_replay (assertion_key, until) VALUES (?, ?)`, assertionKey, Math.max(id.replayUntil, deps.now + LOGIN_TTL_MS))
  if (spent.rowsWritten === 0) return fail("sso.token_invalid", "this SAML assertion was already used")
  const email = samlEmail(id.nameId, id.nameIdFormat, id.attributes)
  if (!email) return fail("sso.token_invalid", "the SAML assertion has no email; send an email NameID or an email attribute")
  const domain = email.slice(email.lastIndexOf("@") + 1)
  if (!c.domains.includes(domain) || deps.state.domains?.[domain]?.state !== "verified") return fail("sso.domain_mismatch", "this account's email domain is not served by this SSO connection")
  const name = id.attributes["displayName"]?.[0] ?? id.attributes["name"]?.[0]
  const subject = await sha256(`${c.saml.idp_entity_id}\n${id.nameId}`)
  return finishSignIn(deps, c, { subject, email, ...(name ? { name } : {}) }, row, relayState)
}

/** GET /v1/sso/saml/metadata/:team/:connection: SP metadata to give the IdP (public; no secret in it). */
export const ssoSamlMetadata = (state: TeamState, team: string, connection: string, origin: string): string | undefined => {
  const c = state.sso_connections?.[connection]
  if (!c || c.kind !== "saml" || c.state === "disabled") return undefined
  const { spEntityId, acsUrl } = samlEndpoints(origin, team, c.id)
  return (
    `<?xml version="1.0" encoding="UTF-8"?>\n` +
    `<md:EntityDescriptor xmlns:md="urn:oasis:names:tc:SAML:2.0:metadata" entityID="${xmlAttr(spEntityId)}">` +
    `<md:SPSSODescriptor AuthnRequestsSigned="false" WantAssertionsSigned="true" protocolSupportEnumeration="urn:oasis:names:tc:SAML:2.0:protocol">` +
    `<md:NameIDFormat>${NAMEID_EMAIL}</md:NameIDFormat>` +
    `<md:AssertionConsumerService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST" Location="${xmlAttr(acsUrl)}" index="0" isDefault="true"/>` +
    `</md:SPSSODescriptor></md:EntityDescriptor>\n`
  )
}
