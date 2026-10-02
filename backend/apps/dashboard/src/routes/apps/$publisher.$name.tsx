import { createFileRoute, Link } from "@tanstack/react-router"
import { useState } from "react"
import { appsMutate, appsRead, describeError, type Listing } from "../../lib/apps"
import { formatDate, TierBadge } from "../../lib/apps-ui"
import { useLoad } from "../../lib/hooks"
import { newKey } from "../../lib/session"

export const Route = createFileRoute("/apps/$publisher/$name")({ component: AppListing })

function AppListing() {
  const { publisher, name } = Route.useParams()
  const id = `${publisher}/${name}`
  const [optional, setOptional] = useState<Record<string, boolean>>({})
  const [status, setStatus] = useState<{ error?: string; done?: string } | null>(null)
  const info = useLoad(`info:${id}`, async () => {
    const r = await appsRead({ data: { op: "app.info", params: { app: id } } })
    if (r.status === 401) throw new Error("signed out")
    if (r.status !== 200) throw new Error(describeError(r as never))
    return r.body.value as unknown as Listing
  })
  const app = info.data
  const latest = app?.versions?.find((v) => v.version === app.latest_version)

  const install = async () => {
    if (!app || !latest) return
    if (app.tier === "unverified" && !window.confirm(`${app.name} is unverified: cmux has not reviewed it and its bundle is not attested. Install it anyway?`)) return
    setStatus(null)
    const scopes = [...Object.keys(latest.scopes), ...Object.keys(latest.optional_scopes).filter((s) => optional[s])]
    const r = await appsMutate({
      data: { op: "app.install", params: { app: app.id, scopes, ...(app.tier === "unverified" ? { accept_unverified: true } : {}) }, idempotency_key: newKey() }
    })
    if (!r.body.ok) return setStatus({ error: describeError(r) })
    const v = r.body.value as unknown as { status: string; install?: { version: string } }
    setStatus({ done: v.status === "installed" ? `Installed ${v.install?.version}. The cmux app picks it up from your account.` : "Waiting for approval." })
  }

  return (
    <div className="apps">
      <p>
        <Link to="/apps">Apps</Link>
      </p>
      {info.error === "Error: signed out" ? (
        <p>
          <Link to="/">Sign in</Link> to see this app.
        </p>
      ) : info.error ? (
        <p className="error">{info.error}</p>
      ) : null}
      {app ? (
        <>
          <h2 style={{ marginBottom: 4 }}>
            {app.name} <TierBadge tier={app.tier} />
          </h2>
          <div className="muted mono">
            {app.id} · {app.publisher.name}
            {app.publisher.verified ? " (verified publisher)" : ""} · {app.install_count} installs ·{" "}
            {app.repository.startsWith("https://github.com/") ? (
              <a href={app.repository} rel="noreferrer">
                repository
              </a>
            ) : null}
          </div>
          <p>{app.description}</p>
          <div className="card">
            <strong>Permissions{latest ? ` (v${latest.version})` : ""}</strong>
            {latest ? (
              <table>
                <tbody>
                  {Object.entries(latest.scopes).map(([scope, reason]) => (
                    <tr key={scope}>
                      <td className="mono">{scope}</td>
                      <td>{reason}</td>
                      <td className="muted">required</td>
                    </tr>
                  ))}
                  {Object.entries(latest.optional_scopes).map(([scope, reason]) => (
                    <tr key={scope}>
                      <td className="mono">{scope}</td>
                      <td>{reason}</td>
                      <td>
                        <label>
                          <input type="checkbox" checked={optional[scope] ?? false} onChange={(e) => setOptional({ ...optional, [scope]: e.target.checked })} /> allow
                        </label>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            ) : (
              <p className="muted">No installable version.</p>
            )}
            <div style={{ marginTop: 10, display: "flex", gap: 12, alignItems: "center" }}>
              <button disabled={!latest} onClick={() => void install()}>
                Install
              </button>
              {status?.error ? <span className="error">{status.error}</span> : null}
              {status?.done ? <span>{status.done}</span> : null}
            </div>
          </div>
          <div className="card">
            <strong>Versions</strong>
            <table>
              <thead>
                <tr>
                  <th>Version</th>
                  <th>Published</th>
                  <th>cmux</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {(app.versions ?? []).map((v) => (
                  <tr key={v.version}>
                    <td className="mono">{v.version}</td>
                    <td>{formatDate(v.published_at)}</td>
                    <td className="mono">{v.engines.cmux}</td>
                    <td>{v.yanked ? <span className="error">Yanked: {v.yank_reason}</span> : null}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      ) : null}
      {info.loading ? <p className="muted">Loading</p> : null}
    </div>
  )
}
