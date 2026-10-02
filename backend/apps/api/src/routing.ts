import { env as workerEnv } from "cloudflare:workers"
import type { Principal } from "@cmux/ownership"
import { APP_ID_PATTERN, Forbidden, OwnerUnreachable, type DoOwner } from "@cmux/protocol"
import { Effect } from "effect"
import { withGrantClasses } from "./auth.ts"
import type { Env } from "./env.ts"

const env = workerEnv as unknown as Env

/** DO RPC stubs erase union result types; the DO methods define them. */
export const rpc = <T>(p: unknown) => p as Promise<T>

/** Shape every owner DO exposes over RPC (OwnerDO). */
export interface OwnerStub {
  submit(entity: string, principal: Principal, frame: { t: "op"; op: string; params: unknown; idempotency_key: string; origin?: string; expected_revision?: string }): Promise<unknown>
  readOp(entity: string, principal: Principal, op: string, params: unknown): Promise<unknown>
}

export interface OwnerRoute {
  readonly stub: OwnerStub
  readonly entity: string
  readonly stream: string
}

const route = (ns: DurableObjectNamespace, entity: string, prefix: string): OwnerRoute => ({
  stub: ns.get(ns.idFromName(entity)) as unknown as OwnerStub,
  entity,
  stream: `${prefix}:${entity}`
})

/** AppDO's entity is the app the params name (`app`, or `manifest.id` for app.version.submit). */
const appEntity = (params: unknown): string | undefined => {
  const p = (params ?? {}) as { app?: unknown; manifest?: { id?: unknown } | null }
  const id = typeof p.app === "string" ? p.app : typeof p.manifest?.id === "string" ? p.manifest.id : undefined
  return id !== undefined && APP_ID_PATTERN.test(id) ? id : undefined
}

/**
 * Owner routing table: which object owns an op for this principal and these
 * params. UserDO is keyed by the user; TeamDO, SchedulerDO and ConnectionDO by
 * the principal's team (phase 1: the personal team from the token; Stack
 * teams will need a TeamDO membership check before routing to a team other
 * than the token's); AppDO by the app id in the params. Undefined = the
 * params name no entity.
 */
const ownerRoutes: Record<DoOwner, (p: Principal, params: unknown) => OwnerRoute | undefined> = {
  "cloud:UserDO": (p) => route(env.USER_DO as unknown as DurableObjectNamespace, p.user!, "user"),
  "cloud:TeamDO": (p) => route(env.TEAM_DO as unknown as DurableObjectNamespace, p.team!, "team"),
  "cloud:SchedulerDO": (p) => route(env.SCHEDULER_DO as unknown as DurableObjectNamespace, p.team!, "scheduler"),
  "cloud:ConnectionDO": (p) => route(env.CONNECTION_DO as unknown as DurableObjectNamespace, p.team!, "connections"),
  "cloud:AppDO": (_p, params) => {
    const app = appEntity(params)
    return app === undefined ? undefined : route(env.APP_DO as unknown as DurableObjectNamespace, app, "app")
  }
}

export const ownerRoute = (owner: DoOwner, p: Principal, params: unknown): OwnerRoute | undefined => ownerRoutes[owner](p, params)

export const unreachable = (e: unknown) => new OwnerUnreachable({ code: "owner.unreachable", message: String(e), retryable: true })

/** Principal for a given owner: every owner but UserDO gets the grant classes UserDO resolved. */
export const principalFor = (owner: string, p: Principal) =>
  owner === "cloud:UserDO"
    ? Effect.succeed(p)
    : Effect.tryPromise({ try: () => withGrantClasses(env, p), catch: unreachable }).pipe(
        Effect.flatMap((q) => (q ? Effect.succeed(q) : Effect.fail(new Forbidden({ code: "auth.forbidden", message: "install revoked or grant invalid" }))))
      )
