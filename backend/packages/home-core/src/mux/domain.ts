import type { Domain, Principal, Reject, ReduceResult, RowWrite } from "../conversation/engine-types.ts"
import type { ConfirmLevel, LevelLocks } from "./confirm-level.ts"
import { PROJECTION_OPS, reduceProjection } from "./level-projection.ts"
import { authorizeConfirm, CONFIRM_OPS, reduceConfirm } from "./text-confirm.ts"

/**
 * MuxDO, one per chief (home-messaging.md sections 3 and 4.3): the chief's
 * wake queue. ConversationDO outboxes send `mux.wake`; the brain host (the
 * cloud loop in this object, or a local brain host subscribed to `mux:<agent>`)
 * consumes the queue and acks per conversation. Wake items are rows (table
 * `wake`, key `<conversation>:<seq>`, n = arrival order) so a chief that was
 * offline for a week does not grow one JSON value.
 */
export const TABLE_WAKE = "wake"
/** Pending wakes kept per conversation; older ones drop (the brain reads history from the cursor anyway). */
export const MAX_PENDING_PER_CONVERSATION = 200
/** Conversations tracked in the head; idle ones (nothing pending) are evicted oldest first. */
export const MAX_TRACKED_CONVERSATIONS = 500

export type WakeReason = "dm" | "mention" | "reply" | "owner"

export interface MuxHead {
  readonly agent: string | null
  readonly owner_user: string | null
  readonly brain: "local" | "cloud"
  readonly brain_host: string | null
  /** Wake rows not yet acked. */
  readonly pending: number
  readonly next_n: number
  /** Per conversation: highest acked seq (wakes at or below it are ignored) and pending seqs, ascending. */
  readonly queues: Readonly<Record<string, ConversationQueue>>
  /** The owner's text confirmation level, pushed by UserDO (level-projection.ts). */
  readonly user_level?: { readonly level: ConfirmLevel; readonly rev: number }
  /** Per-chief fields before the level moved to UserDO; `mux.text_confirm.migrate` sends them once. */
  readonly text_confirm_level?: ConfirmLevel
  readonly text_confirm?: "destructive" | "off"
  readonly text_confirm_lock?: LevelLocks | null
  readonly level_migrated?: boolean
  readonly confirm_n?: number
}

export interface ConversationQueue {
  readonly cursor: number
  readonly pending: ReadonlyArray<number>
  readonly touched: number
}

export interface WakeItem {
  readonly conversation: string
  readonly seq: number
  readonly reason: WakeReason
  readonly at: number
}

export const INITIAL_MUX_HEAD: MuxHead = { agent: null, owner_user: null, brain: "local", brain_host: null, pending: 0, next_n: 1, queues: {} }

type Params = Readonly<Record<string, unknown>>

const refuse = (code: string, message = code): ReduceResult<MuxHead> => ({ ok: false, code, message })
const str = (v: unknown, max = 128): v is string => typeof v === "string" && v.length > 0 && v.length <= max
const seqOf = (v: unknown): v is number => Number.isSafeInteger(v) && (v as number) > 0
const REASONS = new Set<WakeReason>(["dm", "mention", "reply", "owner"])

/** The chief itself (agent token) or a system op of a DO. */
const isChief = (head: MuxHead, p: Principal) => p.kind === "agent" && p.agent !== undefined && p.agent === head.agent
const isOwner = (head: MuxHead, p: Principal) => (p.kind === "session" || p.kind === "install") && p.user !== undefined && p.user === head.owner_user

/**
 * Keeps the head bounded: beyond MAX_TRACKED_CONVERSATIONS, conversations with
 * nothing pending are forgotten oldest first. A forgotten cursor only means a
 * very late duplicate wake could queue again; the drain's idempotency key
 * (`wake:<conversation>:<seq>`) already stops duplicates inside the ledger window.
 */
const bounded = (queues: Readonly<Record<string, ConversationQueue>>): Readonly<Record<string, ConversationQueue>> => {
  const entries = Object.entries(queues)
  if (entries.length <= MAX_TRACKED_CONVERSATIONS) return queues
  const idle = entries.filter(([, q]) => q.pending.length === 0).sort((a, b) => a[1].touched - b[1].touched)
  const drop = new Set(idle.slice(0, entries.length - MAX_TRACKED_CONVERSATIONS).map(([c]) => c))
  return Object.fromEntries(entries.filter(([c]) => !drop.has(c)))
}

