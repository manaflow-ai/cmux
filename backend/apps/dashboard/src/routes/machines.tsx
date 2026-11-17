import { createFileRoute, Link } from "@tanstack/react-router"
import { useRef, useState } from "react"
import { useLocale } from "../lib/approval-strings"
import { useLoad } from "../lib/hooks"
import { canStart, isTransition, keepsKey, listErrorCode, loadMachines, MachinesError, startMachine, type MachineList, type MachineRow, type StartOutcome } from "../lib/machines"
import { machinesErrorText, machinesText, pauseReasonText, statusText } from "../lib/machines-strings"
import { newKey, setSignedIn, useSignedIn } from "../lib/session"
import { useTeamApi } from "../lib/team-api"

export const Route = createFileRoute("/machines")({ component: Machines })

/** One page per team: a team switch starts fresh, so no row, notice or error of the last team stays clickable. */
function Machines() {
  const { team } = useTeamApi()
  return <MachinesPage key={team ?? "personal"} />
}

/**
 * The team's Cloud machines, with Start on a paused one (#44784): a person wakes a machine from a
 * browser or a phone's browser, without the Mac app. Lists with `cloud.machine.list` and starts
 * with `cloud.machine.start` in the team in the URL, the ops the Mac and the iPhone call.
 */
function MachinesPage() {
  const signedIn = useSignedIn()
  const locale = useLocale()
  const { read, mutate, team } = useTeamApi()
  const [busy, setBusy] = useState<string | null>(null)
  const [failure, setFailure] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  // A start whose outcome is unknown keeps its idempotency key, so pressing Start again retries it.
  const keys = useRef(new Map<string, string>())

  const list = useLoad<MachineList>(signedIn ? `machines:${team ?? "personal"}` : null, async () => {
    try {
      return await loadMachines(async (op, params) => {
        const r = await read({ data: { op, params } })
        return { status: r.status, body: r.body }
      })
    } catch (e) {
      if (e instanceof MachinesError && e.status === 401) setSignedIn(false)
      throw new Error(e instanceof MachinesError ? machinesErrorText(locale, listErrorCode(e.code)) : String(e))
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
    if (!canStart(machine) || busy || list.loading) return
    setBusy(machine.id)
    setFailure(null)
    setNotice(null)
    const key = keys.current.get(machine.id) ?? newKey()
    keys.current.set(machine.id, key)
    let outcome: StartOutcome | "unreachable"
    try {
      outcome = await startMachine(
        async (op, params, idempotencyKey) => {
          const r = await mutate({ data: { op, params, idempotency_key: idempotencyKey } })
          return { status: r.status, body: r.body }
        },
        machine,
        key
      )
    } catch {
      outcome = "unreachable"
    }
    if (!keepsKey(outcome)) keys.current.delete(machine.id)
    if (outcome === "unreachable") setFailure(machinesErrorText(locale, "owner.unreachable"))
    else if (outcome.ok) setNotice(machinesText(locale, "started", { name: machine.name ?? machine.id }))
    else {
      if (outcome.status === 401) setSignedIn(false)
      setFailure(machinesErrorText(locale, outcome.code))
    }
    setBusy(null)
    list.reload()
  }

  const rows = list.data?.rows ?? []
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
                    <button disabled={busy !== null || list.loading} aria-busy={busy === m.id} onClick={() => void start(m)}>
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
      {list.data?.incomplete ? <p className="muted">{machinesText(locale, "page.incomplete")}</p> : null}
      {rows.some(isTransition) ? <p className="muted">{machinesText(locale, "page.changing")}</p> : null}
      <button onClick={refresh} disabled={list.loading}>
        {machinesText(locale, "page.refresh")}
      </button>
    </>
  )
}
