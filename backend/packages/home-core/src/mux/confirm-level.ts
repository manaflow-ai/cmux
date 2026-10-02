import type { Principal, ReduceContext, ReduceResult, RowWrite } from "../conversation/engine-types.ts"
import { rowsOf } from "../conversation/engine-types.ts"

/**
 * The per-user level of in-app confirmation for actions asked by text
 * (decision 2026-10-02, home-messaging.md section 19):
 * - `strict` (default): destructive, money, send-external, access, irreversible;
 * - `destructive-only`: destructive and irreversible only;
 * - `off`: no confirmation.
 * A safer level applies at once. A riskier level needs a second, explicit
 * in-app confirmation from the owner's own app (origin user, never a text),
 * within 5 minutes. A team or MDM policy lock wins over both and names who
 * locked it. Every change is written to an audit table. MuxDO hosts it; pure.
 */
export type ConfirmLevel = "strict" | "destructive-only" | "off"
export const CONFIRM_LEVELS: ReadonlyArray<ConfirmLevel> = ["strict", "destructive-only", "off"]
/** Higher = riskier. */
const RISK_RANK: Readonly<Record<ConfirmLevel, number>> = { strict: 0, "destructive-only": 1, off: 2 }
export const isRiskier = (to: ConfirmLevel, from: ConfirmLevel) => RISK_RANK[to] > RISK_RANK[from]

export const LEVEL_CHANGE_TTL_MS = 5 * 60_000
export const TABLE_LEVEL_AUDIT = "level_audit"
export const MAX_AUDIT_ROWS = 100

export interface LevelLock {
  readonly level: ConfirmLevel
  readonly by: "team_policy" | "mdm"
  /** Shown in Settings: the team name or the managing organization. */
  readonly name: string
  readonly at: number
}

export interface PendingLevelChange {
  readonly id: string
  readonly to: ConfirmLevel
  readonly requested_by: string
  readonly expires_at: number
}

export interface LevelHeadPart {
  readonly agent: string | null
  readonly owner_user: string | null
  readonly text_confirm_level?: ConfirmLevel
  /** Legacy boolean setting (before levels): "destructive" = on, "off" = off. */
  readonly text_confirm?: "destructive" | "off"
  readonly text_confirm_lock?: LevelLock | null
  readonly level_change?: PendingLevelChange | null
  readonly level_audit_n?: number
}

/** The level in effect: a lock wins, then the stored level, then the migrated boolean (on -> strict, off -> off). */
export const levelOf = (head: LevelHeadPart): ConfirmLevel =>
  head.text_confirm_lock?.level ?? head.text_confirm_level ?? (head.text_confirm === "off" ? "off" : "strict")

export interface AuditRow {
  readonly at: number
  readonly kind: "set" | "raise_requested" | "raise_confirmed" | "raise_declined" | "lock" | "unlock"
  readonly by: string
  readonly from: ConfirmLevel
  readonly to: ConfirmLevel
  readonly lock?: { readonly by: LevelLock["by"]; readonly name: string }
}

export const LEVEL_OPS = new Set(["mux.text_confirm.level.set", "mux.text_confirm.level.confirm", "mux.text_confirm.lock"])

/** Installs that are a person's app (never a daemon, CLI or VM install, where a chief may run). */
const USER_APP_KINDS: ReadonlySet<string> = new Set(["mac", "ios", "web"])
const userOf = (p: Principal) => (p.user ? (p.user.startsWith("user_") ? p.user : `user_${p.user}`) : null)

export const isOwnerApp = (head: { readonly owner_user: string | null }, p: Principal): boolean =>
  (p.kind === "session" || (p.kind === "install" && !p.agent && USER_APP_KINDS.has(p.install_kind ?? ""))) &&
  head.owner_user !== null &&
  userOf(p) === head.owner_user

/** Set and confirm: only the owner's own app. Lock: only a system principal (team policy or MDM, pushed by the Worker). */
export const authorizeLevel = (head: LevelHeadPart, op: string, p: Principal): boolean =>
  op === "mux.text_confirm.lock" ? p.kind === "system" : isOwnerApp(head, p)

type Params = Readonly<Record<string, unknown>>
const isLevel = (v: unknown): v is ConfirmLevel => typeof v === "string" && (CONFIRM_LEVELS as ReadonlyArray<string>).includes(v)

