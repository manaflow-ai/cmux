import { env as workerEnv } from "cloudflare:workers"
import type { Principal } from "@cmux/ownership"
import { AppSearch, BadRequest, type AppInstall, type CloudOpDef, type DoOwner, type ResolvedRelease } from "@cmux/protocol"
import { Effect, Exit, Schema } from "effect"
import { defaultApps } from "./app-do.ts"
import { searchApps } from "./app-store.ts"
import type { DefaultPref } from "./domains/app-installs.ts"
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
 * First-party apps installed for everyone by default, as install records:
 * every configured default the user has neither installed explicitly nor
 * removed, while AppDO lists it as first-party with a live version. Granted
 * scopes are the version's required ones (first-party apps need no consent
 * sheet); optional scopes need the user's install.
 */
const defaultInstalls = async (prefs: Record<string, DefaultPref>, installed: ReadonlySet<string>): Promise<Array<AppInstall>> => {
  const ids = [...defaultApps(env)].filter((id) => !installed.has(id) && (prefs[id]?.removed_at ?? null) === null)
  const found = await Promise.allSettled(ids.map((id) => env.APP_DO.get(env.APP_DO.idFromName(id)).release(id, { range: "*" }) as Promise<ResolvedRelease | null>))
  return found.flatMap((f): Array<AppInstall> => {
    const r = f.status === "fulfilled" ? f.value : null
    if (!r || r.tier !== "first-party" || r.yanked) return []
    return [{
      app: r.app,
      scope: "user",
      version: r.version,
      version_range: "*",
      tier: r.tier,
      scopes_granted: [...r.scopes],
      version_scopes: [...r.scopes],
      version_optional_scopes: [...r.optional_scopes],
      bundle_url: r.bundle_url,
      bundle_sha256: r.bundle_sha256,
      app_revision: r.app_revision,
      installed_by: "default",
      installed_at: 0,
      updated_at: 0,
      hidden: prefs[r.app]?.hidden ?? false,
      by_default: true
    }]
  })
}

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
      // A revoked install is refused here too (UserDO answers for its grant).
      yield* principalFor(def.owner, principal)
      const r = yield* Effect.promise(() => searchApps(env, d.value))
      if (!r.ok) return yield* unreachable(r.message)
      return { value: r.value, stream: "planetscale:apps", revision: "0" }
    }
    if (def.name !== "app.list") return undefined
    const scope = (params as { scope?: unknown } | null)?.scope
    if (scope === "team") return undefined
    const user = yield* readFrom("cloud:UserDO", principal, "app.list", { scope: "user" })
    if (!user.ok) return yield* unreachable(user.message)
    const u = user.value as InstallsValue & { default_prefs?: Record<string, DefaultPref> }
    const installs = [...u.installs, ...(yield* Effect.promise(() => defaultInstalls(u.default_prefs ?? {}, new Set(u.installs.map((i) => (i as { app: string }).app)))))]
    if (scope === "user") return { value: { installs, approvals: u.approvals, policy: null, revisions: { user: user.revision } }, stream: `user:${principal.user}`, revision: user.revision }
    // The team part is best effort: a caller who is not a member still sees their own installs.
    const team = yield* Effect.orElseSucceed(readFrom("cloud:TeamDO", principal, "app.list", { scope: "team" }), () => undefined)
    const t = team?.ok ? (team.value as InstallsValue) : undefined
    return {
      value: {
        installs: [...installs, ...(t?.installs ?? [])],
        approvals: [...u.approvals, ...(t?.approvals ?? [])],
        policy: t?.policy ?? null,
        revisions: { user: user.revision, ...(t && team?.ok ? { team: team.revision } : {}) }
      },
      stream: `user:${principal.user}`,
      revision: user.revision
    }
  })
