import { createFileRoute, Link } from "@tanstack/react-router"
import { useEffect, useRef } from "react"
import { useLoad } from "../../lib/hooks"
import { AUTHORIZE_REFUSED, integrationAppHandoff, integrationAppHandoffResponse, integrationAuthorizeBounce, integrationCompletionRequest, integrationConfigureLink, integrationReturnLink, integrationTeamHint } from "../../lib/integration-callback"
import { callbackSearch } from "../../lib/search"
import { apiUrl, completeIntegration } from "../../lib/server"
import { setSignedIn, useSignedIn } from "../../lib/session"
import { INTEGRATION_RETURN_TEAM_KEY, integrationReturnPath, integrationReturnTeamKey } from "./-return"

/**
 * Where GitHub (Setup URL), Linear and Slack redirect after approval. A connect
 * the cmux app started goes straight back to the app (`integrationAppHandoff`),
 * before anything renders and with no sign-in here: the app finishes it with its
 * own session (#46018). Any other connect is finished here by the signed-in
 * user's own session; the API refuses a state that belongs to someone else.
 */
export const Route = createFileRoute("/integrations/callback")({
  validateSearch: callbackSearch,
  // The provider's redirect is a full page load: before the router runs, the server sends a GitHub redirect that has
  // no code on to GitHub's authorize page, and answers an app handoff with a 302.
  server: {
    handlers: {
      GET: ({ request, next }) =>
        integrationAuthorizeBounce(request.url, { api: apiUrl, host: request.headers.get("x-forwarded-host") ?? request.headers.get("host") }) ??
        integrationAppHandoffResponse(request.url) ??
        next(),
    },
  },
  // Reached in the browser only (a client navigation here): the router refuses to redirect to an app scheme.
  beforeLoad: ({ search }) => {
    const handoff = integrationAppHandoff(search)
    if (handoff && typeof window !== "undefined") window.location.replace(handoff)
  },
  component: Callback
})

function Callback() {
  const signedIn = useSignedIn()
  const search = Route.useSearch()
  const redirectScheduled = useRef(false)
  // A connect the app started is the app's to finish (beforeLoad sent the browser there); never finish it here too.
  const handoff = integrationAppHandoff(search)
  const result = useLoad<{ ok: boolean; message: string; returnTo?: string; configure?: string; development?: boolean }>(signedIn && search.state && !search.error && !handoff ? `complete:${search.state}` : null, async () => {
    // The key is derived from the state, so a reload of this page replays instead of exchanging the code twice.
    const r = await completeIntegration({ data: integrationCompletionRequest(search.state!, search) })
    if (r.status === 401) setSignedIn(false)
    // A development connection (finished on the development API): this console's integrations list does not show it.
    if (r.body.ok && r.environment === "development" && !integrationConfigureLink(r.body.value) && !integrationReturnLink(r.body.value)) {
      return { ok: true, message: "Connected to the development Cloud. You can close this page.", development: true }
    }
    // A connect started from a chat returns to it: the link comes from the API's verified state, never this page's query.
    const returnTo = r.body.ok ? integrationReturnLink(r.body.value) : undefined
    // The link left the repository out: GitHub's settings page for the installation adds it.
    const configure = r.body.ok ? integrationConfigureLink(r.body.value) : undefined
    if (r.body.ok && configure) return { ok: true, message: "Connected, but this repository is not in the installation yet. Opening GitHub to add it.", configure, ...(returnTo ? { returnTo } : {}) }
    if (r.body.ok) return { ok: true, message: returnTo ? "Connected. Opening cmux." : "Connected.", ...(returnTo ? { returnTo } : {}) }
    return { ok: false, message: `${r.body.error?.code ?? r.status}: ${r.body.error?.message ?? "failed"}` }
  })
  useEffect(() => {
    if (!result.data?.ok || result.data.development || redirectScheduled.current) return
    redirectScheduled.current = true
    // Completing an OAuth flow should not strand the user on an intermediate
    // page. Keep the team scope selected before the provider redirect.
    let team: string | null = null
    try {
      const key = integrationReturnTeamKey(search.state)
      // A connect that went on through GitHub's authorize page comes back with a new state, so the key misses:
      // the state's own team (the one the connection was started in) is the same answer.
      team = sessionStorage.getItem(key) ?? integrationTeamHint(search.state) ?? null
      sessionStorage.removeItem(key)
      // Clean up the pre-keyed value left by older dashboard builds.
      if (key !== INTEGRATION_RETURN_TEAM_KEY) sessionStorage.removeItem(INTEGRATION_RETURN_TEAM_KEY)
    } catch {
      // Storage can be unavailable in private or embedded browser contexts.
    }
    // A connect from a chat goes on to GitHub's settings page (the repository is missing) or back to the chat.
    const { configure, returnTo } = result.data
    if (configure || returnTo) {
      window.location.assign(configure ?? returnTo!)
      return
    }
    const timer = window.setTimeout(() => window.location.replace(integrationReturnPath(team)), 350)
    return () => window.clearTimeout(timer)
  }, [result.data?.ok])
  if (handoff)
    return (
      <p>
        <a href={handoff}>Open cmux</a> to finish connecting GitHub.
      </p>
    )
  // Said before any sign-in prompt: a connect the app started has no session here, and signing in would not help.
  if (search.error === AUTHORIZE_REFUSED) return <p className="error">This connection link expired. Start the connection again.</p>
  if (signedIn === false)
    return (
      <p>
        <Link to="/">Sign in</Link> as the person who started this connection, then open the link again.
      </p>
    )
  return (
    <>
      <h2>Connecting</h2>
      {search.error ? <p className="error">The provider reported: {search.error}</p> : null}
      {!search.state ? <p className="error">This page needs the provider's redirect (no state).</p> : null}
      {result.loading ? <p className="muted">Finishing the connection</p> : null}
      {result.error ? <p className="error">{result.error}</p> : null}
      {result.data ? <p className={result.data.ok ? undefined : "error"}>{result.data.message}</p> : null}
      {result.data?.configure ? (
        <p>
          <a href={result.data.configure}>Add the repository on GitHub</a>
        </p>
      ) : null}
      {result.data?.returnTo ? (
        <p>
          <a href={result.data.returnTo}>Back to your chat in cmux</a>
        </p>
      ) : null}
      <p>
        <Link to="/integrations">Back to integrations</Link>
      </p>
    </>
  )
}
