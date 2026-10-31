import type { Principal } from "@cmux/ownership"
import type { MachineRow } from "./domains/cloud.ts"
import { digest, pointOf, type NetworkIdentity } from "./host-network-peers.ts"

/** Public original VM identity; renewal timestamps are not an incarnation. */
export const vmReceiverStamp = (r: MachineRow) => digest([r.id, r.team, r.creator, r.status, r.transport, r.provider_name, r.vm_install, r.epoch, r.host, r.host_id, r.wg_public_key, r.network])
export const vmReceiverScope = (row: MachineRow, grant: string, own: NetworkIdentity) =>
  digest(["cmux-vm-receiver-scope-v1", vmReceiverStamp({ ...row, status: "running" }), grant, own.authority_version, pointOf(own)])
export const boundVmReceiver = (row: MachineRow, p: Principal): boolean => row.team === p.team && row.transport === "vm-api" && row.creator === p.user
  && row.host !== undefined && row.host === row.host_id && row.wg_public_key !== undefined && Number.isSafeInteger(row.epoch) && Number(row.epoch) > 0
  && row.network !== undefined && row.vm_install === p.install
export const liveVmReceiver = (row: MachineRow, p: Principal): boolean => row.status === "running" && boundVmReceiver(row, p)
export const originalVmReceiverGrant = (p: Principal, own: NetworkIdentity | null, now: number): own is NetworkIdentity => own !== null && own.kind === "vm"
  && own.op_classes.includes("vm-self") && (own.expires_at === null || Number.isSafeInteger(own.expires_at) && own.expires_at > now) && pointOf(own) !== null
  && /^[0-9a-f]{64}$/.test(own.authority_version) && (p.install_authority === undefined || p.install_authority === own.authority_version)
