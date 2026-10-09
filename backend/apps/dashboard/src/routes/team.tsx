import { createFileRoute, Link } from "@tanstack/react-router"
import { useLoad } from "../lib/hooks"
import { mutate, read } from "../lib/server"
import { newKey, setSignedIn, useSignedIn } from "../lib/session"
import { roleOf } from "../lib/team-vm"
import { TeamVmSection } from "./-team-vm"

export const Route = createFileRoute("/team")({ component: Team })

interface Directory {
  team: string
  members: Array<{ user: string; role: string; display_name: string }>
  hosts: Array<{ id: string; name: string; platform: string; owner_user: string; enrolled_by: string; enrolled_at: number }>
}

function Team() {
  const signedIn = useSignedIn()
  const dir = useLoad<{ value: Directory; revision: string; me: string }>(signedIn ? "team" : null, async () => {
    // user.ensure is idempotent and names the caller, whose role decides the team VM actions.
    const e = await mutate({ data: { op: "user.ensure", params: {}, idempotency_key: newKey() } })
    if (e.status === 401) setSignedIn(false)
    if (e.status !== 200) throw new Error(`user.ensure failed: ${e.status}`)
    const me = String((e.body.value as { id?: unknown } | undefined)?.id ?? "")
    const r = await read({ data: { op: "team.directory", params: {} } })
    if (r.status === 401) setSignedIn(false)
    if (r.status !== 200) throw new Error(`team.directory failed: ${r.status} (open Devices once to create your personal team)`)
    return { value: r.body.value as unknown as Directory, revision: r.body.revision, me }
  })
  if (signedIn === false)
    return (
      <p>
        <Link to="/">Sign in</Link> to see your team.
      </p>
    )
  const d = dir.data?.value
  const role = roleOf(d?.members.find((m) => m.user === dir.data?.me)?.role)
  return (
    <>
      <h2>Team</h2>
      {dir.error ? <p className="error">{dir.error}</p> : null}
      {d ? (
        <p className="muted">
          <code>{d.team}</code> · revision {dir.data?.revision}
        </p>
      ) : null}
      {d ? <TeamVmSection team={d.team} role={role} /> : null}
      <h3>Members</h3>
      <div className="card">
        <table>
          <tbody>
            {(d?.members ?? []).map((m) => (
              <tr key={m.user}>
                <td>{m.display_name}</td>
                <td>{m.role}</td>
                <td>
                  <code className="muted">{m.user}</code>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <h3>Hosts</h3>
      <div className="card">
        <table>
          <tbody>
            {(d?.hosts ?? []).map((h) => (
              <tr key={h.id}>
                <td>
                  {h.name}
                  <br />
                  <code className="muted">{h.id}</code>
                </td>
                <td>{h.platform}</td>
                <td>{new Date(h.enrolled_at).toLocaleString()}</td>
                <td>
                  <code className="muted">{h.enrolled_by}</code>
                </td>
              </tr>
            ))}
            {d && d.hosts.length === 0 ? (
              <tr>
                <td className="muted">No hosts enrolled yet (a machine's link enrolls with host.enroll).</td>
              </tr>
            ) : null}
          </tbody>
        </table>
      </div>
      {dir.loading ? <p className="muted">Loading</p> : null}
    </>
  )
}
