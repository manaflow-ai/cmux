import type { Env } from "./env.ts"

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } })
const TEAM = /^team_[a-z0-9]{20}$/

/**
 * Where a finished sign-in may send the browser: the dashboard, or the app's
 * own callback for ASWebAuthenticationSession. Anything else is refused (no
 * open redirect carrying a redeem code).
 */
export const allowedReturnTo = (env: Env, returnTo: string): boolean => {
  if (returnTo === "cmux://sso-complete" || returnTo === "cmux-dev://sso-complete") return true
  if (!env.DASHBOARD_ORIGIN) return false
  try {
    return new URL(returnTo).origin === new URL(env.DASHBOARD_ORIGIN).origin
  } catch {
    return false
  }
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
  const domain = email.slice(email.lastIndexOf("@") + 1)
  if (!email.includes("@") || !domain) return json({ error: "a valid email is required" }, 400)
  if (env.SSO_DISCOVER_LIMIT) {
    const { success } = await env.SSO_DISCOVER_LIMIT.limit({ key: request.headers.get("cf-connecting-ip") ?? "unknown" })
    if (!success) return json({ error: "rate limited" }, 429)
  }
  const owner = await env.DOMAIN_DO.get(env.DOMAIN_DO.idFromName(domain)).owner()
  if (!owner) return json({ error: "this email does not sign in with SSO" }, 404)
  const r = await env.TEAM_DO.get(env.TEAM_DO.idFromName(owner)).ssoStart(owner, email, `${url.origin}/v1/sso/callback`, returnTo)
  if (!r.ok) return json({ error: r.message }, 404)
  return new Response(null, { status: 302, headers: { location: r.url, "cache-control": "no-store" } })
}

/** GET /v1/sso/callback?code=&state= -> 302 to return_to with a one-time code (or an error). */
export const handleSsoCallback = async (request: Request, env: Env): Promise<Response> => {
  const url = new URL(request.url)
  const state = url.searchParams.get("state") ?? ""
  const code = url.searchParams.get("code") ?? ""
  const team = teamOf(state)
  if (!team || !code) return json({ error: url.searchParams.get("error_description") ?? "the sign-in did not complete" }, 400)
  const r = await env.TEAM_DO.get(env.TEAM_DO.idFromName(team)).ssoCallback(team, state, code)
  if (!r.ok) return json({ error: r.message, code: r.code }, 400)
  const target = new URL(r.returnTo)
  // In the fragment, so it reaches neither server logs nor Referer headers.
  target.hash = `sso_code=${encodeURIComponent(r.redeem)}`
  return new Response(null, { status: 302, headers: { location: target.toString(), "cache-control": "no-store", "referrer-policy": "no-referrer" } })
}

/** POST /v1/sso/redeem {code} -> {access_token, refresh_token} (Stack session), once. */
export const handleSsoRedeem = async (request: Request, env: Env): Promise<Response> => {
  if (request.method !== "POST") return json({ error: "method not allowed" }, 405)
  const body = (await request.json().catch(() => ({}))) as { code?: unknown }
  const code = typeof body.code === "string" ? body.code : ""
  const team = teamOf(code)
  if (!team) return json({ error: "the sign-in code expired or was used" }, 400)
  const r = await env.TEAM_DO.get(env.TEAM_DO.idFromName(team)).ssoRedeem(team, code)
  return r.ok ? json({ access_token: r.access_token, refresh_token: r.refresh_token }) : json({ error: r.message }, 400)
}
