import type { Principal, RejectFrame, ResultFrame } from "@cmux/ownership"
import { HostNetworkBind, type Host } from "@cmux/protocol"
import { admit, decodeParams } from "./domains/common.ts"
import { sha256Hex } from "./domains/pairing.ts"
import { can, hostOf } from "./domains/team-members.ts"
import { sameServerNetwork } from "./domains/team-servers.ts"
import { installPublicPoint } from "./install-public-point.ts"
import { networkOrigin, verifyNetworkIdentity, type NetworkIdentityDeps } from "./network-policy-read.ts"
import type { DomainReply } from "./team-domain-external.ts"
import type { VmApiTenant } from "./team-vm-api-tenant.ts"

const pointOf = (key: JsonWebKey | null): string | null => { try { return key ? installPublicPoint(key) : null } catch { return null } }
const tenantMatches = (d: NetworkIdentityDeps, target: VmApiTenant | null): target is VmApiTenant =>
  target?.team === d.team && target.project === d.project

const ownHost = (d: NetworkIdentityDeps, p: Principal, id: string): typeof Host.Type | undefined => {
  const state = d.state(), host = hostOf(state, d.rows, id)
  return p.kind === "install" && !p.agent && ["mac", "ios", "cli"].includes(p.install_kind ?? "") && p.team === d.team && p.user && p.install && p.grant
    && state.team?.id === d.team && state.team.deleted_at === undefined && host && host.kind !== "server" && !host.orphaned
    && host.owner_user === p.user && host.enrolled_by === p.install && !state.server_revocations?.[p.install] && can(state, d.rows, p.user, "team.resources") ? host : undefined
}

/** A binding records verified identity, never current policy or transport authority. */
export const hostNetworkExternal = async (d: NetworkIdentityDeps, p: Principal, frame: { op: string; params: unknown; idempotency_key: string; expected_revision?: string }): Promise<DomainReply> => {
  const base = { op: frame.op, transaction: "", idempotency_key: frame.idempotency_key, stream: d.stream, sequence: 0, replayed: false }
  const fail = (code: string, message: string, retryable = false): DomainReply => ({ ...base, ok: false, error: { code, message, retryable } })
  if (frame.op !== HostNetworkBind.name) return fail("validation.invalid", "invalid host network operation")
  const admission = admit("cloud:TeamDO", frame.op, p, () => p.grant_classes ? { op_classes: p.grant_classes, revoked_at: null, expires_at: null } : undefined, d.now())
  if (admission) return fail(admission.code, admission.message)
  const decoded = decodeParams<typeof HostNetworkBind.params.Type>(HostNetworkBind, frame.params)
  if (!decoded.ok) return fail("validation.invalid", "invalid host network binding")
  const v = decoded.value, host = ownHost(d, p, v.host), origin = networkOrigin(d.origin)
  if (!host) return fail("auth.forbidden", "only the current client may bind its own host")
  if (!origin) return fail("owner.unreachable", "network identity verification is unavailable", true)
  try {
    const [target, key] = await Promise.all([d.tenant(), d.key(p.user!, p.install!, p.grant!)])
    const point = pointOf(key)
    if (!tenantMatches(d, target) || !point) return fail("auth.forbidden", "the host owner identity could not be verified")
    const network = { tenant: target.tenant, mesh: v.mesh, device: v.device }
    if (host.network && !sameServerNetwork(network, host.network)) return fail("auth.forbidden", "the host network binding cannot be retargeted")
    const read = await verifyNetworkIdentity(d.http, origin, "device", { ...network, wg: v.wg_public_key, point }, v.proof, d.now())
    if (!read.ok) return fail(read.code, read.message, read.retryable)
    const operationKey = `host-network-v2:${await sha256Hex(`${p.user}:${p.install}:${p.grant}:${frame.idempotency_key}`)}`
    const [currentTarget, currentKey] = await Promise.all([d.tenant(), d.key(p.user!, p.install!, p.grant!)])
    const current = ownHost(d, p, v.host)
    if (!tenantMatches(d, currentTarget) || currentTarget.tenant !== target.tenant || pointOf(currentKey) !== point || !current
      || (current.wg_public_key !== host.wg_public_key && current.wg_public_key !== v.wg_public_key)
      || (current.network && !sameServerNetwork(network, current.network))) return fail("auth.forbidden", "the host identity changed")
    // No await between the final live-host check and this synchronous commit.
    // Only stable business intent enters the ledger, so fresh-proof retries replay.
    const params = { host: host.id, install: p.install, owner_user: p.user, grant: p.grant, wg_public_key: v.wg_public_key, network }
    const { frames } = d.submitSystem("host.network.bound", params, operationKey, frame.expected_revision)
    const rejected = frames.find((f): f is RejectFrame => f.t === "reject")
    if (rejected) return { ...base, ok: false, transaction: rejected.tx, replayed: rejected.replayed, error: { code: rejected.code, message: rejected.message, retryable: rejected.retryable } }
    const result = frames.find((f): f is ResultFrame => f.t === "result")
    if (!result) return fail("owner.unreachable", "the host binding could not be recorded", true)
    const settled = frames.find((f) => f.t === "request-settled") as { sequence?: number } | undefined
    return { ...base, ok: true, value: result.value, transaction: result.tx, replayed: result.replayed, sequence: settled?.sequence ?? 0 }
  } catch { return fail("owner.unreachable", "network identity verification is unavailable", true) }
}
