import { env as workerEnv } from "cloudflare:workers"
import type { Principal } from "@cmux/ownership"
import { AppSearch, BadRequest, type CloudOpDef, type DoOwner } from "@cmux/protocol"
import { Effect, Exit, Schema } from "effect"
import { searchApps } from "./app-store.ts"
import type { Env } from "./env.ts"
import type { ReadResult } from "./owner-do.ts"
import { ownerRoute, principalFor, rpc, unreachable } from "./routing.ts"

const env = workerEnv as unknown as Env

interface InstallsValue {
  installs: Array<unknown>
  approvals: Array<unknown>
  policy: unknown
}

const readFrom = (owner: DoOwner, principal: Principal, op: string, params: unknown) =>
  Effect.gen(function* () {
    const reader = yield* principalFor(owner, principal)
    const route = ownerRoute(owner, reader, params)!
    return yield* Effect.tryPromise({ try: () => rpc<ReadResult>(route.stub.readOp(route.entity, reader, op, params)), catch: unreachable })
  })

/**
 * App store reads the generic owner path cannot answer: app.search (owner
 * `cloud:planetscale`) and app.list over both owners (scope all, default).
 * Undefined = route the read normally.
 */
export const appStoreRead = (def: CloudOpDef, principal: Principal, params: unknown) =>
  Effect.gen(function* () {
    if (def.owner === "cloud:planetscale") {
      const d = Schema.decodeUnknownExit(AppSearch.params)(params ?? {})
      if (Exit.isFailure(d)) return yield* new BadRequest({ code: "validation.invalid", message: `invalid params: ${String(d.cause)}` })
      const r = yield* Effect.promise(() => searchApps(env, d.value))
      if (!r.ok) return yield* unreachable(r.message)
      return { value: r.value, stream: "planetscale:apps", revision: "0" }
    }
    if (def.name !== "app.list") return undefined
    const scope = (params as { scope?: unknown } | null)?.scope
    if (scope === "user" || scope === "team") return undefined
    const user = yield* readFrom("cloud:UserDO", principal, "app.list", { scope: "user" })
    if (!user.ok) return yield* unreachable(user.message)
    // The team part is best effort: a caller who is not a member still sees their own installs.
    const team = yield* Effect.orElseSucceed(readFrom("cloud:TeamDO", principal, "app.list", { scope: "team" }), () => undefined)
    const u = user.value as InstallsValue
    const t = team?.ok ? (team.value as InstallsValue) : undefined
    return {
      value: {
        installs: [...u.installs, ...(t?.installs ?? [])],
        approvals: [...u.approvals, ...(t?.approvals ?? [])],
        policy: t?.policy ?? null,
        revisions: { user: user.revision, ...(t && team?.ok ? { team: team.revision } : {}) }
      },
      stream: `user:${principal.user}`,
      revision: user.revision
    }
  })
