import { createFileRoute, Link } from "@tanstack/react-router"
import { useEffect, useRef } from "react"
import { useLoad } from "../../lib/hooks"
import { callbackSearch } from "../../lib/search"
import { mutate } from "../../lib/server"
import { setSignedIn, useSignedIn } from "../../lib/session"
import { INTEGRATION_RETURN_TEAM_KEY, integrationReturnPath, integrationReturnTeamKey } from "./-return"

/**
 * Where GitHub (Setup URL), Linear and Slack redirect after approval. The
 * signed-in user's own session finishes the connection; the API refuses a
 * state that belongs to someone else.
 */
export const Route = createFileRoute("/integrations/callback")({
  validateSearch: callbackSearch,
  component: Callback
})

function Callback() {
  const signedIn = useSignedIn()
  const search = Route.useSearch()
  const redirectScheduled = useRef(false)
  const result = useLoad<{ ok: boolean; message: string }>(signedIn && search.state && !search.error ? `complete:${search.state}` : null, async () => {
    const params: Record<string, unknown> = { state: search.state }
    if (search.code) params.code = search.code
    if (search.installation_id) params.installation_id = search.installation_id
    if (search.setup_action) params.setup_action = search.setup_action
    // The key is derived from the state, so a reload of this page replays instead of exchanging the code twice.
    const r = await mutate({ data: { op: "integration.complete", params, idempotency_key: `complete:${search.state!.slice(-40)}` } })
    if (r.status === 401) setSignedIn(false)
    if (r.body.ok) return { ok: true, message: "Connected." }
    return { ok: false, message: `${r.body.error?.code ?? r.status}: ${r.body.error?.message ?? "failed"}` }
  })
  useEffect(() => {
    if (!result.data?.ok || redirectScheduled.current) return
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
    const timer = window.setTimeout(() => window.location.replace(integrationReturnPath(team)), 350)
    return () => window.clearTimeout(timer)
  }, [result.data?.ok])
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
      <p>
        <Link to="/integrations">Back to integrations</Link>
      </p>
    </>
  )
}
