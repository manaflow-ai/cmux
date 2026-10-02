import { createFileRoute, Link } from "@tanstack/react-router"
import { useState } from "react"
import { appsRead, describeError, type Listing, type Tier } from "../../lib/apps"
import { appPath, TierBadge } from "../../lib/apps-ui"
import { useLoad } from "../../lib/hooks"

export const Route = createFileRoute("/apps/")({ component: AppStore })

function AppStore() {
  const [query, setQuery] = useState("")
  const [submitted, setSubmitted] = useState("")
  const [tier, setTier] = useState<Tier | "">("")
  const key = `search:${submitted}:${tier}`
  const list = useLoad(key, async () => {
    const r = await appsRead({ data: { op: "app.search", params: { ...(submitted ? { query: submitted } : {}), ...(tier ? { tier } : {}), limit: 50 } } })
    if (r.status === 401) throw new Error("signed out")
    if (r.status !== 200) throw new Error(describeError(r as never))
    return r.body.value as unknown as { apps: Array<Listing> }
  })
  return (
    <div className="apps">
      <div style={{ display: "flex", alignItems: "baseline", gap: 12 }}>
        <h2 style={{ marginRight: "auto" }}>Apps</h2>
        <Link to="/apps/installed">Installed</Link>
      </div>
      <form
        className="card"
        style={{ display: "flex", gap: 8, flexWrap: "wrap" }}
        onSubmit={(e) => {
          e.preventDefault()
          setSubmitted(query.trim())
        }}
      >
        <input style={{ flex: 1, minWidth: 200 }} placeholder="Search apps" value={query} onChange={(e) => setQuery(e.target.value)} />
        <select value={tier} onChange={(e) => setTier(e.target.value as Tier | "")}>
          <option value="">All tiers</option>
          <option value="first-party">first-party (cmux)</option>
          <option value="verified">Verified</option>
        </select>
        <button type="submit">Search</button>
      </form>
      {list.error === "Error: signed out" ? (
        <p>
          <Link to="/">Sign in</Link> to browse apps.
        </p>
      ) : list.error ? (
        <p className="error">{list.error}</p>
      ) : null}
      <div className="card">
        <table>
          <tbody>
            {(list.data?.apps ?? []).map((a) => (
              <tr key={a.id}>
                <td>
                  <Link to="/apps/$publisher/$name" params={appPath(a.id)}>
                    <strong>{a.name}</strong>
                  </Link>{" "}
                  <TierBadge tier={a.tier} />
                  <div>{a.description}</div>
                  <div className="muted mono">
                    {a.id} · {a.publisher.name} · v{a.latest_version} · {a.install_count} installs
                  </div>
                </td>
              </tr>
            ))}
            {list.data && list.data.apps.length === 0 ? (
              <tr>
                <td className="muted">No apps match.</td>
              </tr>
            ) : null}
          </tbody>
        </table>
        {list.loading ? <p className="muted">Loading</p> : null}
      </div>
    </div>
  )
}
