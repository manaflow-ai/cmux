import type { OwnerFrame, Principal, RejectFrame, ResultFrame, RowReader } from "@cmux/ownership"
import { ServerNetworkConfirm, type Host } from "@cmux/protocol"
import { admit, decodeParams } from "./domains/common.ts"
import { can, hostOf } from "./domains/team-members.ts"
import { sameServerNetwork, serverPlacementActive } from "./domains/team-servers.ts"
import type { TeamState } from "./domains/team.ts"
import { sha256Hex } from "./domains/pairing.ts"
import { installPublicPoint } from "./install-public-point.ts"
import type { DomainReply, Http } from "./team-domain-external.ts"
import type { VmApiTenant } from "./team-vm-api-tenant.ts"

export interface ServerNetworkDeps {
  readonly team: string
  readonly project: string
  readonly origin: string | undefined
  readonly stream: string
  readonly state: () => TeamState
  readonly rows: RowReader | undefined
  readonly tenant: () => Promise<VmApiTenant | null>
  readonly key: (user: string, install: string, grant: string) => Promise<JsonWebKey | null>
  readonly http: Http
  readonly now: () => number
  readonly submitSystem: (op: string, params: unknown, key: string) => { frames: ReadonlyArray<OwnerFrame> }
}

const originOf = (value: string | undefined): string | null => {
  if (!value) return null
  try { const u = new URL(value); return u.protocol === "https:" && u.origin === value && !u.username && !u.password ? value : null } catch { return null }
}
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

/** Bounded even when a trusted endpoint returns an unexpected full policy or error body. */
const policyBody = async (response: Response): Promise<Record<string, unknown> | null> => {
  const reader = response.body?.getReader()
  if (!reader) return null
  const chunks: Uint8Array[] = []
  let size = 0
  try {
    for (;;) {
      const next = await reader.read()
      if (next.done) break
      size += next.value.byteLength
      if (size > 1_048_576) { await reader.cancel(); return null }
      chunks.push(next.value)
    }
  } finally { reader.releaseLock() }
  const bytes = new Uint8Array(size)
  let offset = 0
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength }
  const value: unknown = JSON.parse(new TextDecoder().decode(bytes))
  return value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null
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
  const v = decoded.value, host = ownServer(d, p, v.host), origin = originOf(d.origin)
  if (!host?.network || !host.wg_public_key || host.network.mesh !== v.mesh || host.network.device !== v.device) return fail("auth.forbidden", "no matching approved server network reservation")
  if (!origin) return fail("owner.unreachable", "server network confirmation is unavailable")
  if (!Number.isSafeInteger(v.proof.signedAt) || Math.abs(d.now() - v.proof.signedAt) > 120_000) return fail("validation.invalid", "the network proof must be freshly signed", true)
  const network = { state: "reserved" as const, tenant: host.network.tenant, mesh: v.mesh, device: v.device }
  try {
    const operationKey = `server-network:${await sha256Hex(`${p.user}:${p.install}:${frame.idempotency_key}`)}`
    const [target, key] = await Promise.all([d.tenant(), d.key(p.user!, p.install!, p.grant!)])
    const point = pointOf(key)
    if (!targetMatches(d, target, network.tenant) || !point) return fail("auth.forbidden", "the server's owner identity could not be verified")
    const response = await d.http(new Request(`${origin}/v1/overlay-servers/${network.device}/signed/policy`, {
      method: "POST", headers: { "content-type": "application/json", accept: "application/json" },
      body: JSON.stringify({ signedAt: v.proof.signedAt, nonce: v.proof.nonce, signature: v.proof.signature }),
      redirect: "manual", signal: AbortSignal.timeout(15_000)
    }))
    if (response.status === 404) return fail("selector.not_found", "the reserved network identity is unavailable")
    if (response.status === 401 || response.status === 403) return fail("auth.forbidden", "the network proof was refused")
    if (response.status === 409) return fail("validation.invalid", "sign a fresh network proof", true)
    if (!response.ok) return fail("owner.unreachable", "server network confirmation is unavailable", true)
    const policy = await policyBody(response)
    if (!policy) return fail("owner.unreachable", "server network confirmation is unavailable", true)
    if (policy.tenantId !== network.tenant || policy.meshId !== network.mesh || policy.deviceId !== network.device
      || policy.wgPublicKey !== host.wg_public_key || policy.installPublicKey !== point) return fail("auth.forbidden", "the network identity does not match the approved server")
    const [currentTarget, currentKey] = await Promise.all([d.tenant(), d.key(p.user!, p.install!, p.grant!)])
    const current = ownServer(d, p, v.host)
    if (!targetMatches(d, currentTarget, network.tenant) || pointOf(currentKey) !== point || !current?.network
      || current.wg_public_key !== host.wg_public_key || !sameServerNetwork(network, current.network)) return fail("auth.forbidden", "the approved server identity changed")
    // The proof, policy and arbitrary response fields never enter this command.
    const { frames } = d.submitSystem("server.network.confirmed", { host: host.id, install: p.install, owner_user: p.user, wg_public_key: host.wg_public_key, network }, operationKey)
    const rejected = frames.find((f): f is RejectFrame => f.t === "reject")
    if (rejected) return fail(rejected.code, rejected.message)
    const result = frames.find((f): f is ResultFrame => f.t === "result")
    if (!result) return fail("owner.unreachable", "server network confirmation could not be recorded", true)
    const settled = frames.find((f) => f.t === "request-settled") as { sequence?: number } | undefined
    return { ...base, ok: true, value: result.value, transaction: result.tx, replayed: result.replayed, sequence: settled?.sequence ?? 0 }
  } catch { return fail("owner.unreachable", "server network confirmation is unavailable", true) }
}
