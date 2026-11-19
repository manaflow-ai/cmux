import type { Principal } from "@cmux/ownership"
import { appkv } from "@cmux/home-core"
import type { ReadResult } from "./owner-do.ts"
import type { SecondaryStream } from "./secondary-stream.ts"
import { isMachineInstallKind } from "./machine-installs.ts"

/**
 * Synced app storage (`storage:synced`, cmuxterm-hq#12221) on UserDO's stream `appkv:<user>`.
 * Only the person reads or writes it: their Stack session or one of their own client installs
 * (Mac, iOS, CLI, daemon) whose grant covers the op. A chief token and a machine install (a Cloud
 * VM, `vm` or `team-vm`) never do, as with the inbox (`maySubscribe` below mirrors the inbox's).
 */
export const appKvMaySubscribe = (principal: Principal, entity: string, installKind: (install: string) => string | undefined): boolean =>
  principal.user === entity && principal.agent === undefined && !isMachineInstallKind(principal.install_kind) && !(principal.install !== undefined && isMachineInstallKind(installKind(principal.install)))

/** `appkv.list`: every row in revision order, a page at a time (a snapshot carries only the newest rows). */
export const readAppKvOp = (stream: SecondaryStream<appkv.AppKvHead>, entity: string, op: string, params: Record<string, unknown>): ReadResult => {
  if (op !== "appkv.list") return { ok: false, code: "validation.invalid", message: `unknown appkv read ${op}` }
  const after = params.after_revision
  if (after !== undefined && (typeof after !== "number" || !Number.isSafeInteger(after) || after < 0)) return { ok: false, code: "validation.invalid", message: "after_revision must be a revision" }
  const limit = typeof params.limit === "number" && params.limit > 0 ? Math.min(Math.floor(params.limit), appkv.APPKV_PAGE_LIMIT) : appkv.APPKV_PAGE_LIMIT
  const engine = stream.open(entity)
  const rows = engine.rows.range<appkv.AppKvRow>(appkv.TABLE_ITEM, { after: (after as number | undefined) ?? 0, limit: limit + 1 }).map((r) => r.row)
  const page = rows.slice(0, limit)
  const more = rows.length > limit
  return { ok: true, value: { rows: page, next_after_revision: more ? page[page.length - 1]!.revision : null }, revision: String(engine.currentSeq) }
}
