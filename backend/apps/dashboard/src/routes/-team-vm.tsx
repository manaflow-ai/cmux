import { useReducer } from "react"
import { useLocale } from "../lib/approval-strings"
import { useLoad } from "../lib/hooks"
import { exportTeamFiles, mutate, read } from "../lib/server"
import { newKey, setSignedIn } from "../lib/session"
import { exportRequest, initialCardState, reduceCard, teamVmRequest, type TeamRole, type TeamVmView } from "../lib/team-vm"
import { TeamVmCard } from "../lib/team-vm-card"
import { teamVmText } from "../lib/team-vm-strings"

/** The team VM card on the Team page: reads team_vm.status and sends the owner/admin ops (cx-hnj9). */
export function TeamVmSection({ role, team }: { readonly role: TeamRole | null; readonly team: string }) {
  const locale = useLocale()
  const [state, dispatch] = useReducer(reduceCard, initialCardState)
  const status = useLoad<TeamVmView>(`team-vm:${team}`, async () => {
    const r = await read({ data: { op: "team_vm.status", params: {} } })
    if (r.status === 401) setSignedIn(false)
    if (r.status !== 200) throw new Error(`team_vm.status ${r.status}`)
    return r.body.value as unknown as TeamVmView
  })

  const confirm = async () => {
    const view = status.data
    const request = view ? teamVmRequest(view, state.dialog) : null
    if (!request) return
    dispatch({ t: "sent" })
    try {
      const r = await mutate({ data: { op: request.op, params: request.params, idempotency_key: newKey() } })
      if (r.status === 401) setSignedIn(false)
      dispatch({ t: "done", error: r.body.ok ? null : { code: r.body.error?.code ?? `http.${r.status}`, message: r.body.error?.message ?? "" } })
    } catch (e) {
      dispatch({ t: "done", error: { code: "unknown", message: e instanceof Error ? e.message : String(e) } })
    }
    status.reload()
  }

  /** Export, then open the single-use URL: the API answers the tar as an attachment, so the page stays. */
  const download = async (vm: string) => {
    const view = status.data
    if (!view || !exportRequest(view, vm)) return
    dispatch({ t: "download", vm })
    try {
      const r = await exportTeamFiles({ data: { vm, idempotency_key: newKey() } })
      if (r.status === 401) setSignedIn(false)
      if (!r.url) {
        dispatch({ t: "download_done", vm, error: { code: r.body.error?.code ?? `http.${r.status}`, message: r.body.error?.message ?? "" }, skipped: 0 })
        return
      }
      const link = document.createElement("a")
      link.href = r.url
      link.rel = "noopener"
      document.body.append(link)
      link.click()
      link.remove()
      const value = r.body.value as { skipped_count?: unknown } | undefined
      dispatch({ t: "download_done", vm, error: null, skipped: typeof value?.skipped_count === "number" ? value.skipped_count : 0 })
    } catch (e) {
      dispatch({ t: "download_done", vm, error: { code: "unknown", message: e instanceof Error ? e.message : String(e) }, skipped: 0 })
    }
  }

  return (
    <>
      {status.error ? <p className="error">{teamVmText(locale, "card.error.load", { error: status.error })}</p> : null}
      {status.data ? (
        <TeamVmCard
          view={status.data}
          role={role}
          locale={locale}
          state={state}
          onOpen={(kind, vm) => dispatch({ t: "open", kind, vm })}
          onCancel={() => dispatch({ t: "cancel" })}
          onFilesCopied={(value) => dispatch({ t: "files_copied", value })}
          onConfirm={() => void confirm()}
          onDownload={(vm) => void download(vm)}
        />
      ) : status.loading ? (
        <p className="muted">{teamVmText(locale, "card.loading")}</p>
      ) : null}
    </>
  )
}
