import { createFileRoute, Link } from "@tanstack/react-router"
import { useState } from "react"
import { useLoad } from "../../lib/hooks"
import { mutate, read } from "../../lib/server"
import { newKey, setSignedIn, useSignedIn } from "../../lib/session"

export const Route = createFileRoute("/integrations/")({ component: Integrations })

interface Connection {
  id: string
  provider: "github" | "linear" | "slack"
  account: { key: string; name: string; url?: string } | null
  scopes_granted: Array<string>
  status: string
  status_detail?: string
  sharing: "private" | "team"
  created_at: number
}
interface Listing {
  connections: Array<Connection>
  providers: Array<{ provider: Connection["provider"]; configured: boolean }>
}

const LABEL: Record<Connection["provider"], string> = { github: "GitHub App", linear: "Linear", slack: "Slack bot" }

function Integrations() {
  const signedIn = useSignedIn()
  const [error, setError] = useState<string | null>(null)
  const list = useLoad<Listing>(signedIn ? "integrations" : null, async () => {
    const e = await mutate({ data: { op: "user.ensure", params: {}, idempotency_key: newKey() } })
    if (e.status === 401) setSignedIn(false)
    const r = await read({ data: { op: "integration.list", params: {} } })
    if (r.status !== 200) throw new Error(`integration.list failed: ${r.status}`)
    return r.body.value as unknown as Listing
  })
  if (signedIn === false)
    return (
      <p>
        <Link to="/">Sign in</Link> to connect integrations.
      </p>
    )

  const connect = async (provider: Connection["provider"]) => {
    setError(null)
    const r = await mutate({ data: { op: "integration.connect", params: { provider }, idempotency_key: newKey() } })
    if (r.status === 401) return setSignedIn(false)
    const value = r.body.value as unknown as { authorize_url?: string } | undefined
    if (!r.body.ok || !value?.authorize_url) return setError(`${r.body.error?.code ?? r.status}: ${r.body.error?.message ?? "connect failed"}`)
    // The provider asks the human to approve, then redirects to /integrations/callback.
    window.location.assign(value.authorize_url)
  }
  const revoke = async (c: Connection) => {
    if (!window.confirm(`Disconnect ${c.account?.name ?? LABEL[c.provider]}? The stored credential is deleted at once.`)) return
    const r = await mutate({ data: { op: "integration.revoke", params: { connection: c.id }, idempotency_key: newKey() } })
    if (!r.body.ok) setError(`${r.body.error?.code}: ${r.body.error?.message}`)
    list.reload()
  }

  return (
    <>
      <h2>Integrations</h2>
      <p className="muted">Provider tokens stay on the server, encrypted. Agents and automations use them only through cmux operations.</p>
      {list.error ? <p className="error">{list.error}</p> : null}
      {error ? <p className="error">{error}</p> : null}
      <div className="card" style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
        {(list.data?.providers ?? []).map((p) => (
          <button key={p.provider} disabled={!p.configured} title={p.configured ? undefined : "Not configured on this deployment"} onClick={() => void connect(p.provider)}>
            Connect {LABEL[p.provider]}
            {p.configured ? "" : " (not configured)"}
          </button>
        ))}
      </div>
      <div className="card">
        <table>
          <thead>
            <tr>
              <th>Connection</th>
              <th>Status</th>
              <th>Access</th>
              <th />
            </tr>
          </thead>
          <tbody>
            {(list.data?.connections ?? []).map((c) => (
              <tr key={c.id}>
                <td>
                  {LABEL[c.provider]} · {c.account ? c.account.url?.startsWith("https://") ? <a href={c.account.url} rel="noreferrer">{c.account.name}</a> : c.account.name : <span className="muted">not linked yet</span>}
                  <br />
                  <code className="muted">{c.id}</code>
                </td>
                <td>
                  <span className={c.status === "active" ? undefined : c.status === "pending" ? "muted" : "error"}>{c.status}</span>
                  {c.status_detail ? <div className="muted">{c.status_detail}</div> : null}
                </td>
                <td>
                  {c.sharing === "team" ? "Team" : "Only you"}
                  {c.scopes_granted.length > 0 ? <div className="muted mono">{c.scopes_granted.join(" ")}</div> : null}
                </td>
                <td>
                  {c.status === "revoked" ? null : (
                    <button className="danger" onClick={() => void revoke(c)}>
                      Disconnect
                    </button>
                  )}
                </td>
              </tr>
            ))}
            {list.data && list.data.connections.length === 0 ? (
              <tr>
                <td colSpan={4} className="muted">
                  No connections yet.
                </td>
              </tr>
            ) : null}
          </tbody>
        </table>
        {list.loading ? <p className="muted">Loading</p> : null}
      </div>
    </>
  )
}
