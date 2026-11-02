import { Schema } from "effect"

const Port = Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: 65535 }))
/** One Native service rule: TCP/UDP with an optional port, or any/ICMP with none. */
export const NetworkAllow = Schema.Union([
  Schema.Struct({ protocol: Schema.Literals(["tcp", "udp"]), port: Schema.optionalKey(Port) }),
  Schema.Struct({ protocol: Schema.Literals(["any", "icmp"]) })
])
