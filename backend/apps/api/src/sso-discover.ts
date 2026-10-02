import type { Env } from "./env.ts"

const DOMAIN = /^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/

/**
 * GET /v1/sso/discover?email= (no account needed): whether the email's domain
 * signs in through an enterprise connection (spec/enterprise.md 3.3 step 1).
 * Answers only {sso: true|false}, never the team or the connection, so it does
 * not enumerate customers. The domain is the exact lowercased part after "@"
 * (no suffix matching: a verified parent never covers a subdomain).
 */
export const handleSsoDiscover = async (request: Request, env: Env): Promise<Response> => {
  const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } })
  if (request.method !== "GET") return json({ error: "method not allowed" }, 405)
  const email = new URL(request.url).searchParams.get("email") ?? ""
  const at = email.lastIndexOf("@")
  let domain = at > 0 ? email.slice(at + 1).trim().toLowerCase() : ""
  // Unicode domains in their ASCII (punycode) form, the form domain claims use.
  try {
    if (domain && !/^[\x00-\x7f]*$/.test(domain)) domain = new URL(`http://${domain}`).hostname
  } catch {
    domain = ""
  }
  if (!DOMAIN.test(domain)) return json({ error: "a valid email is required" }, 400)
  const owner = await env.DOMAIN_DO.get(env.DOMAIN_DO.idFromName(domain)).owner()
  if (!owner) return json({ sso: false })
  const { sso } = await env.TEAM_DO.get(env.TEAM_DO.idFromName(owner)).ssoDiscover(owner, domain)
  return json({ sso })
}
