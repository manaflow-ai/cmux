import type { Env } from "../env.ts"
import { integrationCallbackUrl, stateNamingInstallation } from "./state.ts"

/**
 * GET /v1/integrations/github/authorize?state=&installation_id= : the second half of a connect that came back
 * from GitHub with an installation and no code.
 *
 * Connect opens the App's install page. When the App is already installed on the account the person picks,
 * GitHub shows that installation's settings instead, and after Save it redirects with `installation_id` and
 * `setup_action=update` but no `code`. Without a code nothing proves who the GitHub user is, so the connection
 * cannot be finished. The console sends that redirect here: this answers a 302 to GitHub's authorize page (which
 * GitHub skips for an App the person already authorized) with the same connect state re-signed to name the
 * installation. GitHub then comes back with a code, and `integration.complete` takes the installation from the
 * state, as it does for a connect that started on the authorize page.
 *
 * No sign-in: the browser arrives from GitHub with no cmux session. It answers only for a state this API signed
 * that has not expired, and the new state expires when the old one does. Naming the installation grants nothing:
 * completion still proves, with the person's own GitHub token, that they can reach it, and only for the person
 * and team the state was signed for. A refusal goes back to the callback page with `error`, never to GitHub.
 */
export const GITHUB_AUTHORIZE_PATH = "/v1/integrations/github/authorize"

/** The `error` the callback gets when the state did not verify: the person starts the connect again. */
export const AUTHORIZE_REFUSED = "connection_link_expired"

const NO_STORE = { "cache-control": "no-store", "referrer-policy": "no-referrer" }
const to = (location: string) => new Response(null, { status: 302, headers: { ...NO_STORE, location } })

export const handleGithubAuthorize = async (request: Request, env: Env): Promise<Response> => {
  if (request.method !== "GET" && request.method !== "HEAD") return new Response(null, { status: 405, headers: { ...NO_STORE, allow: "GET, HEAD" } })
  const callback = integrationCallbackUrl(env)
  if (!env.GITHUB_APP_CLIENT_ID || !callback.startsWith("http")) return Response.json({ error: { code: "integration.unavailable", message: "GitHub is not configured here" } }, { status: 503, headers: NO_STORE })
  const query = new URL(request.url).searchParams
  const state = query.get("state") ?? ""
  const id = query.get("installation_id") ?? ""
  const installation = /^[0-9]{1,20}$/.test(id) ? Number(id) : Number.NaN
  const signed = state.length <= 4096 ? await stateNamingInstallation(env, state, installation) : undefined
  // The old state goes back only so the callback can tell an app's connect from the console's own; it names no code.
  if (!signed) return to(`${callback}?${new URLSearchParams({ ...(state && state.length <= 4096 ? { state } : {}), error: AUTHORIZE_REFUSED })}`)
  return to(`https://github.com/login/oauth/authorize?${new URLSearchParams({ client_id: env.GITHUB_APP_CLIENT_ID, redirect_uri: callback, state: signed })}`)
}
