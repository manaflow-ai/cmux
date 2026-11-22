import type { OutboxItem, ReduceContext, ReduceResult } from "../conversation/engine-types.ts"
import { effectiveLock, isLevel, type ConfirmLevel, type LevelLocks } from "./confirm-level.ts"

/**
 * Each chief's copy of its owner's text confirmation level. UserDO owns the
 * level (`user/text-confirm-user.ts`) and pushes `mux.text_confirm.level.sync`
 * (newest `rev` wins, so duplicates and reordering are harmless). Chiefs that
 * stored a level of their own before the move send it once to UserDO with
 * `mux.text_confirm.migrate`; UserDO keeps the safest of them.
 */
export interface LevelProjectionPart {
  readonly owner_user: string | null
  readonly user_level?: { readonly level: ConfirmLevel; readonly rev: number }
  /** Per-chief fields before the level moved to UserDO (read for migration only). */
  readonly text_confirm?: "destructive" | "off"
  readonly text_confirm_level?: ConfirmLevel
  readonly text_confirm_lock?: LevelLocks | null
  readonly level_migrated?: boolean
}

export const PROJECTION_OPS = new Set(["mux.text_confirm.level.sync", "mux.text_confirm.migrate"])

const legacyLevel = (h: LevelProjectionPart): ConfirmLevel | null => {
  const lock = effectiveLock(h.text_confirm_lock)
  if (lock) return lock.level
  if (h.text_confirm_level) return h.text_confirm_level
  if (h.text_confirm !== undefined) return h.text_confirm === "off" ? "off" : "strict"
  return null
}

/** The level this chief applies: its owner's (from UserDO), else its own pre-migration value, else strict. */
export const chiefLevelOf = (h: LevelProjectionPart): ConfirmLevel => h.user_level?.level ?? legacyLevel(h) ?? "strict"

export const reduceProjection = <H extends LevelProjectionPart>(head: H, op: string, params: Readonly<Record<string, unknown>>, ctx: ReduceContext): ReduceResult<H> => {
  const refuse = (code: string): ReduceResult<H> => ({ ok: false, code, message: code })
  if (op === "mux.text_confirm.level.sync") {
    const { level, rev } = params
    if (!isLevel(level) || !Number.isSafeInteger(rev) || (rev as number) < 1) return refuse("invalid_params")
    if (head.user_level && head.user_level.rev >= (rev as number)) return { ok: true, state: head, value: head.user_level, changed: false }
    const user_level = { level, rev: rev as number }
    return { ok: true, state: { ...head, user_level }, value: user_level }
  }
  // mux.text_confirm.migrate: once per chief, the old per-chief value goes to the owner's UserDO.
  if (head.level_migrated || head.owner_user === null) return { ok: true, state: head, value: null, changed: false }
  const legacy = legacyLevel(head)
  const outbox: ReadonlyArray<OutboxItem> = legacy
    ? [{ kind: "user.text_confirm.migrate", entity: `migrate:${ctx.tx}`, payload: { level: legacy }, target: { class: "UserDO", name: head.owner_user } }]
    : []
  const { text_confirm: _a, text_confirm_level: _b, text_confirm_lock: _c, ...rest } = head
  return { ok: true, state: { ...rest, level_migrated: true } as H, value: { migrated: legacy }, outbox }
}
