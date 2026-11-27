import { DriverError } from "./team-vm-driver.ts"
import { EXPORT_LIMITS, exportRefusal, exportResponse, planExport, type ExportTickets } from "./team-vm-export.ts"
import type { AdminReply, TaintRunDeps } from "./team-vm-taint-run.ts"

/** TeamVmDO's side of team_vm.retired.export (team-vm-export.ts): the op after TeamDO's owner/admin check, and the download. */
export type ExportRunDeps = TaintRunDeps & { readonly exportTickets: () => ExportTickets }

/** The download path of a ticket; the dashboard puts the API origin in front. */
export const exportPath = (team: string, ticket: string) => `/v1/team-vm/export/${team}/${ticket}`

const provider = (d: TaintRunDeps): { ok: true; driver: NonNullable<ReturnType<TaintRunDeps["driver"]>> } | { ok: false; code: string; message: string } => {
  const refused = d.refusal()
  const driver = refused ? null : d.driver()
  return driver ? { ok: true, driver } : { ok: false, code: refused ?? "team_vm.not_configured", message: "no team VM provider is available on this deployment" }
}

export const exportRetired = async (d: ExportRunDeps, req: { readonly vm: string; readonly by: string }): Promise<AdminReply> => {
  const s = d.state()
  if (!s?.team) return { ok: false, code: "owner.unreachable", message: "team VM record not open" }
  const row = (s.retired ?? []).find((r) => r.vm === req.vm)
  const refused = exportRefusal(row)
  if (refused) return refused
  const p = provider(d)
  if (!p.ok) return p
  let plan: Awaited<ReturnType<typeof planExport>>
  try {
    plan = await planExport(p.driver, row!.vm)
  } catch (e) {
    if (e instanceof DriverError) return { ok: false, code: e.code, message: e.message }
    throw e
  }
  if (!plan.ok) return plan
  const now = Date.now()
  const expiresAt = now + EXPORT_LIMITS.ticketMs
  const { ticket, total } = await d.exportTickets().mint(row!.vm, req.by, plan.entries, expiresAt, now)
  const value = { vm: row!.vm, path: exportPath(s.team, ticket), expires_at: expiresAt, files: plan.files, bytes: plan.bytes, archive_bytes: total, skipped: plan.skipped.slice(0, 50), skipped_count: plan.skipped.length }
  return { ok: true, value, tainted_by: row!.tainted_by, epoch: row!.epoch }
}

const refusal = (status: number, code: string, message: string) => Response.json({ ok: false, error: { code, message } }, { status, headers: { "cache-control": "private, no-store" } })

/** The download of one ticket: the ticket ends here; the VM must still be a fenced retired VM of this team. */
export const downloadExport = async (d: ExportRunDeps, ticket: string): Promise<Response> => {
  const taken = await d.exportTickets().take(ticket, Date.now())
  if (!taken) return refusal(404, "team_vm.export_ticket_invalid", "this download link expired or was used; start the download again")
  const refused = exportRefusal((d.state()?.retired ?? []).find((r) => r.vm === taken.vm))
  if (refused) return refusal(409, refused.code, refused.message)
  const p = provider(d)
  if (!p.ok) return refusal(503, p.code, p.message)
  return exportResponse(p.driver, taken.vm, taken.entries, taken.total)
}

/** The answer for a ticket of a team without a VM record. */
export const exportUnknown = () => refusal(404, "team_vm.export_ticket_invalid", "this download link expired or was used; start the download again")
