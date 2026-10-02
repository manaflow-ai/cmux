import { createFileRoute, Link } from "@tanstack/react-router"
import { useLoad } from "../../lib/hooks"
import { mutate } from "../../lib/server"
import { setSignedIn, useSignedIn } from "../../lib/session"

/**
 * Where GitHub (Setup URL), Linear and Slack redirect after approval. The
 * signed-in user's own session finishes the connection; the API refuses a
 * state that belongs to someone else.
 */
export const Route = createFileRoute("/integrations/callback")({
  validateSearch: (s: Record<string, unknown>) => ({
    state: typeof s.state === "string" ? s.state : undefined,
    code: typeof s.code === "string" ? s.code : undefined,
    installation_id: typeof s.installation_id === "string" || typeof s.installation_id === "number" ? String(s.installation_id) : undefined,
    setup_action: typeof s.setup_action === "string" ? s.setup_action : undefined,
    error: typeof s.error === "string" ? s.error : undefined
  }),
  component: Callback
})

function Callback() {
  const signedIn = useSignedIn()
  const search = Route.useSearch()
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
