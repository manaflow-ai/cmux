import type { Principal, RejectFrame, ResultFrame } from "@cmux/ownership"
import { ServerNetworkConfirm, type Host } from "@cmux/protocol"
import { admit, decodeParams } from "./domains/common.ts"
import { can, hostOf } from "./domains/team-members.ts"
import { sameServerNetwork, serverPlacementActive } from "./domains/team-servers.ts"
import { sha256Hex } from "./domains/pairing.ts"
import { installPublicPoint } from "./install-public-point.ts"
import type { DomainReply } from "./team-domain-external.ts"
import { networkOrigin, verifyNetworkIdentity, type NetworkIdentityDeps } from "./network-policy-read.ts"
import type { VmApiTenant } from "./team-vm-api-tenant.ts"

export type ServerNetworkDeps = NetworkIdentityDeps

const targetMatches = (d: ServerNetworkDeps, target: VmApiTenant | null, tenant: string): boolean =>
  target?.team === d.team && target.project === d.project && target.tenant === tenant
const pointOf = (key: JsonWebKey | null): string | null => { try { return key ? installPublicPoint(key) : null } catch { return null } }

/** Re-read live rows after external awaits, including before an idempotent replay. */
const ownServer = (d: ServerNetworkDeps, p: Principal, id: string): typeof Host.Type | undefined => {
  const state = d.state(), host = hostOf(state, d.rows, id)
  return p.kind === "install" && !p.agent && p.install_kind === "daemon" && p.team === d.team && p.user && p.install && p.grant
    && state.team?.id === d.team && state.team.deleted_at === undefined && host?.owner_user === p.user && can(state, d.rows, p.user, "team.resources")
    && serverPlacementActive(state, d.rows, id, p.install) ? host : undefined
}

/** No account credential is used. Only business identity reaches the owner ledger. */
export const serverNetworkExternal = async (d: ServerNetworkDeps, p: Principal, frame: { op: string; params: unknown; idempotency_key: string }): Promise<DomainReply> => {
  const base = { op: frame.op, transaction: "", idempotency_key: frame.idempotency_key, stream: d.stream, sequence: 0, replayed: false }
  const fail = (code: string, message: string, retryable = false): DomainReply => ({ ...base, ok: false, error: { code, message, retryable } })
  if (frame.op !== ServerNetworkConfirm.name) return fail("validation.invalid", "invalid server network operation")
  const admission = admit("cloud:TeamDO", frame.op, p, () => p.grant_classes ? { op_classes: p.grant_classes, revoked_at: null, expires_at: null } : undefined, d.now())
  if (admission) return fail(admission.code, admission.message)
  const decoded = decodeParams<typeof ServerNetworkConfirm.params.Type>(ServerNetworkConfirm, frame.params)
  if (!decoded.ok) return fail("validation.invalid", "invalid server network confirmation")
  const v = decoded.value, host = ownServer(d, p, v.host), origin = networkOrigin(d.origin)
  if (!host?.network || !host.wg_public_key || host.network.mesh !== v.mesh || host.network.device !== v.device) return fail("auth.forbidden", "no matching approved server network reservation")
  if (!origin) return fail("owner.unreachable", "server network confirmation is unavailable")
  if (!Number.isSafeInteger(v.proof.signedAt) || Math.abs(d.now() - v.proof.signedAt) > 120_000) return fail("validation.invalid", "the network proof must be freshly signed", true)
  const network = { state: "reserved" as const, tenant: host.network.tenant, mesh: v.mesh, device: v.device }
  try {
    const operationKey = `server-network-v2:${await sha256Hex(`${p.user}:${p.install}:${p.grant}:${frame.idempotency_key}`)}`
    const [target, key] = await Promise.all([d.tenant(), d.key(p.user!, p.install!, p.grant!)])
    const point = pointOf(key)
    if (!targetMatches(d, target, network.tenant) || !point) return fail("auth.forbidden", "the server's owner identity could not be verified")
    const read = await verifyNetworkIdentity(d.http, origin, "server", { ...network, wg: host.wg_public_key, point }, v.proof, d.now())
    if (!read.ok) return fail(read.code, read.message, read.retryable)
    const [currentTarget, currentKey] = await Promise.all([d.tenant(), d.key(p.user!, p.install!, p.grant!)])
    const current = ownServer(d, p, v.host)
    if (!targetMatches(d, currentTarget, network.tenant) || pointOf(currentKey) !== point || !current?.network
      || current.wg_public_key !== host.wg_public_key || !sameServerNetwork(network, current.network)) return fail("auth.forbidden", "the approved server identity changed")
    // The proof, policy and arbitrary response fields never enter this command.
    const { frames } = d.submitSystem("server.network.confirmed", { host: host.id, install: p.install, owner_user: p.user, grant: p.grant, wg_public_key: host.wg_public_key, network }, operationKey)
    const rejected = frames.find((f): f is RejectFrame => f.t === "reject")
    if (rejected) return fail(rejected.code, rejected.message)
    const result = frames.find((f): f is ResultFrame => f.t === "result")
    if (!result) return fail("owner.unreachable", "server network confirmation could not be recorded", true)
    const settled = frames.find((f) => f.t === "request-settled") as { sequence?: number } | undefined
    return { ...base, ok: true, value: result.value, transaction: result.tx, replayed: result.replayed, sequence: settled?.sequence ?? 0 }
  } catch { return fail("owner.unreachable", "server network confirmation is unavailable", true) }
}
