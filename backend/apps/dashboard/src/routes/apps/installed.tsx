import { createFileRoute, Link } from "@tanstack/react-router"
import { useState } from "react"
import { appsMutate, appsRead, describeError, type Approval, type InstallsView } from "../../lib/apps"
import { appPath, formatDate, TierBadge } from "../../lib/apps-ui"
import { useLoad } from "../../lib/hooks"
import { newKey } from "../../lib/session"

export const Route = createFileRoute("/apps/installed")({ component: InstalledApps })

function InstalledApps() {
  const [error, setError] = useState<string | null>(null)
  const list = useLoad("installed", async () => {
    const r = await appsRead({ data: { op: "app.list", params: { scope: "all" } } })
    if (r.status === 401) throw new Error("signed out")
    if (r.status !== 200) throw new Error(describeError(r as never))
    return r.body.value as unknown as InstallsView
  })
  const act = async (op: string, params: Record<string, unknown>) => {
    setError(null)
    const r = await appsMutate({ data: { op, params, idempotency_key: newKey() } })
    if (!r.body.ok) setError(describeError(r))
    list.reload()
  }
  const decide = (a: Approval, decision: "approve" | "deny") => act("app.approval.decide", { approval: a.id, decision, scope: a.scope })

  return (
    <div className="apps">
      <div style={{ display: "flex", alignItems: "baseline", gap: 12 }}>
        <h2 style={{ marginRight: "auto" }}>Installed apps</h2>
        <Link to="/apps">Browse</Link>
      </div>
      {list.error === "Error: signed out" ? (
        <p>
          <Link to="/">Sign in</Link> to see your apps.
        </p>
      ) : list.error ? (
        <p className="error">{list.error}</p>
      ) : null}
      {error ? <p className="error">{error}</p> : null}
      {(list.data?.approvals ?? []).length > 0 ? (
        <div className="card">
          <strong>Waiting for your approval</strong>
          <table>
            <tbody>
              {list.data!.approvals.map((a) => (
                <tr key={a.id}>
                  <td>
                    An agent ({a.requested_by.origin}) asks to {a.kind === "install" ? "install" : "update"} <span className="mono">{a.app}</span> {a.version}
                    {a.scope === "team" ? " for the team" : ""}
                    <div className="muted mono">new permissions: {a.added.join(", ") || "none"}</div>
                  </td>
                  <td style={{ whiteSpace: "nowrap" }}>
                    <button onClick={() => void decide(a, "approve")}>Approve</button> <button onClick={() => void decide(a, "deny")}>Deny</button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : null}
      <div className="card">
        <table>
          <thead>
            <tr>
              <th>App</th>
              <th>Version</th>
              <th>Permissions</th>
              <th />
            </tr>
          </thead>
          <tbody>
            {(list.data?.installs ?? []).map((i) => (
              <tr key={`${i.scope}:${i.app}`}>
                <td>
                  <Link to="/apps/$publisher/$name" params={appPath(i.app)}>
                    {i.app}
                  </Link>{" "}
                  <TierBadge tier={i.tier} />
                  <div className="muted">
                    {i.scope === "team" ? "Team" : "Only you"} · {i.by_default ? "installed for everyone" : `since ${formatDate(i.installed_at)}`}
                    {i.hidden ? " · hidden" : ""}
                  </div>
                </td>
                <td className="mono">{i.version}</td>
                <td className="mono muted">{i.scopes_granted.join(" ")}</td>
                <td style={{ whiteSpace: "nowrap" }}>
                  {i.scope === "user" ? (
                    <button title="Hidden apps keep running; their sidebar, palette and menu entries go away." onClick={() => void act(i.hidden ? "app.unhide" : "app.hide", { app: i.app })}>
                      {i.hidden ? "Show" : "Hide"}
                    </button>
                  ) : null}{" "}
                  <button className="danger" onClick={() => void act("app.remove", { app: i.app, scope: i.scope })}>
                    Remove
                  </button>
                </td>
              </tr>
            ))}
            {list.data && list.data.installs.length === 0 ? (
              <tr>
                <td colSpan={4} className="muted">
                  No apps installed.
                </td>
              </tr>
            ) : null}
          </tbody>
        </table>
        {list.loading ? <p className="muted">Loading</p> : null}
      </div>
    </div>
  )
}
