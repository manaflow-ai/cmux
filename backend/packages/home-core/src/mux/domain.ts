import type { Domain, Principal, Reject, ReduceResult, RowWrite } from "../conversation/engine-types.ts"

/**
 * MuxDO, one per chief (home-messaging.md sections 3 and 4.3): the chief's
 * wake queue. ConversationDO outboxes send `mux.wake`; the brain host (the
 * cloud loop in this object, or a local brain host subscribed to `mux:<agent>`)
 * consumes the queue and acks per conversation. Wake items are rows (table
 * `wake`, key `<conversation>:<seq>`, n = arrival order) so a chief that was
 * offline for a week does not grow one JSON value.
 */
export const TABLE_WAKE = "wake"
/** Rows one ack may clear; a larger backlog clears over several acks. */
export const ACK_SCAN_LIMIT = 1000

export type WakeReason = "dm" | "mention" | "reply" | "owner"

export interface MuxHead {
  readonly agent: string | null
  readonly owner_user: string | null
  readonly brain: "local" | "cloud"
  readonly brain_host: string | null
  /** Wake rows not yet acked. */
  readonly pending: number
  readonly next_n: number
  /** Highest acked seq per conversation; wakes at or below it are ignored. */
  readonly cursors: Readonly<Record<string, number>>
}

export interface WakeItem {
  readonly conversation: string
  readonly seq: number
  readonly reason: WakeReason
  readonly at: number
}

export const INITIAL_MUX_HEAD: MuxHead = { agent: null, owner_user: null, brain: "local", brain_host: null, pending: 0, next_n: 1, cursors: {} }

type Params = Readonly<Record<string, unknown>>

const refuse = (code: string, message = code): ReduceResult<MuxHead> => ({ ok: false, code, message })
const str = (v: unknown, max = 128): v is string => typeof v === "string" && v.length > 0 && v.length <= max
const seqOf = (v: unknown): v is number => Number.isSafeInteger(v) && (v as number) > 0
const REASONS = new Set<WakeReason>(["dm", "mention", "reply", "owner"])

/** The chief itself (agent token) or a system op of a DO. */
const isChief = (head: MuxHead, p: Principal) => p.kind === "agent" && p.agent !== undefined && p.agent === head.agent
const isOwner = (head: MuxHead, p: Principal) => (p.kind === "session" || p.kind === "install") && p.user !== undefined && p.user === head.owner_user

export const muxDomain: Domain<MuxHead, Params> = {
  initial: () => INITIAL_MUX_HEAD,
  authorize: (head, op, _params, p): Reject | undefined => {
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
        if (seq <= (head.cursors[conversation] ?? 0) || ctx.rows.get(TABLE_WAKE, key)) return { ok: true, state: head, value: null, changed: false }
        const item: WakeItem = { conversation, seq, reason: reason as WakeReason, at: ctx.now }
        const next = { ...head, pending: head.pending + 1, next_n: head.next_n + 1 }
        return { ok: true, state: next, value: item, writes: [{ table: TABLE_WAKE, op: "upsert", key, n: head.next_n, row: item }] }
      }
      case "mux.ack": {
        const { conversation, seq } = params
        if (!str(conversation) || !seqOf(seq)) return refuse("invalid_params")
        const cursor = head.cursors[conversation] ?? 0
        if (seq <= cursor) return { ok: true, state: head, value: { cursor }, changed: false }
        const cleared: Array<RowWrite> = ctx.rows
          .range<WakeItem>(TABLE_WAKE, { limit: ACK_SCAN_LIMIT })
          .filter((r) => r.row.conversation === conversation && r.row.seq <= seq)
          .map((r) => ({ table: TABLE_WAKE, op: "delete" as const, key: r.key }))
        const next = { ...head, pending: Math.max(0, head.pending - cleared.length), cursors: { ...head.cursors, [conversation]: seq } }
        return { ok: true, state: next, value: { cursor: seq, cleared: cleared.length }, writes: cleared }
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