export const reduceLevel = <H extends LevelHeadPart>(head: H, op: string, params: Params, ctx: ReduceContext): ReduceResult<H> => {
  const refuse = (code: string): ReduceResult<H> => ({ ok: false, code, message: code })
  const rows = rowsOf(ctx)
  const current = levelOf(head)
  const actor = ctx.principal.kind === "system" ? "system" : (userOf(ctx.principal) ?? "unknown")
  const audit = (row: AuditRow): ReadonlyArray<RowWrite> => {
    const n = (head.level_audit_n ?? 0) + 1
    const old = rows.range(TABLE_LEVEL_AUDIT, { before: n - MAX_AUDIT_ROWS + 1, limit: 1, desc: true })
    return [{ table: TABLE_LEVEL_AUDIT, op: "upsert", key: `a${n}`, n, row }, ...old.map((r) => ({ table: TABLE_LEVEL_AUDIT, op: "delete" as const, key: r.key }))]
  }
  const nextN = { level_audit_n: (head.level_audit_n ?? 0) + 1 }
  switch (op) {
    case "mux.text_confirm.level.set": {
      // A person's own tap in the app; never automation or a text acting with their identity.
      if (ctx.origin !== "user") return refuse("forbidden")
      const to = params.level
      if (!isLevel(to)) return refuse("invalid_params")
      const lock = head.text_confirm_lock
      if (lock) return refuse(to === lock.level ? "text_confirm.unchanged" : "text_confirm.locked")
      if (to === current) return { ok: true, state: head, value: { level: current }, changed: false }
      if (!isRiskier(to, current)) {
        const state = { ...head, text_confirm_level: to, level_change: null, ...nextN }
        return { ok: true, state, value: { level: to }, writes: audit({ at: ctx.now, kind: "set", by: actor, from: current, to }) }
      }
      const change: PendingLevelChange = { id: ctx.newId("lvl"), to, requested_by: actor, expires_at: ctx.now + LEVEL_CHANGE_TTL_MS }
      const state = { ...head, level_change: change, ...nextN }
      return { ok: true, state, value: { level: current, pending: change }, writes: audit({ at: ctx.now, kind: "raise_requested", by: actor, from: current, to }) }
    }
    case "mux.text_confirm.level.confirm": {
      if (ctx.origin !== "user") return refuse("forbidden")
      const change = head.level_change
      if (!change || change.id !== params.change) return refuse("text_confirm.no_pending_change")
      if (typeof params.approve !== "boolean") return refuse("invalid_params")
      if (ctx.now >= change.expires_at) return { ok: true, state: { ...head, level_change: null }, value: { level: current, expired: true } }
      if (head.text_confirm_lock) return { ok: true, state: { ...head, level_change: null }, value: { level: current, locked: true } }
      if (!params.approve) {
        const state = { ...head, level_change: null, ...nextN }
        return { ok: true, state, value: { level: current }, writes: audit({ at: ctx.now, kind: "raise_declined", by: actor, from: current, to: change.to }) }
      }
      const state = { ...head, text_confirm_level: change.to, level_change: null, ...nextN }
      return { ok: true, state, value: { level: change.to }, writes: audit({ at: ctx.now, kind: "raise_confirmed", by: actor, from: current, to: change.to }) }
    }
    case "mux.text_confirm.lock": {
      // Team policy or MDM: `level` locks it (and clears a pending raise); null unlocks and keeps the locked level.
      const { level, by, name } = params
      if (level === null) {
        if (!head.text_confirm_lock) return { ok: true, state: head, value: { level: current }, changed: false }
        const state = { ...head, text_confirm_level: current, text_confirm_lock: null, ...nextN }
        return { ok: true, state, value: { level: current }, writes: audit({ at: ctx.now, kind: "unlock", by: actor, from: current, to: current }) }
      }
      if (!isLevel(level) || (by !== "team_policy" && by !== "mdm") || typeof name !== "string" || name.length === 0 || name.length > 120) return refuse("invalid_params")
      const lock: LevelLock = { level, by, name, at: ctx.now }
      const same = head.text_confirm_lock && head.text_confirm_lock.level === level && head.text_confirm_lock.by === by && head.text_confirm_lock.name === name
      if (same) return { ok: true, state: head, value: { level }, changed: false }
      const state = { ...head, text_confirm_lock: lock, level_change: null, ...nextN }
      return { ok: true, state, value: { level, lock }, writes: audit({ at: ctx.now, kind: "lock", by: actor, from: current, to: level, lock: { by, name } }) }
    }
    default:
      return refuse("invalid_params")
  }
}
