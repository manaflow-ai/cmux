import type { Principal } from "@cmux/ownership"
import { CloudVmNetworkPolicy, CloudVmNetworkPolicyView, NativeVmId } from "@cmux/protocol"
import { Effect, Schema } from "effect"
import type { MachineRow } from "./domains/cloud.ts"
import { decodeParams } from "./domains/common.ts"
import { vmGate } from "./cloud-vm.ts"
import { digest, pointOf, type NetworkIdentity } from "./host-network-peers.ts"
import type { ReadResult } from "./owner-do.ts"
import type { VmApiConnection } from "./cloud-vm-api-config.ts"
import { addressInMesh } from "./cloud-vm-api-network.ts"
import type { VmReceiverPeers, VmReceiverPeerTarget } from "./cloud-vm-receiver-peers.ts"
import { readNativeVmReceiverPolicy } from "./cloud-vm-receiver-native.ts"
import type { Http } from "./team-domain-external.ts"

interface Deps {
  team: string; now(): number; connection(): VmApiConnection | null; revision(): string; http: Http;
  row(machine: string): MachineRow | undefined;
  own(user: string, install: string, grant: string, machine: string): Promise<NetworkIdentity | null>;
  allocation(row: MachineRow, signal: AbortSignal): Promise<string | null>; peers(target: VmReceiverPeerTarget): Promise<VmReceiverPeers | null>;
}
const unavailable = (): ReadResult => ({ ok: false, code: "owner.unreachable", message: "the current VM receiving policy is unavailable" })
const forbidden = (): ReadResult => ({ ok: false, code: "auth.forbidden", message: "the original bound VM authority is unavailable" })
const stamp = (r: MachineRow) => digest([r.id, r.team, r.creator, r.status, r.transport, r.provider_name, r.vm_install, r.epoch, r.host, r.host_id, r.wg_public_key, r.network])
const live = (row: MachineRow, p: Principal): boolean => row.team === p.team && row.transport === "vm-api" && row.status === "running" && row.creator === p.user
  && row.host !== undefined && row.host === row.host_id && row.wg_public_key !== undefined && Number.isSafeInteger(row.epoch) && Number(row.epoch) > 0
  && row.network !== undefined && row.vm_install === p.install
const ownMatches = (p: Principal, own: NetworkIdentity | null, now: number): own is NetworkIdentity => own !== null && own.kind === "vm"
  && own.op_classes.includes("vm-self") && (own.expires_at === null || own.expires_at > now) && pointOf(own) !== null
  && /^[0-9a-f]{64}$/.test(own.authority_version) && (p.install_authority === undefined || p.install_authority === own.authority_version)

/** CloudDO owns the VM fence; TeamDO/UserDO own client grants. Nothing is persisted by this read. */
export const cloudVmReceiverPolicy = (d: Deps, p: Principal, params: unknown): Promise<ReadResult> => Effect.runPromise(
  Effect.tryPromise({ try: async (signal): Promise<ReadResult> => {
    const decoded = decodeParams<typeof CloudVmNetworkPolicy.params.Type>(CloudVmNetworkPolicy, params)
    if (!decoded.ok) return decoded
    const checked = d.now(), machine = decoded.value.machine
    const gate = () => vmGate(d.team, p, machine, { get: <T>() => { const row = d.row(machine); return row ? { row: row as T, n: null } : undefined } })
    const first = gate(), connection = d.connection()
    if (!first.ok) return first
    if (!connection || !p.user || !p.install || !p.grant || (p.expires_at !== undefined && p.expires_at <= checked) || !live(first.row, p)) return forbidden()
    const own = await d.own(p.user, p.install, p.grant, machine)
    if (signal.aborted || !ownMatches(p, own, d.now())) return forbidden()
    const ready = gate()
    if (!ready.ok || !live(ready.row, p)) return forbidden()
    const row = ready.row, original = stamp(row), vm = await d.allocation(row, signal)
    if (signal.aborted || !Schema.is(NativeVmId)(vm)) return unavailable()
    const native = await readNativeVmReceiverPolicy(d.http, connection, row.network!.tenant, row.network!.mesh, vm, signal)
    if (signal.aborted || !native || (native.ipv4 !== null && !addressInMesh(native.ipv4, row.network!.ipv4_cidr)) || native.checkedAt > d.now() || native.expiresAt <= d.now()) return unavailable()
    const target = { creator: row.creator, origin: connection.origin, deadline: checked + 15_000, policy: native }, peers = await d.peers(target)
    if (!peers || signal.aborted) return unavailable()
    const [currentOwn, currentVm, currentPeers] = await Promise.all([d.own(p.user, p.install, p.grant, machine), d.allocation(row, signal), d.peers(target)])
    const current = gate(), after = d.connection(), now = d.now()
    if (signal.aborted || !current.ok || !live(current.row, p) || stamp(current.row) !== original
      || after?.origin !== connection.origin || after.key !== connection.key || currentVm !== vm
      || !ownMatches(p, currentOwn, now) || currentOwn.authority_version !== own.authority_version || pointOf(currentOwn) !== pointOf(own)
      || !currentPeers || currentPeers.authority_version !== peers.authority_version || now < checked) return forbidden()
    const expires = Math.min(checked + 30_000, native.expiresAt, currentPeers.expires_at, currentOwn.expires_at ?? Infinity, p.expires_at ?? Infinity)
    if (expires <= now) return forbidden()
    const value = { schema_version: 1, machine, host: row.host, epoch: row.epoch, user: row.creator, install: p.install, team: d.team,
      origin: connection.origin, tenant: native.tenantId, mesh: native.meshId, vm, ipv4: native.ipv4, wg_public_key: row.wg_public_key,
      install_public_key: pointOf(currentOwn), checked_at: checked, expires_at: expires, acl_version: native.aclVersion, policy_digest: native.policyDigest,
      authority_version: digest(["cmux-cloud-vm-receiver-v1", original, currentOwn.authority_version, currentPeers.authority_version, native.aclVersion, native.policyDigest]), peers: currentPeers.peers }
    return Schema.is(CloudVmNetworkPolicyView)(value) ? { ok: true, value, revision: d.revision() } : unavailable()
  }, catch: unavailable }).pipe(Effect.timeout("15 seconds"), Effect.catch(() => Effect.succeed(unavailable())))
)
