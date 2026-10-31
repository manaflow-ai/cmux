import { HostId, InstallId, NativeDeviceId, NativeMeshId, NativeTenantId, UserId, WgPublicKey } from "@cmux/protocol"
import { Schema } from "effect"

/** Authenticated peer metadata; raw grants and private authority stamps never enter a token. */
const NativeLinkBindingSchema = Schema.Struct({
  version: Schema.Literal(1), tenant: NativeTenantId, mesh: NativeMeshId, device: NativeDeviceId,
  host: HostId, user: UserId, wg_public_key: WgPublicKey,
  authority_version: Schema.String.check(Schema.isPattern(/^[0-9a-f]{64}$/)),
  acl_version: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0))
})
export type NativeLinkBinding = typeof NativeLinkBindingSchema.Type
const NativeReceiverBindingSchema = Schema.Struct({
  version: Schema.Literal(2), generation: Schema.String.check(Schema.isPattern(/^[0-9a-f]{64}$/))
})
export type NativeReceiverBinding = typeof NativeReceiverBindingSchema.Type
export const isNativeReceiverBinding = (value: unknown): value is NativeReceiverBinding =>
  Schema.is(NativeReceiverBindingSchema)(value) && Object.keys(value as object).length === 2
export interface NativeLinkExpected {
  readonly issuer: string
  readonly team: string
  readonly install: string
  readonly service: string
  readonly binding: NativeLinkBinding
  readonly receiver?: NativeReceiverBinding
}
const fields = ["version", "tenant", "mesh", "device", "host", "user", "wg_public_key", "authority_version", "acl_version"] as const
export const isNativeLinkBinding = (value: unknown): value is NativeLinkBinding =>
  Schema.is(NativeLinkBindingSchema)(value) && Object.keys(value as object).length === fields.length

/** A receiver supplies its current authenticated peer mapping, never values taken from the JWT. */
export const matchesNativeLink = (claims: Record<string, unknown>, expected: NativeLinkExpected, now: number): boolean => {
  const network = claims.network
  const receiver = claims.receiver
  return isNativeLinkBinding(network) && isNativeLinkBinding(expected.binding)
    && (expected.receiver === undefined ? receiver === undefined : isNativeReceiverBinding(receiver)
      && isNativeReceiverBinding(expected.receiver) && receiver.generation === expected.receiver.generation)
    && fields.every((key) => network[key] === expected.binding[key])
    && claims.iss === expected.issuer && claims.team === expected.team && claims.sub === expected.install
    && Schema.is(InstallId)(claims.sub) && ["daemon", "ssh"].includes(expected.service)
    && Array.isArray(claims.svc) && claims.svc.length > 0 && claims.svc.length <= 2
    && claims.svc.every((s: unknown) => s === "daemon" || s === "ssh") && new Set(claims.svc).size === claims.svc.length && claims.svc.some((s: unknown) => s === expected.service)
    && typeof claims.jti === "string" && /^[A-Za-z0-9_-]{21}[AQgw]$/.test(claims.jti)
    && Number.isSafeInteger(claims.iat) && Number(claims.iat) > 0 && Number(claims.iat) <= now
    && Number.isSafeInteger(claims.exp) && Number(claims.exp) > Number(claims.iat)
}