export const muxDomain: Domain<MuxHead, Params> = {
  initial: () => INITIAL_MUX_HEAD,
  authorize: (head, op, _params, p): Reject | undefined => {
    if (CONFIRM_OPS.has(op)) return authorizeConfirm(head, op, p) ? undefined : { code: "forbidden", message: `${op} is not allowed for this caller` }
    if (PROJECTION_OPS.has(op)) return p.kind === "system" ? undefined : { code: "forbidden", message: `${op} is a system op` }
    const ok =
      op === "mux.bind" || op === "mux.wake"
        ? p.kind === "system"
        : op === "mux.ack"
          ? isChief(head, p) || p.kind === "system"
          : op === "mux.configure"
            ? isOwner(head, p)
            : false
    return ok ? undefined : { code: "forbidden", message: `${op} is not allowed for this caller` }
  },
  reduce: (head, op, params, ctx) => {
    if (CONFIRM_OPS.has(op)) return head.agent === null ? refuse("mux.unbound") : reduceConfirm(head, op, params, ctx)
    if (PROJECTION_OPS.has(op)) return head.agent === null ? refuse("mux.unbound") : reduceProjection(head, op, params, ctx)
    switch (op) {
      case "mux.bind": {
        const { agent, owner_user, brain } = params
        if (!str(agent) || !agent.startsWith("agent_") || !str(owner_user) || (brain !== "local" && brain !== "cloud")) return refuse("invalid_params")
        if (head.agent !== null) {
          if (head.agent !== agent || head.owner_user !== owner_user) return refuse("mux.bound", "this object belongs to another chief")
          return { ok: true, state: head, value: head, changed: false }
        }
        const next: MuxHead = { ...head, agent, owner_user, brain }
        return { ok: true, state: next, value: next }
      }
      case "mux.wake": {
        const { conversation, seq, reason } = params
        if (head.agent === null) return refuse("mux.unbound")
        if (!str(conversation) || !seqOf(seq) || !REASONS.has(reason as WakeReason)) return refuse("invalid_params")
        const key = `${conversation}:${seq}`
        const queue = head.queues[conversation] ?? { cursor: 0, pending: [], touched: 0 }
        if (seq <= queue.cursor || queue.pending.includes(seq)) return { ok: true, state: head, value: null, changed: false }
        const item: WakeItem = { conversation, seq, reason: reason as WakeReason, at: ctx.now }
        const pending = [...queue.pending, seq].sort((a, b) => a - b)
        const dropped = pending.slice(0, Math.max(0, pending.length - MAX_PENDING_PER_CONVERSATION))
        const writes: Array<RowWrite> = [
          { table: TABLE_WAKE, op: "upsert", key, n: head.next_n, row: item },
          ...dropped.map((s) => ({ table: TABLE_WAKE, op: "delete" as const, key: `${conversation}:${s}` }))
        ]
        const queues = bounded({ ...head.queues, [conversation]: { cursor: queue.cursor, pending: pending.slice(dropped.length), touched: ctx.now } })
        const next = { ...head, pending: head.pending + 1 - dropped.length, next_n: head.next_n + 1, queues }
        return { ok: true, state: next, value: item, writes }
      }
      case "mux.ack": {
        const { conversation, seq } = params
        if (!str(conversation) || !seqOf(seq)) return refuse("invalid_params")
        const queue = head.queues[conversation] ?? { cursor: 0, pending: [], touched: 0 }
        if (seq <= queue.cursor) return { ok: true, state: head, value: { cursor: queue.cursor }, changed: false }
        // Exact keys from the head: no scan, every acked row goes.
        const acked = queue.pending.filter((s) => s <= seq)
        const cleared: Array<RowWrite> = acked.map((s) => ({ table: TABLE_WAKE, op: "delete" as const, key: `${conversation}:${s}` }))
        const queues = bounded({ ...head.queues, [conversation]: { cursor: seq, pending: queue.pending.filter((s) => s > seq), touched: ctx.now } })
        const next = { ...head, pending: Math.max(0, head.pending - acked.length), queues }
        return { ok: true, state: next, value: { cursor: seq, cleared: acked.length }, writes: cleared }
      }
      case "mux.configure": {
        const { brain, brain_host } = params
        if (brain !== "local" && brain !== "cloud") return refuse("invalid_params")
        if (brain_host !== undefined && brain_host !== null && !str(brain_host)) return refuse("invalid_params")
        const next: MuxHead = { ...head, brain, brain_host: brain === "local" ? ((brain_host as string | undefined) ?? head.brain_host) : null }
        return { ok: true, state: next, value: next }
      }
      default:
        return refuse("invalid_params", `unknown op ${op}`)
    }
  }
}
