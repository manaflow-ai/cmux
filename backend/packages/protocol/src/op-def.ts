import type { Schema } from "effect"

/**
 * Cloud operations, authored in Effect Schema (spec D7). `catalog:export`
 * writes them into the cmux operation catalog; the API Worker routes and
 * validates with the same definitions.
 */
/** Durable Object owners. Each has a route in the API Worker's owner table. */
export type DoOwner = "cloud:UserDO" | "cloud:TeamDO" | "cloud:SchedulerDO" | "cloud:ConnectionDO" | "cloud:AppDO"
/**
 * `cloud:planetscale` is the read projection in PlanetScale `cmux-next`, read
 * through the read-only Hyperdrive binding. It owns no writes: reads only.
 */
export type CloudOwner = DoOwner | "cloud:planetscale"

export interface CloudOpDef<P extends Schema.Top = Schema.Top, R extends Schema.Top = Schema.Top> {
  readonly name: string
  readonly owner: CloudOwner
  /**
   * For ops that exist on a personal and a team owner (apps): `params.scope`
   * ("user" | "team", absent = "user") picks the owner; `owner` is the user one.
   */
  readonly scopeOwners?: { readonly user: DoOwner; readonly team: DoOwner }
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

/** The owner that decides this op for these params (`scopeOwners` by `params.scope`, else `owner`). */
export const resolveOwner = (op: CloudOpDef, params: unknown): CloudOwner => {
  if (!op.scopeOwners) return op.owner
  const scope = (params as { scope?: unknown } | null)?.scope
  return scope === "team" ? op.scopeOwners.team : op.scopeOwners.user
}

/** True when `owner` may hold this op (its owner, or one of its scope owners). */
export const heldBy = (op: CloudOpDef, owner: CloudOwner): boolean =>
  op.owner === owner || op.scopeOwners?.user === owner || op.scopeOwners?.team === owner
