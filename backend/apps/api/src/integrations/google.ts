import type { Env } from "../env.ts"
import { json, ProviderError, type Approved, type Credential, type Http } from "./provider-core.ts"

/**
 * Google OAuth shared by the `gmail` and `google_calendar` providers (one
 * OAuth client, two connections; plans/cmux-next/integrations-plan.md G1).
 * Web server flow with PKCE (S256), offline access and fresh consent. The
 * PKCE verifier is derived on the server from the KEK and the connection id,
 * so it never travels in a URL and needs no storage.
 */

export const GOOGLE_AUTH = "https://accounts.google.com/o/oauth2/v2/auth"
export const GOOGLE_TOKEN = "https://oauth2.googleapis.com/token"
export const GOOGLE_USERINFO = "https://openidconnect.googleapis.com/v1/userinfo"
const AUTH = "https://www.googleapis.com/auth/"

/** cmux's short scope names and their Google values. Nothing else may be asked for. */
export const GOOGLE_SCOPES: Readonly<Record<string, string>> = {
  "gmail.send": `${AUTH}gmail.send`,
  "gmail.readonly": `${AUTH}gmail.readonly`,
  "gmail.modify": `${AUTH}gmail.modify`,
  "calendar.events": `${AUTH}calendar.events`,
  "calendar.calendarlist.readonly": `${AUTH}calendar.calendarlist.readonly`
}
const SHORT_BY_URL = new Map(Object.entries(GOOGLE_SCOPES).map(([k, v]) => [v, k]))

/** Restricted Gmail scopes: server-side use needs Google's yearly security assessment (D14, S3). */
export const RESTRICTED_SCOPES: ReadonlySet<string> = new Set(["gmail.readonly", "gmail.modify"])

/**
 * `GOOGLE_RESTRICTED_SCOPES`: `testing` (dev project in Testing mode),
 * `internal` (Workspace-internal app) or `verified` (after the Letter of
 * Validation). Unset = this deployment never asks for a restricted scope.
 */
export const restrictedScopesEnabled = (env: Env) => {
  const mode = env.GOOGLE_RESTRICTED_SCOPES ?? ""
  // Production honors only `verified`: a Testing or Internal setting copied there by mistake stays off.
  return env.ENVIRONMENT === "production" ? mode === "verified" : ["testing", "internal", "verified"].includes(mode)
}

/** Scopes this deployment may use now; a restricted scope granted earlier stops working when the gate closes. */
export const usableScopes = (env: Env, scopes: ReadonlyArray<string>) => scopes.filter((s) => !RESTRICTED_SCOPES.has(s) || restrictedScopesEnabled(env))

export const googleConfigured = (env: Env) => Boolean(env.GOOGLE_CLIENT_ID && env.GOOGLE_CLIENT_SECRET)

export const refuseGoogleScopes =
  (allowed: ReadonlyArray<string>) =>
  (env: Env, scopes: ReadonlyArray<string>): string | undefined => {
    for (const s of scopes) {
      if (!allowed.includes(s)) return `${s} is not a scope this provider asks for (allowed: ${allowed.join(", ")})`
      if (RESTRICTED_SCOPES.has(s) && !restrictedScopesEnabled(env)) return `${s} is a restricted Gmail scope; this deployment may not ask for it before Google's security assessment`
    }
    return undefined
  }

const b64url = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const enc = new TextEncoder()

/** An HMAC key derived from the KEK with HKDF, so the KEK itself only ever wraps data keys. */
const pkceKeys = new Map<string, Promise<CryptoKey>>()
const pkceKey = (kek: string) => {
  let k = pkceKeys.get(kek)
  if (!k) {
    k = (async () => {
      const raw = Uint8Array.from(atob(kek), (c) => c.charCodeAt(0))
      const base = await crypto.subtle.importKey("raw", raw, "HKDF", false, ["deriveKey"])
      raw.fill(0)
      return crypto.subtle.deriveKey(
        { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(32), info: enc.encode("cmux-google-pkce-v1") },
        base,
        { name: "HMAC", hash: "SHA-256", length: 256 },
        false,
        ["sign"]
      )
    })()
    pkceKeys.set(kek, k)
  }
  return k
}

