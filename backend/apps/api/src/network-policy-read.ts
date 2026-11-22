import type { ServerNetworkProof } from "@cmux/protocol"
import type { OwnerFrame, RowReader } from "@cmux/ownership"
import type { TeamState } from "./domains/team.ts"
import type { Http } from "./team-domain-external.ts"
import type { VmApiTenant } from "./team-vm-api-tenant.ts"

export interface NetworkIdentityDeps {
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
  readonly submitSystem: (op: string, params: unknown, key: string, expectedRevision?: string) => { frames: ReadonlyArray<OwnerFrame> }
}

export const networkOrigin = (value: string | undefined): string | null => {
  if (!value) return null
  try { const u = new URL(value); return u.protocol === "https:" && u.origin === value && !u.username && !u.password ? value : null } catch { return null }
}

export interface NetworkIdentity {
  readonly tenant: string
  readonly mesh: string
  readonly device: string
  readonly wg: string
  readonly point: string
}

type Failure = { readonly ok: false; readonly code: string; readonly message: string; readonly retryable: boolean }
export type NetworkRead = { readonly ok: true; readonly policy: Record<string, unknown> } | Failure

/** Bound responses even when the trusted service sends an unexpected policy. */
export const networkBody = async (response: Response): Promise<Record<string, unknown> | null> => {
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

/** Fixed endpoints; the verified policy stays inside the Worker for authorization. */
export const verifyNetworkIdentity = async (
  http: Http, origin: string, kind: "device" | "server", identity: NetworkIdentity,
  proof: typeof ServerNetworkProof.Type, now: number
): Promise<NetworkRead> => {
  const fail = (code: string, message: string, retryable = false): Failure => ({ ok: false, code, message, retryable })
  if (!Number.isSafeInteger(proof.signedAt) || Math.abs(now - proof.signedAt) > 120_000) return fail("validation.invalid", "the network proof must be freshly signed", true)
  const path = kind === "server" ? `/v1/overlay-servers/${identity.device}/signed/policy` : `/v1/devices/${identity.device}/signed/overlay-policy`
  try {
    const response = await http(new Request(`${origin}${path}`, {
      method: "POST", headers: { "content-type": "application/json", accept: "application/json" },
      body: JSON.stringify({ signedAt: proof.signedAt, nonce: proof.nonce, signature: proof.signature }),
      redirect: "manual", signal: AbortSignal.timeout(15_000)
    }))
    if (response.status === 404) return fail("selector.not_found", "the network identity is unavailable")
    if (response.status === 401 || response.status === 403) return fail("auth.forbidden", "the network proof was refused")
    if (response.status === 409) return fail("validation.invalid", "sign a fresh network proof", true)
    if (!response.ok) return fail("owner.unreachable", "network identity verification is unavailable", true)
    const policy = await networkBody(response)
    if (!policy) return fail("owner.unreachable", "network identity verification is unavailable", true)
    if (policy.tenantId !== identity.tenant || policy.meshId !== identity.mesh || policy.deviceId !== identity.device
      || policy.wgPublicKey !== identity.wg || policy.installPublicKey !== identity.point) return fail("auth.forbidden", "the network identity does not match this install")
    return { ok: true, policy }
  } catch { return fail("owner.unreachable", "network identity verification is unavailable", true) }
}
