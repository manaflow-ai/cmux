import type { Principal, ReduceContext, ReduceResult, RowWrite } from "../conversation/engine-types.ts"
import { rowsOf } from "../conversation/engine-types.ts"

/**
 * In-app confirmation for risky actions a Chief was asked to do by text
 * (decision 2026-10-02, home-messaging.md section 19). The Chief may do
 * everything by default; when a request arrived over the text channel and the
 * action is destructive or irreversible, the Chief first records a pending
 * confirmation here and the user approves or declines it in the app (a
 * session or install of the chief's owner, never a text). An approval is
 * single use: the Chief consumes it when it runs the action. The owner can
 * turn the rule off (`text_confirm: off`). MuxDO hosts it; pure.
 */
export const TABLE_CONFIRM = "confirm"
export const CONFIRM_TTL_MS = 15 * 60_000
/** Live pending confirmations per chief (counted among the newest rows); more are refused until some are decided or expire. */
export const MAX_PENDING_CONFIRMS = 20
const PENDING_SCAN = 64

export type RiskClass = "read" | "mutate-own" | "mutate-shared" | "execute" | "send-external" | "money" | "destructive"
export type Channel = "app" | "text"
export type TextConfirm = "destructive" | "off"

/** The decision rule: which actions need the in-app confirmation. */
export const needsConfirmation = (input: { readonly channel: Channel; readonly risk: RiskClass; readonly irreversible?: boolean; readonly setting?: TextConfirm }): boolean =>
  input.channel === "text" && (input.setting ?? "destructive") !== "off" && (input.risk === "destructive" || input.risk === "money" || input.irreversible === true)

export type ConfirmState = "pending" | "approved" | "declined" | "consumed" | "expired"

export interface Confirmation {
  readonly id: string
  /** The catalog op the Chief wants to run and a fingerprint of its params (the approval is for exactly this). */
  readonly op: string
  readonly params_hash: string
  readonly risk: RiskClass
  /** One line for the approval card, written by the Chief; never secrets. */
  readonly summary: string
  /** The text message that asked for it: conversation and seq. */
  readonly source: { readonly conversation: string; readonly seq: number }
  readonly state: ConfirmState
  readonly created_at: number
  readonly expires_at: number
  readonly decided_by?: string
  readonly decided_at?: number
}

export interface ConfirmHeadPart {
  readonly agent: string | null
  readonly owner_user: string | null
  readonly text_confirm?: TextConfirm
  readonly confirm_n?: number
}

type Params = Readonly<Record<string, unknown>>
const str = (v: unknown, max = 256): v is string => typeof v === "string" && v.length > 0 && v.length <= max
const RISKS = new Set<RiskClass>(["read", "mutate-own", "mutate-shared", "execute", "send-external", "money", "destructive"])

export const CONFIRM_OPS = new Set(["mux.confirm.request", "mux.confirm.decide", "mux.confirm.consume", "mux.text_confirm.set"])

const userOf = (p: Principal) => (p.user ? (p.user.startsWith("user_") ? p.user : `user_${p.user}`) : null)

/** Who may call each op: the chief requests and consumes; only the owner's app decides or changes the setting. */
export const authorizeConfirm = (head: ConfirmHeadPart, op: string, p: Principal): boolean => {
  const isChief = p.kind === "agent" && p.agent !== undefined && p.agent === head.agent
  const isOwnerApp = (p.kind === "session" || p.kind === "install") && head.owner_user !== null && userOf(p) === head.owner_user
  if (op === "mux.confirm.request" || op === "mux.confirm.consume") return isChief
  if (op === "mux.confirm.decide" || op === "mux.text_confirm.set") return isOwnerApp
  return false
}

const write = (c: Confirmation, n: number): RowWrite => ({ table: TABLE_CONFIRM, op: "upsert", key: c.id, n, row: c })

export const reduceConfirm = <H extends ConfirmHeadPart>(head: H, op: string, params: Params, ctx: ReduceContext): ReduceResult<H> => {
  const refuse = (code: string): ReduceResult<H> => ({ ok: false, code, message: code })
  const rows = rowsOf(ctx)
  const load = (id: unknown) => (str(id, 64) ? rows.get<Confirmation>(TABLE_CONFIRM, id) : undefined)
  const live = (c: Confirmation): Confirmation => (c.state === "pending" && ctx.now >= c.expires_at ? { ...c, state: "expired" } : c)
  switch (op) {
    case "mux.text_confirm.set": {
      const { setting } = params
      if (setting !== "destructive" && setting !== "off") return refuse("invalid_params")
      if ((head.text_confirm ?? "destructive") === setting) return { ok: true, state: head, value: { setting }, changed: false }
      return { ok: true, state: { ...head, text_confirm: setting }, value: { setting } }
    }
    case "mux.confirm.request": {
      const { op: action, params_hash, risk, summary, source } = params
      const src = source as { conversation?: unknown; seq?: unknown } | null
      if (!str(action, 128) || !str(params_hash, 128) || !RISKS.has(risk as RiskClass) || !str(summary, 280)) return refuse("invalid_params")
      if (!src || !str(src.conversation, 128) || !Number.isSafeInteger(src.seq) || (src.seq as number) < 1) return refuse("invalid_params")
      // Bounded scan of the newest rows: expired ones stop counting without any cleanup op.
      const pending = rows.range<Confirmation>(TABLE_CONFIRM, { limit: PENDING_SCAN, desc: true }).filter((r) => live(r.row).state === "pending").length
      if (pending >= MAX_PENDING_CONFIRMS) return refuse("confirm.too_many")
      const n = (head.confirm_n ?? 0) + 1
      const c: Confirmation = {
        id: ctx.newId("cfm"),
        op: action,
        params_hash,
        risk: risk as RiskClass,
        summary,
        source: { conversation: src.conversation, seq: src.seq as number },
        state: "pending",
        created_at: ctx.now,
        expires_at: ctx.now + CONFIRM_TTL_MS
      }
      return { ok: true, state: { ...head, confirm_n: n }, value: c, writes: [write(c, n)] }
    }
    case "mux.confirm.decide": {
      const stored = load(params.confirm)
      if (!stored) return refuse("confirm.unknown")
      if (typeof params.approve !== "boolean") return refuse("invalid_params")
      const c = live(stored.row)
      if (c.state !== "pending") return refuse(c.state === "expired" ? "confirm.expired" : "confirm.decided")
      const next: Confirmation = { ...c, state: params.approve ? "approved" : "declined", decided_by: userOf(ctx.principal)!, decided_at: ctx.now }
      return { ok: true, state: head, value: next, writes: [write(next, stored.n ?? 0)] }
    }
    case "mux.confirm.consume": {
      // The chief proves it runs exactly the approved action: same op and params fingerprint, once.
      const stored = load(params.confirm)
      if (!stored) return refuse("confirm.unknown")
      const c = live(stored.row)
      if (c.state !== "approved") return refuse(c.state === "pending" ? "confirm.pending" : c.state === "expired" ? "confirm.expired" : "confirm.not_approved")
      if (params.op !== c.op || params.params_hash !== c.params_hash) return refuse("confirm.mismatch")
      if (ctx.now >= c.expires_at + CONFIRM_TTL_MS) return refuse("confirm.expired")
      const next: Confirmation = { ...c, state: "consumed" }
      return { ok: true, state: head, value: next, writes: [write(next, stored.n ?? 0)] }
    }
    default:
      return refuse("invalid_params")
  }
}
