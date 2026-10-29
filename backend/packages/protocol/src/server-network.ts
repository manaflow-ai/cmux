import { Schema } from "effect"
import { isPattern } from "./json-checks.ts"

export const NativeTenantId = Schema.String.check(isPattern(/^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/)).annotate({ identifier: "NativeTenantId" })
export const NativeMeshId = Schema.String.check(isPattern(/^mesh_[0-9a-hjkmnp-tv-z]{26}$/)).annotate({ identifier: "NativeMeshId" })
export const NativeDeviceId = Schema.String.check(isPattern(/^dev_[0-9a-hjkmnp-tv-z]{26}$/)).annotate({ identifier: "NativeDeviceId" })

const locator = { tenant: NativeTenantId, mesh: NativeMeshId, device: NativeDeviceId }
/** Approved public identity, not transport admission or a serving grant. */
export const ServerNetworkReservation = Schema.Struct({ state: Schema.Literal("reserved"), ...locator }).annotate({ identifier: "ServerNetworkReservation" })
/** Last verified registration; current peer policy and revocation remain independent. */
export const ServerNetworkBinding = Schema.Struct({ state: Schema.Literal("confirmed"), ...locator, confirmed_at: Schema.Int }).annotate({ identifier: "ServerNetworkBinding" })
export const ServerNetworkState = Schema.Union([ServerNetworkReservation, ServerNetworkBinding]).annotate({ identifier: "ServerNetworkState" })

/** One request's install-key proof. Consumed outside owner commands and ledgers. */
export const ServerNetworkProof = Schema.Struct({
  signedAt: Schema.Int,
  nonce: Schema.String.check(isPattern(/^[A-Za-z0-9_-]{22}$/)),
  signature: Schema.String.check(isPattern(/^[A-Za-z0-9+/]{86}==$/))
}).annotate({ identifier: "ServerNetworkProof" })
