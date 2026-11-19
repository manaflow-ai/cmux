import { createFileRoute, Link } from "@tanstack/react-router"
import { useEffect, useRef } from "react"
import { useLoad } from "../../lib/hooks"
import { integrationAppAttemptHint, integrationCompletionRequest, integrationConfigureLink, integrationReturnLink } from "../../lib/integration-callback"
import { callbackSearch } from "../../lib/search"
import { type AppHandoff, completeIntegration, handOffIntegration } from "../../lib/server"
import { setSignedIn, useSignedIn } from "../../lib/session"
import { INTEGRATION_RETURN_TEAM_KEY, integrationReturnPath, integrationReturnTeamKey } from "./-return"

/**
 * Where GitHub (Setup URL), Linear and Slack redirect after approval. A connect
 * the cmux app started (#46018) is verified and handed over on the server before
 * anything renders (`handOffIntegration`): the provider's answer goes to the API,
 * and the page opens the app's link (and shows it, for a browser that does not
 * follow it) with only the connection id and a single-use handoff value; the app
 * finishes it with its own session and secret, no sign-in here. Any other connect is finished here by the signed-in user's own
 * session; the API refuses a state that belongs to someone else.
 */
export const Route = createFileRoute("/integrations/callback")({
  validateSearch: callbackSearch,
  loaderDeps: ({ search }) => ({ state: search.state, code: search.code, installation_id: search.installation_id, setup_action: search.setup_action, error: search.error }),
  loader: async ({ deps }): Promise<{ appHandoff?: AppHandoff }> => {
    // The unverified hint only picks this path; handOffIntegration verifies the state before any link is made.
    if (!deps.state || deps.error || !integrationAppAttemptHint(deps.state)) return {}
    const appHandoff = await handOffIntegration({ data: { state: deps.state, ...(deps.code ? { code: deps.code } : {}), ...(deps.installation_id ? { installation_id: deps.installation_id } : {}), ...(deps.setup_action ? { setup_action: deps.setup_action } : {}) } })
    return { appHandoff }
  },
  component: Callback
})

function Callback() {
  const signedIn = useSignedIn()
  const search = Route.useSearch()
  const { appHandoff } = Route.useLoaderData()
  const redirectScheduled = useRef(false)
  const appOpened = useRef(false)
  const appHref = appHandoff && "href" in appHandoff ? appHandoff.href : undefined
  // The verified hand-off's app link (no provider code in it): opened once; the page keeps it as a link.
  useEffect(() => {
    if (!appHref || appOpened.current) return
    appOpened.current = true
    window.location.assign(appHref)
  }, [appHref])
  // A connect the app started is the app's to finish (the loader handed it over); never finish it here too.
  const appAttempt = integrationAppAttemptHint(search.state)
  const result = useLoad<{ ok: boolean; message: string; returnTo?: string; configure?: string; development?: boolean }>(signedIn && search.state && !search.error && !appAttempt ? `complete:${search.state}` : null, async () => {
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
      team = sessionStorage.getItem(key)
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
  if (appAttempt)
    return (
      <>
        <h2>Connecting</h2>
        {search.error ? <p className="error">The provider reported: {search.error}</p> : null}
        {appHandoff && "refused" in appHandoff ? <p className="error">{appHandoff.refused}</p> : null}
        {appHref ? (
          <p>
            <a href={appHref}>Open cmux</a> to finish connecting.
          </p>
        ) : null}
      </>
    )
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
