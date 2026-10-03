import type { Schema } from "effect"

/**
 * Cloud operations, authored in Effect Schema (spec D7). `catalog:export`
 * writes them into the cmux operation catalog; the API Worker routes and
 * validates with the same definitions.
 */
export interface CloudOpDef<P extends Schema.Top = Schema.Top, R extends Schema.Top = Schema.Top> {
  readonly name: string
  readonly owner:
    | "cloud:UserDO"
    | "cloud:TeamDO"
    | "cloud:SchedulerDO"
    | "cloud:ConnectionDO"
    | "cloud:FeedDO"
    | "cloud:ConversationDO"
    | "cloud:MuxDO"
    | "cloud:AddressDO"
    | "cloud:PairingDO"
    /** One per team: the automation usage ledger and hard cap (automations-billing.md). */
    | "cloud:UsageMeterDO"
    | "cloud:TeamVmDO"
    /** A read of a PlanetScale projection through the read-only Hyperdrive (for example home.search). */
    | "cloud:planetscale"
  readonly class: "read" | "mutation"
  readonly risk: "read" | "mutate-own" | "mutate-shared" | "execute" | "send-external" | "money" | "destructive"
  readonly target: string
  /**
   * Who may call: a Stack session (human), an install token, or both. `system`
   * is a principal a Durable Object builds for its own internal ops; such ops
   * are never in `cloudOps` (no HTTP, MCP or CLI surface).
   */
  readonly principals: ReadonlyArray<"session" | "install" | "system">
  readonly params: P
  readonly result: R
  readonly errors: ReadonlyArray<string>
  readonly docs: string
  readonly cli: { readonly path: string; readonly visible: boolean }
  readonly mcp: { readonly expose: "default" | "opt_in" | "never"; readonly group: string }
}

export const def = <P extends Schema.Top, R extends Schema.Top>(d: CloudOpDef<P, R>) => d

export const mutationErrors = ["validation.invalid", "idempotency.conflict", "revision.conflict", "auth.forbidden", "auth.unauthenticated"]
