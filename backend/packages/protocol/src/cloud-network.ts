import { Schema } from "effect"
import { NativeMeshId, NativeTenantId } from "./server-network.ts"

/** Confirmed VM membership, not a tunnel configuration or a serving grant. */
export const CloudVmNetwork = Schema.Struct({ tenant: NativeTenantId, mesh: NativeMeshId, ipv4_cidr: Schema.String, ipv4: Schema.NullOr(Schema.String) }).annotate({ identifier: "CloudVmNetwork" })
