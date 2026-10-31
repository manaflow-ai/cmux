import type { Principal, RowReader, SqlStore } from "@cmux/ownership"
import { CloudVmReceiverLifecycleParams } from "@cmux/protocol"
import { Effect, Exit, Schema } from "effect"
import { vmGate, type VmReply } from "./cloud-vm.ts"
import type { MachineRow } from "./domains/cloud.ts"
import type { NetworkIdentity } from "./host-network-peers.ts"
import { boundVmReceiver, liveVmReceiver, originalVmReceiverGrant, vmReceiverScope, vmReceiverStamp } from "./cloud-vm-receiver-identity.ts"
import { VmReceiverGenerations, type ReceiverTransitionAudit } from "./cloud-vm-receiver-generations.ts"

interface Deps {
  team: string; rows: RowReader | undefined; now(): number; sql(): SqlStore;
  own(user: string, install: string, grant: string, machine: string): Promise<NetworkIdentity | null>;
  audit(entry: ReceiverTransitionAudit): void;
}
const unavailable = (): VmReply => ({ ok: false, code: "owner.unreachable", message: "receiving incarnation unavailable" })
const forbidden = (): VmReply => ({ ok: false, code: "auth.forbidden", message: "the original live VM authority is unavailable" })

/** Catalog and internal callers share the original-VM lifecycle boundary. */
export const cloudVmReceiverLifecycle = (d: Deps, p: Principal, params: unknown): Promise<VmReply> => Effect.runPromise(
  Effect.tryPromise({ try: async (signal): Promise<VmReply> => {
    const decoded = Schema.decodeUnknownExit(CloudVmReceiverLifecycleParams)(params)
    if (!Exit.isSuccess(decoded)) return { ok: false, code: "validation.invalid", message: "invalid receiving transition" }
    const r = decoded.value
    if (Object.keys(params as object).some((k) => !["machine", "phase", "expected", "attempt"].includes(k))
      || (r.phase === "read" ? r.expected !== undefined || r.attempt !== undefined : r.expected === undefined || (r.phase === "begin" ? r.attempt === undefined : r.attempt !== undefined))) {
      return { ok: false, code: "validation.invalid", message: "invalid receiving transition" }
    }
    const refuse = (reply: VmReply): VmReply => { d.audit({ phase: r.phase, machine: r.machine, changed: false, outcome: "refused" }); return reply }
    const gate = () => vmGate(d.team, p, r.machine, d.rows)
    const permitted = r.phase === "read" || r.phase === "end" ? boundVmReceiver : liveVmReceiver
    // Power state gates activation, but cannot change the original identity
    // whose receiver must retire during park. Preserve the running scope hash.
    const stamp = (row: MachineRow) => vmReceiverStamp({ ...row, status: "running" })
    const first = gate(), started = d.now()
    if (!first.ok) return refuse(first)
    if (!p.user || !p.install || !p.grant || !permitted(first.row, p) || (p.expires_at !== undefined && p.expires_at <= started)) return refuse(forbidden())
    const original = stamp(first.row)
    let own: NetworkIdentity | null
    try { own = await d.own(p.user, p.install, p.grant, r.machine) }
    catch { return refuse(unavailable()) }
    const now = d.now(), current = gate()
    // Timeout/cancellation must fence the continuation before any authority change.
    if (signal.aborted || now < started || now >= started + 15_000) return refuse(unavailable())
    if (!current.ok || !permitted(current.row, p) || stamp(current.row) !== original
      || !originalVmReceiverGrant(p, own, now) || (p.expires_at !== undefined && p.expires_at <= now)) return refuse(forbidden())
    const scope = vmReceiverScope(current.row, p.grant, own)
    // No I/O or await separates the final original-scope check from the atomic
    // private record and audit. An audit failure rolls the transition back.
    return new VmReceiverGenerations(d.sql()).apply(r.machine, scope, r, d.audit, { user: p.user, install: p.install, grant: p.grant })
  }, catch: unavailable }).pipe(Effect.timeout("15 seconds"), Effect.catch(() => Effect.succeed(unavailable())))
)
