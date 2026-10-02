import type { Principal } from "@cmux/ownership"
import { APP_ID_PATTERN, AppInfo, type ResolvedRelease } from "@cmux/protocol"
import { releaseSelector, type AppsSlice } from "./domains/app-installs.ts"
import { decodeParams } from "./domains/common.ts"
import { listingView, makeAppDomain, resolveRelease, type AppConfig, type AppState } from "./domains/app.ts"
import type { Env } from "./env.ts"
import { OwnerDO, type ReadResult } from "./owner-do.ts"

/** Deployment facts the AppDO reducer depends on (never request data). */
export const appConfig = (env: Env): AppConfig => ({
  environment: env.ENVIRONMENT,
  staff: new Set((env.APP_STORE_STAFF ?? "").split(",").map((s) => s.trim()).filter(Boolean))
})

/**
 * AppDO: one object per app id (`idFromName(<app id>)`), the single writer of
 * that app's listing, versions, tier and yanks (spec app-platform.md section
 * 11). Projects into `apps` and `app_versions` through the outbox.
 */
export class AppDO extends OwnerDO<AppState> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env, makeAppDomain(appConfig(env)), "app", (p) => ({
      // Publishers are public; installs, grants and Stack ids are not.
      identity: p.user ? `user:${p.user}` : p.identity,
      ...(p.kind ? { kind: p.kind } : {}),
      ...(p.user ? { user: p.user } : {}),
      ...(p.team ? { team: p.team } : {})
    }))
  }

  protected read(state: AppState, op: string, params: unknown, _principal: Principal): ReadResult {
    if (op !== "app.info") return { ok: false, code: "validation.invalid", message: `unknown read ${op}` }
    const d = decodeParams<typeof AppInfo.params.Type>(AppInfo, params)
    if (!d.ok) return d
    if (d.value.version !== undefined && !state.versions[d.value.version]) return { ok: false, code: "selector.not_found", message: `version ${d.value.version} not found` }
    const view = listingView(state, 0, d.value.version === undefined ? {} : { only: d.value.version })
    return view && view.id === d.value.app ? { ok: true, value: view, revision: "" } : { ok: false, code: "selector.not_found", message: `app ${d.value.app} not found` }
  }

  /** Reads of an id this object never served answer not found without creating storage. */
  override async readOp(entity: string, principal: Principal, op: string, params: unknown): Promise<ReadResult> {
    const row = this.ctx.storage.sql.exec<{ entity: string }>(`SELECT entity FROM do_entity WHERE id = 1`).toArray()[0]
    if (!row || row.entity !== entity) return { ok: false, code: "selector.not_found", message: `app ${entity} not found` }
    return super.readOp(entity, principal, op, params)
  }

  /** No live stream yet: clients learn about new versions from UserDO/TeamDO pushes (spec section 9). */
  protected maySubscribe(): boolean {
    return false
  }

  /** Every op learns which app this object is, from the binding, never from the client. */
  protected override async resolve(entity: string): Promise<unknown> {
    return { entity }
  }

  /**
   * For UserDO and TeamDO before an install, update or approval: the release
   * a selector resolves to, pinned by this object's sequence. Never creates
   * storage for an id this object has not served.
   */
  async release(entity: string, sel: { version?: string; range?: string }): Promise<ResolvedRelease | null> {
    const row = this.ctx.storage.sql.exec<{ entity: string }>(`SELECT entity FROM do_entity WHERE id = 1`).toArray()[0]
    if (!row || row.entity !== entity) return null
    const engine = this.bind(entity)
    return resolveRelease(engine.currentState, engine.currentSeq, sel)
  }
}

/**
 * The owner-side release lookup for UserDO and TeamDO (OwnerDO `resolve`):
 * null for every app op that names no resolvable release, so a client can
 * never pass its own `resolved` through; undefined for other ops.
 */
export const resolveAppRelease = async (env: Env, slice: AppsSlice | undefined, op: string, params: unknown): Promise<ResolvedRelease | null | undefined> => {
  if (!op.startsWith("app.")) return undefined
  const sel = releaseSelector(slice, op, params)
  if (!sel || !APP_ID_PATTERN.test(sel.app)) return null
  const stub = env.APP_DO.get(env.APP_DO.idFromName(sel.app))
  return (await stub.release(sel.app, { ...(sel.version ? { version: sel.version } : {}), ...(sel.range ? { range: sel.range } : {}) })) as ResolvedRelease | null
}
