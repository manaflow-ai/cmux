import type { Principal, RowReader, SqlStore } from "@cmux/ownership"
import { Effect } from "effect"
import { TABLE_MACHINE, type MachineRow } from "./domains/cloud.ts"
import type { NetworkIdentity } from "./host-network-peers.ts"
import { VmReceiverGenerations, type StoredReceiverAuthority } from "./cloud-vm-receiver-generations.ts"
import { liveVmReceiver, originalVmReceiverGrant, vmReceiverScope, vmReceiverStamp } from "./cloud-vm-receiver-identity.ts"

interface Deps {
  team: string; rows: RowReader | undefined; sql: SqlStore; now(): number;
  own(user: string, install: string, grant: string, machine: string): Promise<NetworkIdentity | null>;
}
export interface VmReceiverPermit extends StoredReceiverAuthority { expires_at: number | null }

/** Recover only context committed by the authenticated VM lifecycle. Check the
 * original UserDO grant and re-read the exact ready record after that await.
 * Neither the dialer nor a stored generation can supply its own authority.
 */
export const readVmReceiverPermit = (d: Deps, machine: string): Promise<VmReceiverPermit | null> => Effect.runPromise(
  Effect.tryPromise({ try: async (signal): Promise<VmReceiverPermit | null> => {
    const started = d.now(), store = new VmReceiverGenerations(d.sql)
    const stored = store.storedAuthority(machine)
    if (!stored) return null
    const { user, install, grant } = stored.identity
    const p: Principal = { identity: install, kind: "install", user, install, grant, team: d.team, install_kind: "vm", bound_machine: machine, grant_classes: ["vm-self"] }
    const row = () => d.rows?.get<MachineRow>(TABLE_MACHINE, machine)?.row
    const first = row()
    if (!first || !liveVmReceiver(first, p)) return null
    const stamp = vmReceiverStamp(first), own = await d.own(user, install, grant, machine)
    const now = d.now(), current = row(), ready = store.storedAuthority(machine)
    if (signal.aborted || now < started || now >= started + 15_000 || !current || !liveVmReceiver(current, p)
      || vmReceiverStamp(current) !== stamp || !originalVmReceiverGrant(p, own, now)
      || !ready || ready.generation !== stored.generation || ready.scope !== stored.scope
      || ready.identity.user !== user || ready.identity.install !== install || ready.identity.grant !== grant
      || vmReceiverScope(current, grant, own) !== stored.scope) return null
    return { ...ready, expires_at: own.expires_at }
  }, catch: () => null }).pipe(Effect.timeout("15 seconds"), Effect.catch(() => Effect.succeed(null)))
)

export const sameVmReceiverPermit = (a: VmReceiverPermit, b: VmReceiverPermit | null): boolean =>
  b !== null && a.machine === b.machine && a.scope === b.scope && a.generation === b.generation && a.expires_at === b.expires_at
    && a.identity.user === b.identity.user && a.identity.install === b.identity.install && a.identity.grant === b.identity.grant
