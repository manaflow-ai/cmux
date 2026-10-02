import type { Env } from "./env.ts"

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } })
const TEAM = /^team_[a-z0-9]{20}$/

/**
 * Where a finished sign-in may send the browser: the dashboard, or the app's
 * own callback for ASWebAuthenticationSession. Anything else is refused (no
 * open redirect carrying a redeem code).
 */
export const allowedReturnTo = (env: Env, returnTo: string): boolean => {
  if (returnTo === "cmux://sso-complete") return true
  if (returnTo === "cmux-dev://sso-complete") return env.ENVIRONMENT !== "production"
  // Exact URL only: an open redirect elsewhere on the dashboard would carry the fragment along.
  return Boolean(env.DASHBOARD_ORIGIN) && returnTo === `${env.DASHBOARD_ORIGIN!.replace(/\/+$/, "")}/sso/complete`
}

const CHALLENGE = /^[A-Za-z0-9_-]{43}$/
const SSOC = /^ssoc_[a-z0-9]{20}$/

const limited = async (env: Env, request: Request) => {
  if (!env.SSO_DISCOVER_LIMIT) return false
  const { success } = await env.SSO_DISCOVER_LIMIT.limit({ key: request.headers.get("cf-connecting-ip") ?? "unknown" })
  return !success
}

const teamOf = (value: string) => {
  const team = value.split(".")[0] ?? ""
  return TEAM.test(team) ? team : undefined
}

/** GET /v1/sso/start?email=&return_to= -> 302 to the IdP. */
export const handleSsoStart = async (request: Request, env: Env): Promise<Response> => {
  const url = new URL(request.url)
  const email = (url.searchParams.get("email") ?? "").trim().toLowerCase()
  const returnTo = url.searchParams.get("return_to") ?? ""
  if (!allowedReturnTo(env, returnTo)) return json({ error: "return_to is not allowed" }, 400)
  // The client's own PKCE-style challenge: only it can redeem the result (login CSRF defense).
  const clientChallenge = url.searchParams.get("client_challenge") ?? ""
  if (!CHALLENGE.test(clientChallenge)) return json({ error: "client_challenge (base64url SHA-256 of a client secret) is required" }, 400)
  const domain = email.slice(email.lastIndexOf("@") + 1)
  if (!email.includes("@") || !domain) return json({ error: "a valid email is required" }, 400)
  if (await limited(env, request)) return json({ error: "rate limited" }, 429)
  const owner = await env.DOMAIN_DO.get(env.DOMAIN_DO.idFromName(domain)).owner()
  if (!owner) return json({ error: "this email does not sign in with SSO" }, 404)
  const r = await env.TEAM_DO.get(env.TEAM_DO.idFromName(owner)).ssoStart(owner, email, `${url.origin}/v1/sso/callback`, returnTo, clientChallenge)
  if (!r.ok) return json({ error: r.message }, 404)
  return new Response(null, { status: 302, headers: { location: r.url, "cache-control": "no-store" } })
}

/** GET /v1/sso/callback/<connection>?code=&state=[&iss=] -> 302 to return_to with a one-time code (or an error). */
export const handleSsoCallback = async (request: Request, env: Env, connection: string): Promise<Response> => {
  const url = new URL(request.url)
  const state = url.searchParams.get("state") ?? ""
  const code = url.searchParams.get("code") ?? ""
  const team = teamOf(state)
  // A fixed message: never reflect the IdP's error text.
  if (!team || !code || !SSOC.test(connection)) return json({ error: "the sign-in did not complete" }, 400)
  if (await limited(env, request)) return json({ error: "rate limited" }, 429)
  const r = await env.TEAM_DO.get(env.TEAM_DO.idFromName(team)).ssoCallback(team, state, code, connection, url.searchParams.get("iss"))
  if (!r.ok) return json({ error: r.message, code: r.code }, 400)
  const target = new URL(r.returnTo)
  // In the fragment, so it reaches neither server logs nor Referer headers.
  target.hash = `sso_code=${encodeURIComponent(r.redeem)}`
  return new Response(null, { status: 302, headers: { location: target.toString(), "cache-control": "no-store", "referrer-policy": "no-referrer" } })
}

/** POST /v1/sso/redeem {code} -> {access_token, refresh_token} (Stack session), once. */
export const handleSsoRedeem = async (request: Request, env: Env): Promise<Response> => {
  if (request.method !== "POST") return json({ error: "method not allowed" }, 405)
  if (await limited(env, request)) return json({ error: "rate limited" }, 429)
  const body = (await request.json().catch(() => ({}))) as { code?: unknown; client_verifier?: unknown }
  const code = typeof body.code === "string" ? body.code : ""
  const verifier = typeof body.client_verifier === "string" ? body.client_verifier : ""
  const team = teamOf(code)
  if (!team || verifier.length < 43 || verifier.length > 128) return json({ error: "the sign-in code expired, was used, or belongs to another client" }, 400)
  const r = await env.TEAM_DO.get(env.TEAM_DO.idFromName(team)).ssoRedeem(team, code, verifier)
  return r.ok ? json({ access_token: r.access_token, refresh_token: r.refresh_token }) : json({ error: r.message }, 400)
}
