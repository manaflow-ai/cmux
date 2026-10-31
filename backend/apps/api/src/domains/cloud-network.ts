import type { ReduceContext, ReduceResult } from "@cmux/ownership"
import { CloudVmNetwork } from "@cmux/protocol"
import { Schema } from "effect"
import { networkBinding } from "../cloud-network-observation.ts"
import { reject } from "./common.ts"
import { TABLE_MACHINE, type CloudState, type MachineRow } from "./cloud.ts"

/** An observation changes routing metadata, never a permission or placement. */
export const applyNetworkObservation = (state: CloudState, params: unknown, ctx: ReduceContext,
  next: (s: CloudState, patch: Partial<CloudState>, changed: CloudState["changed"]) => CloudState): ReduceResult<CloudState> => {
  if (ctx.principal.kind !== "system") return reject("auth.forbidden", "internal op")
  const p = params as { machine?: unknown; binding?: unknown; network?: unknown } | null
  if (!p || typeof p.machine !== "string" || typeof p.binding !== "string" || !Schema.is(CloudVmNetwork)(p.network)) return reject("validation.invalid", "invalid network observation")
  const stored = ctx.rows?.get<MachineRow>(TABLE_MACHINE, p.machine), m = stored?.row, n = p.network
  if (!m?.network || m.status !== "running" || networkBinding(m) !== p.binding
    || n.tenant !== m.network.tenant || n.mesh !== m.network.mesh || n.ipv4_cidr !== m.network.ipv4_cidr) return { ok: true, state, value: { applied: false }, changed: false }
  if (n.ipv4 === m.network.ipv4) return { ok: true, state, value: { applied: true }, changed: false }
  const row = { ...m, network: n, revision: String(state.rev + 1) }
  return { ok: true, state: next(state, {}, { machine: row.id, removed: false }), value: { applied: true },
    writes: [{ table: TABLE_MACHINE, op: "upsert", key: row.id, n: stored!.n, row }] }
}
