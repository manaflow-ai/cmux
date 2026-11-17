import { createFileRoute, Link } from "@tanstack/react-router"
import { useState } from "react"
import { useLocale } from "../lib/approval-strings"
import { useLoad } from "../lib/hooks"
import { canStart, isTransition, loadMachines, MachinesError, startMachine, type MachineRow } from "../lib/machines"
import { machinesErrorText, machinesText, pauseReasonText, statusText } from "../lib/machines-strings"
import { newKey, setSignedIn, useSignedIn } from "../lib/session"
import { useTeamApi } from "../lib/team-api"

export const Route = createFileRoute("/machines")({ component: Machines })

/**
 * The team's Cloud machines, with Start on a paused one (#44784): a person wakes a machine from a
 * browser or a phone's browser, without the Mac app. Lists with `cloud.machine.list` and starts
 * with `cloud.machine.start` in the team in the URL, the ops the Mac and the iPhone call.
 */
function Machines() {
  const signedIn = useSignedIn()
  const locale = useLocale()
  const { read, mutate, team } = useTeamApi()
  const [busy, setBusy] = useState<string | null>(null)
  const [failure, setFailure] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)

  const list = useLoad<Array<MachineRow>>(signedIn ? `machines:${team ?? "personal"}` : null, async () => {
    try {
      return await loadMachines(async (op, params) => {
        const r = await read({ data: { op, params } })
        return { status: r.status, body: r.body }
      })
    } catch (e) {
      if (e instanceof MachinesError && e.status === 401) setSignedIn(false)
      throw new Error(e instanceof MachinesError ? machinesErrorText(locale, e.code) : String(e))
    }
  })

  if (signedIn === false)
    return (
      <p>
        <Link to="/">{machinesText(locale, "page.signin")}</Link>
      </p>
    )

  const refresh = () => {
    setFailure(null)
    setNotice(null)
    list.reload()
  }

  const start = async (machine: MachineRow) => {
    if (!canStart(machine) || busy) return
    setBusy(machine.id)
    setFailure(null)
    setNotice(null)
    try {
      const outcome = await startMachine(
        async (op, params, key) => {
          const r = await mutate({ data: { op, params, idempotency_key: key } })
          return { status: r.status, body: r.body }
        },
        machine,
        newKey()
      )
      if (outcome.ok) setNotice(machinesText(locale, "started", { name: machine.name ?? machine.id }))
      else {
        if (outcome.status === 401) setSignedIn(false)
        setFailure(machinesErrorText(locale, outcome.code))
      }
    } catch {
      setFailure(machinesErrorText(locale, "owner.unreachable"))
    } finally {
      setBusy(null)
    }
    list.reload()
  }

  const rows = list.data ?? []
  return (
    <>
      <h2>{machinesText(locale, "page.title")}</h2>
      <p className="muted">{machinesText(locale, "page.intro")}</p>
      {list.error ? <p className="error">{list.error}</p> : null}
      {failure ? (
        <p className="error" role="alert">
          {failure}
        </p>
      ) : null}
      {notice ? (
        <p className="muted" role="status">
          {notice}
        </p>
      ) : null}
      <div className="card">
        <table>
          <thead>
            <tr>
              <th>{machinesText(locale, "column.machine")}</th>
              <th>{machinesText(locale, "column.status")}</th>
              <th />
            </tr>
          </thead>
          <tbody>
            {rows.map((m) => (
              <tr key={m.id}>
                <td>
                  {m.name ?? m.id}
                  <br />
                  <code className="muted">{m.id}</code>
                </td>
                <td>
                  {statusText(locale, m.status)}
                  {m.status === "paused" && m.pauseReason ? <div className="muted">{pauseReasonText(locale, m.pauseReason)}</div> : null}
                  {(m.status === "failed" || m.status === "paused") && m.error ? <div className="muted">{m.error}</div> : null}
                </td>
                <td style={{ whiteSpace: "nowrap" }}>
                  {canStart(m) ? (
                    <button disabled={busy !== null} aria-busy={busy === m.id} onClick={() => void start(m)}>
                      {machinesText(locale, busy === m.id ? "action.starting" : "action.start")}
                    </button>
                  ) : null}
                </td>
              </tr>
            ))}
            {list.data && rows.length === 0 ? (
              <tr>
                <td colSpan={3} className="muted">
                  {machinesText(locale, "page.empty")}
                </td>
              </tr>
            ) : null}
          </tbody>
        </table>
        {list.loading ? <p className="muted">{machinesText(locale, "page.loading")}</p> : null}
      </div>
      {rows.some(isTransition) ? <p className="muted">{machinesText(locale, "page.changing")}</p> : null}
      <button onClick={refresh} disabled={list.loading}>
        {machinesText(locale, "page.refresh")}
      </button>
    </>
  )
}
