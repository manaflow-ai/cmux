import { createFileRoute, Link } from "@tanstack/react-router"
import { useState } from "react"
import { useLoad, useWire } from "../lib/hooks"
import { mutate, read, type OpResponse } from "../lib/server"
import { newKey, setSignedIn, useSignedIn } from "../lib/session"

export const Route = createFileRoute("/devices")({ component: Devices })

interface Install {
  id: string
  name: string
  kind: string
  platform: string
  device_name: string
  created_at: number
  revoked_at: number | null
}
interface Listing {
  user: { id: string; email: string | null; display_name: string } | null
  installs: Array<Install>
}

function Echo({ r }: { r: OpResponse | null }) {
  if (!r) return null
  return (
    <div className="card mono">
      {r.ok ? "ok" : <span className="error">rejected: {r.error?.code} {r.error?.message}</span>} · op {r.op} · transaction {r.transaction} · stream{" "}
      {r.stream} · sequence {r.sequence}
      {r.revision ? ` · revision ${r.revision}` : ""}
      {r.replayed ? " · replayed" : ""}
    </div>
  )
}

function Devices() {
  const signedIn = useSignedIn()
  const [last, setLast] = useState<OpResponse | null>(null)
  const [ensured, setEnsured] = useState<OpResponse | null>(null)

  const list = useLoad<Listing>(signedIn ? "devices" : null, async () => {
    // The user record and personal team exist before anything else (user.ensure is idempotent).
    const e = await mutate({ data: { op: "user.ensure", params: {}, idempotency_key: newKey() } })
    if (e.status === 401) setSignedIn(false)
    if (e.status !== 200) throw new Error(`user.ensure failed: ${e.status} ${JSON.stringify(e.body)}`)
    setEnsured(e.body)
    const r = await read({ data: { op: "install.list", params: {} } })
    if (r.status !== 200) throw new Error(`install.list failed: ${r.status}`)
    return r.body.value as unknown as Listing
  })
  const userId = list.data?.user?.id ?? null
  const wire = useWire(userId ? `user:${userId}` : null)

  if (signedIn === false)
    return (
      <p>
        <Link to="/">Sign in</Link> to see your devices.
      </p>
    )

  const run = async (op: string, params: Record<string, unknown>) => {
    const r = await mutate({ data: { op, params, idempotency_key: newKey() } })
    if (r.status === 401) return setSignedIn(false)
    if (r.status === 200) setLast(r.body)
    list.reload()
  }

  return (
    <>
      <h2>Devices</h2>
      {list.data?.user ? (
        <p className="muted">
          {list.data.user.display_name} · {list.data.user.email} · <code>{list.data.user.id}</code>
        </p>
      ) : null}
      {list.error ? <p className="error">{list.error}</p> : null}
      <div className="card">
        <table>
          <thead>
            <tr>
              <th>Install</th>
              <th>Kind</th>
              <th>Device</th>
              <th>Created</th>
              <th>Status</th>
              <th />
            </tr>
          </thead>
          <tbody>
            {(list.data?.installs ?? []).map((i) => (
              <tr key={i.id}>
                <td>
                  {i.name}
                  <br />
                  <code className="muted">{i.id}</code>
                </td>
                <td>
                  {i.kind} · {i.platform}
                </td>
                <td>{i.device_name}</td>
                <td>{new Date(i.created_at).toLocaleString()}</td>
                <td>{i.revoked_at ? <span className="error">revoked</span> : "active"}</td>
                <td style={{ whiteSpace: "nowrap" }}>
                  {i.revoked_at ? null : (
                    <>
                      <button
                        onClick={() => {
                          const name = window.prompt("New name", i.name)
                          if (name) void run("install.rename", { install: i.id, name })
                        }}
                      >
                        Rename
                      </button>{" "}
                      <button className="danger" onClick={() => window.confirm(`Revoke ${i.name}?`) && void run("install.revoke", { install: i.id })}>
                        Revoke
                      </button>
                    </>
                  )}
                </td>
              </tr>
            ))}
            {list.data && list.data.installs.length === 0 ? (
              <tr>
                <td colSpan={6} className="muted">
                  No installs yet. Register one with the CLI (device flow) or the API.
                </td>
              </tr>
            ) : null}
          </tbody>
        </table>
        {list.loading ? <p className="muted">Loading</p> : null}
      </div>
      <h3>Last mutation</h3>
      <Echo r={last ?? ensured} />
      <h3>Live stream ({wire.status})</h3>
      <div className="card mono">
        {wire.frames.length === 0 ? <span className="muted">No frames yet.</span> : null}
        {wire.frames.map((f, n) => (
          <div key={n}>
            {f.t}
            {f.op ? ` ${f.op}` : ""}
            {f.seq !== undefined ? ` seq ${f.seq}` : ""}
            {f.tx ? ` tx ${f.tx}` : ""}
          </div>
        ))}
      </div>
    </>
  )
}
