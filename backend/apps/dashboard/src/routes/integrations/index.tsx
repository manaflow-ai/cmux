import { createFileRoute, Link } from "@tanstack/react-router"
import { useState } from "react"
import { useLoad } from "../../lib/hooks"
import { mutate, read } from "../../lib/server"
import { newKey, setSignedIn, useSignedIn } from "../../lib/session"
import { IntegrationApprovals } from "./-approvals"

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
interface Policy {
  allowed_providers: Array<string> | null
  github: { scope: "linking_user_repos" | "installation"; require_org_admin: boolean; repo_allowlist: Array<string> | null }
  source: string
  locked: boolean
}
interface Listing {
  connections: Array<Connection>
  providers: Array<{ provider: Connection["provider"]; configured: boolean }>
}

const LABEL: Record<Connection["provider"], string> = { github: "GitHub App", linear: "Linear", slack: "Slack bot" }

function Integrations() {
  const signedIn = useSignedIn()
  const [error, setError] = useState<string | null>(null)
  const list = useLoad<Listing & { policy: Policy | null }>(signedIn ? "integrations" : null, async () => {
    const e = await mutate({ data: { op: "user.ensure", params: {}, idempotency_key: newKey() } })
    if (e.status === 401) setSignedIn(false)
    const [r, p] = await Promise.all([read({ data: { op: "integration.list", params: {} } }), read({ data: { op: "integration.policy.get", params: {} } })])
    if (r.status !== 200) throw new Error(`integration.list failed: ${r.status}`)
    return { ...(r.body.value as unknown as Listing), policy: p.status === 200 ? (p.body.value as unknown as Policy) : null }
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

  const setPolicy = async (github: Partial<Policy["github"]>) => {
    const r = await mutate({ data: { op: "integration.policy.set", params: { github }, idempotency_key: newKey() } })
    if (!r.body.ok) setError(`${r.body.error?.code}: ${r.body.error?.message}`)
    list.reload()
  }
  const policy = list.data?.policy

  return (
    <>
      <h2>Integrations</h2>
      <p className="muted">Provider tokens stay on the server, encrypted. Agents and automations use them only through cmux operations.</p>
      {list.error ? <p className="error">{list.error}</p> : null}
      {error ? <p className="error">{error}</p> : null}
      {signedIn ? <IntegrationApprovals /> : null}
      <div className="card" style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
        {(list.data?.providers ?? []).map((p) => (
          <button key={p.provider} disabled={!p.configured} title={p.configured ? undefined : "Not configured on this deployment"} onClick={() => void connect(p.provider)}>
            Connect {LABEL[p.provider]}
            {p.configured ? "" : " (not configured)"}
          </button>
        ))}
      </div>
      {policy ? (
        <div className="card">
          <strong>GitHub policy</strong> <span className="muted">({policy.locked ? `managed by ${policy.source}` : policy.source})</span>
          <div style={{ display: "flex", gap: 12, flexWrap: "wrap", alignItems: "center", marginTop: 8 }}>
            <select disabled={policy.locked} value={policy.github.scope} onChange={(e) => void setPolicy({ scope: e.target.value as Policy["github"]["scope"] })}>
              <option value="linking_user_repos">Repositories the linking person can access</option>
              <option value="installation">Every repository in the installation</option>
            </select>
            <label>
              <input type="checkbox" disabled={policy.locked} checked={policy.github.require_org_admin} onChange={(e) => void setPolicy({ require_org_admin: e.target.checked })} /> Only organization admins may link
            </label>
            <input
              disabled={policy.locked}
              className="mono"
              style={{ minWidth: 260 }}
              placeholder="Allowed repositories: owner/repo, owner/*"
              defaultValue={policy.github.repo_allowlist?.join(", ") ?? ""}
              onBlur={(e) => {
                const v = e.target.value.split(",").map((x) => x.trim()).filter(Boolean)
                void setPolicy({ repo_allowlist: v.length > 0 ? v : null })
              }}
            />
          </div>
        </div>
      ) : null}
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
                  <span className={c.status === "active" ? undefined : c.status === "pending" || c.status === "expired" ? "muted" : "error"}>{c.status}</span>
                  {c.status_detail ? <div className="muted">{c.status_detail}</div> : null}
                </td>
                <td>
                  {c.sharing === "team" ? "Team" : "Only you"}
                  {c.scopes_granted.length > 0 ? <div className="muted mono">{c.scopes_granted.join(" ")}</div> : null}
                </td>
                <td>
                  {c.status === "revoked" || c.status === "expired" ? null : (
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
