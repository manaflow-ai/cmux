import type { ReduceContext, ReduceResult, RowReader, RowWrite } from "@cmux/ownership"
import { CloudVmStatusParams, CloudVmStatusReport } from "@cmux/protocol"
import { Exit, Schema } from "effect"
import { reject } from "./common.ts"
import { TABLE_MACHINE, type CloudState, type MachineRow } from "./cloud.ts"

type Report = typeof CloudVmStatusReport.params.Type

/**
 * `cloud.machine.vm_status` (internal): CloudDO applies the VM's latest coalesced status report.
 * State, health and activity are private (activity feeds the idle pause); the daemon version and
 * capabilities are public, so only a daemon change emits cloud.machine.upsert.
 */
export const applyVmStatus = (state: CloudState, params: unknown, ctx: ReduceContext, next: (s: CloudState, patch: Partial<CloudState>, changed: CloudState["changed"]) => CloudState): ReduceResult<CloudState> => {
  const outer = Schema.decodeUnknownExit(CloudVmStatusParams as Schema.Codec<typeof CloudVmStatusParams.Type, unknown>)(params ?? {})
  if (!Exit.isSuccess(outer)) return reject("validation.invalid", "invalid vm status")
  const inner = Schema.decodeUnknownExit(CloudVmStatusReport.params as Schema.Codec<Report, unknown>)(outer.value.report)
  if (!Exit.isSuccess(inner)) return reject("validation.invalid", "invalid vm status report")
  const r = inner.value
  const stored = (ctx.rows as RowReader | undefined)?.get<MachineRow>(TABLE_MACHINE, outer.value.machine)
  if (!stored?.row) return reject("cloud.machine.not_found", "no such machine")
  const m = stored.row
  // A report held from an install the machine no longer names (a re-bind in between) never applies (review P3).
  const from = (outer.value.report as { install?: unknown } | null)?.install
  if (typeof from === "string" && m.vm_install !== from) return { ok: true, state, value: { applied: false }, changed: false }
  const daemonChanged = m.daemon?.version !== r.daemon.version || JSON.stringify(m.daemon?.capabilities ?? []) !== JSON.stringify(r.daemon.capabilities)
  const rev = daemonChanged ? state.rev + 1 : state.rev
  const row: MachineRow = {
    ...m,
    daemon: { version: r.daemon.version, capabilities: [...r.daemon.capabilities] },
    image: { ...m.image, daemon_version: r.daemon.version },
    vm_status: { state: r.state, ...(r.health ? { health: r.health } : {}), activity: r.activity, at: outer.value.now },
    ...(daemonChanged ? { revision: String(rev) } : {})
  }
  const writes: Array<RowWrite> = [{ table: TABLE_MACHINE, op: "upsert", key: row.id, n: stored.n, row }]
  if (!daemonChanged) return { ok: true, state, value: { applied: true }, writes, changed: false }
  return { ok: true, state: next(state, {}, { machine: row.id, removed: false }), value: { applied: true }, writes }
}