/**
 * 43 base64url characters (RFC 7636 allows 43 to 128), one per connection
 * attempt: bound to the connection and to the signed state of that attempt.
 */
export const pkceVerifier = async (env: Env, connection: string, state: string): Promise<string> => {
  if (!env.INTEGRATIONS_KEK) throw new ProviderError("integration.unavailable", "integrations are not configured (no INTEGRATIONS_KEK)")
  const stateHash = b64url(new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode(state))))
  return b64url(new Uint8Array(await crypto.subtle.sign("HMAC", await pkceKey(env.INTEGRATIONS_KEK), enc.encode(`${connection}|${stateHash}`))))
}

export const pkceChallenge = async (verifier: string) => b64url(new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode(verifier))))

export const googleAuthorizeUrl = async (env: Env, state: string, scopes: ReadonlyArray<string>, redirectUri: string, connection: string): Promise<string> => {
  const google = scopes.map((s) => GOOGLE_SCOPES[s]).filter((s): s is string => typeof s === "string")
  return `${GOOGLE_AUTH}?${new URLSearchParams({
    client_id: env.GOOGLE_CLIENT_ID!,
    redirect_uri: redirectUri,
    response_type: "code",
    scope: ["openid", "email", ...google].join(" "),
    state,
    access_type: "offline",
    // Always a refresh token, and never scopes granted earlier to another cmux connection.
    prompt: "consent",
    include_granted_scopes: "false",
    code_challenge: await pkceChallenge(await pkceVerifier(env, connection, state)),
    code_challenge_method: "S256"
  })}`
}

const tokenCredential = (b: Record<string, unknown>, previousRefresh?: string): Credential => {
  const refresh = typeof b.refresh_token === "string" ? b.refresh_token : previousRefresh
  return {
    kind: "oauth",
    access_token: String(b.access_token),
    ...(refresh ? { refresh_token: refresh } : {}),
    ...(typeof b.expires_in === "number" ? { expires_at: Date.now() + b.expires_in * 1000 } : {})
  }
}

/** Google's granted scopes as cmux short names; sign-in scopes and unknown values are dropped. */
export const grantedScopes = (scope: unknown): Array<string> =>
  String(scope ?? "")
    .split(/\s+/)
    .map((s) => SHORT_BY_URL.get(s))
    .filter((s): s is string => typeof s === "string")
    .sort()

const tokenRequest = (http: Http, fields: Record<string, string>) =>
  http(new Request(GOOGLE_TOKEN, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: new URLSearchParams(fields).toString() }))

/**
 * Exchanges the code (with the PKCE verifier), reads the account from the
 * userinfo endpoint and requires a verified email. With granular consent the
 * user may grant only some scopes; at least one requested product scope must
 * be granted, and ops check their own scope at call time.
 */
export const googleComplete =
  (provider: "gmail" | "google_calendar") =>
  async (env: Env, http: Http, p: { code?: string; redirectUri: string; connection: string; state: string; scopes_requested: ReadonlyArray<string> }): Promise<Approved> => {
    if (!p.code) throw new ProviderError("integration.state_invalid", "Google returned no code")
    const res = await tokenRequest(http, {
      code: p.code,
      client_id: env.GOOGLE_CLIENT_ID!,
      client_secret: env.GOOGLE_CLIENT_SECRET!,
      redirect_uri: p.redirectUri,
      grant_type: "authorization_code",
      code_verifier: await pkceVerifier(env, p.connection, p.state)
    })
    const b = await json(res)
    if (!res.ok || typeof b.access_token !== "string") throw new ProviderError("integration.state_invalid", "Google code exchange failed")
    if (typeof b.refresh_token !== "string") throw new ProviderError("integration.state_invalid", "Google returned no refresh token; connect again")
    const info = await http(new Request(GOOGLE_USERINFO, { headers: { authorization: `Bearer ${b.access_token}` } }))
    const u = await json(info)
    if (!info.ok || typeof u.sub !== "string" || typeof u.email !== "string" || u.email_verified !== true) throw new ProviderError("integration.state_invalid", "Google did not return a verified account email")
    // The authorize URL passes through the client, which can add scopes to it: keep only what this
    // attempt asked for and what the deployment may use now (restricted scopes before CASA).
    const scopes = usableScopes(env, grantedScopes(b.scope).filter((s) => p.scopes_requested.includes(s)))
    if (!p.scopes_requested.some((s) => scopes.includes(s))) throw new ProviderError("integration.state_invalid", "no requested Google permission was granted; connect again and allow access")
    return {
      account: { key: `${provider}:${u.sub}`, name: u.email.toLowerCase() },
      scopes_granted: scopes,
      credential: tokenCredential(b)
    }
  }

