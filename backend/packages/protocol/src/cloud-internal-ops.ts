import { Schema } from "effect"
import type { CloudOpDef } from "./op-def.ts"

/**
 * Ops only CloudDO itself submits (plans/cmux-next/state-placement.md 5.2). Not exported to the
 * catalog: no HTTP, MCP or CLI surface.
 */
export const CloudDriverResultParams = Schema.Struct({
  /** The provider-call ledger row (one per intent, keyed by the op's idempotency key). */
  key: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(256)),
  ok: Schema.Boolean,
  /** create: the provider's VM id. */
  provider_id: Schema.optionalKey(Schema.String),
  error: Schema.optionalKey(Schema.Struct({ code: Schema.String, message: Schema.String })),
  /** Retrying cannot help (configuration, authorization, a name owned by someone else). */
  final: Schema.optionalKey(Schema.Boolean)
})

export const CloudPruneParams = Schema.Struct({ now: Schema.Int })

const internal = (name: string, params: Schema.Top, docs: string): CloudOpDef =>
  ({
    name,
    owner: "cloud:CloudDO",
    class: "mutation",
    risk: "mutate-own",
    target: "team",
    principals: ["system"],
    params,
    result: Schema.Unknown,
    errors: [],
    docs,
    cli: { path: "", visible: false },
    mcp: { expose: "never", group: "internal" }
  }) as CloudOpDef

export const cloudInternalOps: ReadonlyArray<CloudOpDef> = [
  internal("cloud.driver_result", CloudDriverResultParams, "Internal: a provider call (create or delete) finished, failed, or was refused."),
  internal("cloud.prune", CloudPruneParams, "Internal: drop tombstones older than 30 days and finished ledger rows older than 7 days.")
]