/** Google does not rotate refresh tokens; `invalid_grant` means the user revoked access (or Testing mode's 7 days ended). */
export const googleRefresh = async (env: Env, http: Http, credential: Credential): Promise<Credential | undefined> => {
  if (credential.kind !== "oauth" || credential.expires_at === undefined || credential.expires_at - 60_000 > Date.now()) return undefined
  if (!credential.refresh_token) throw new ProviderError("needs_reauth", "Google token expired and has no refresh token")
  const res = await tokenRequest(http, { client_id: env.GOOGLE_CLIENT_ID!, client_secret: env.GOOGLE_CLIENT_SECRET!, refresh_token: credential.refresh_token, grant_type: "refresh_token" })
  const b = await json(res)
  if (!res.ok || typeof b.access_token !== "string") {
    // Only invalid_grant means the user's grant is gone; invalid_client and the like are our configuration
    // and must not send every connection to re-authorization.
    if (b.error === "invalid_grant") throw new ProviderError("needs_reauth", "Google refused the refresh token (access was removed or expired)")
    const transient = res.status >= 500 || res.status === 429
    throw new ProviderError("provider.error", `Google refresh failed: HTTP ${res.status}`, transient)
  }
  return tokenCredential(b, credential.refresh_token)
}

/**
 * One Google API call. Never echoes a response body. 401 = reauth; 429 and
 * 403 with a rate-limit reason are retryable; for the effect call (`effect`)
 * a 5xx or a network failure after sending is indeterminate.
 */
export const googleApi = async (http: Http, token: string, method: string, url: string, opts: { body?: unknown; effect?: boolean; what: string }): Promise<Record<string, unknown>> => {
  const req = new Request(url, {
    method,
    headers: { authorization: `Bearer ${token}`, ...(opts.body !== undefined ? { "content-type": "application/json" } : {}) },
    ...(opts.body !== undefined ? { body: JSON.stringify(opts.body) } : {})
  })
  let res: Response
  try {
    res = await http(req)
  } catch {
    if (opts.effect) throw new ProviderError("mutation.indeterminate", `google ${opts.what}: the request failed in flight; Google may have acted`)
    throw new ProviderError("provider.error", `google ${opts.what}: network error`, true)
  }
  if (res.ok) return res.status === 204 ? {} : json(res)
  if (res.status === 401) throw new ProviderError("needs_reauth", `google ${opts.what} failed: HTTP 401`)
  if (res.status === 404) throw new ProviderError("provider.error", `google ${opts.what}: not found`, false, 404)
  if (res.status === 429) throw new ProviderError("provider.error", `google ${opts.what}: rate limited`, true)
  if (res.status === 403) {
    const reason = String((((await json(res)).error as { errors?: Array<{ reason?: unknown }> } | undefined)?.errors?.[0]?.reason) ?? "")
    if (/rateLimitExceeded|userRateLimitExceeded|quotaExceeded/.test(reason)) throw new ProviderError("provider.error", `google ${opts.what}: rate limited`, true)
    if (reason === "insufficientPermissions") throw new ProviderError("integration.unavailable", `google ${opts.what}: the connection lacks the permission; reconnect and allow it`)
    throw new ProviderError("provider.error", `google ${opts.what} failed: HTTP 403${reason ? ` (${reason.slice(0, 60)})` : ""}`)
  }
  if (opts.effect && res.status >= 500) throw new ProviderError("mutation.indeterminate", `google ${opts.what}: HTTP ${res.status}; Google may have acted`)
  throw new ProviderError("provider.error", `google ${opts.what} failed: HTTP ${res.status}`, res.status >= 500)
}

export const oauthToken = (credential: Credential) => {
  if (credential.kind !== "oauth") throw new ProviderError("provider.error", "wrong credential kind")
  return credential.access_token
}
