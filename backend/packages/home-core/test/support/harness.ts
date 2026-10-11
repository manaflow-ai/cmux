import { createHash } from "node:crypto"
import { apply, isSend, targetMessageId } from "../../src/conversation/apply.ts"
import { create } from "../../src/conversation/create.ts"
import type { Domain, OutboxItem, Principal, ReduceResult, RowRange, RowReader, RowWrite, StoredRow } from "../../src/conversation/engine-types.ts"
import { formatRfc3339Millis } from "../../src/conversation/ids.ts"
import type { ApplyResult, Commit, OpRequest } from "../../src/conversation/request.ts"
import type { ConversationHead, Message, Op, Participant } from "../../src/conversation/types.ts"

/** Rows in memory, shaped like the engine's SqlRows (PR 16827 MemoryRows). */
export class MemoryRows implements RowReader {
  private readonly tables = new Map<string, Map<string, StoredRow>>()

  get<T>(table: string, key: string): StoredRow<T> | undefined {
    return this.tables.get(table)?.get(key) as StoredRow<T> | undefined
  }

  range<T>(table: string, q: RowRange): Array<StoredRow<T>> {
    const rows = [...(this.tables.get(table)?.values() ?? [])].filter(
      (row) => row.n !== null && row.n > (q.after ?? Number.MIN_SAFE_INTEGER) && row.n < (q.before ?? Number.MAX_SAFE_INTEGER)
    )
    rows.sort((a, b) => (q.desc ? b.n! - a.n! : a.n! - b.n!))
    return rows.slice(0, q.limit) as Array<StoredRow<T>>
  }

  apply(writes: ReadonlyArray<RowWrite>): void {
    for (const w of writes) {
      const table = this.tables.get(w.table) ?? new Map<string, StoredRow>()
      this.tables.set(w.table, table)
      if (w.op === "delete") table.delete(w.key)
      else table.set(w.key, { key: w.key, n: w.n ?? null, row: structuredClone(w.row) })
    }
  }

  all<T>(table: string): Array<T> {
    return [...(this.tables.get(table)?.values() ?? [])].map((row) => row.row as T)
  }
}

/**
 * A tiny owner for one Domain: state, rows, a ledger keyed by idempotency key
 * (replays return the stored result), and the outbox. Commit is atomic: a
 * reject changes nothing.
 */
export class DomainHost<S, P> {
  state: S
  readonly rows = new MemoryRows()
  readonly outbox: Array<OutboxItem> = []
  private readonly ledger = new Map<string, ReduceResult<S>>()
  private tx = 0
  now = Date.UTC(2026, 9, 1, 12)

  private readonly domain: Domain<S, P>

  constructor(domain: Domain<S, P>) {
    this.domain = domain
    this.state = domain.initial()
  }

  run(principal: Principal, op: string, params: P, key: string): ReduceResult<S> & { replayed?: boolean } {
    const ledgerKey = `${principal.identity}\0${key}`
    const prior = this.ledger.get(ledgerKey)
    if (prior) return { ...prior, replayed: true }
    const denied = this.domain.authorize?.(this.state, op, params, principal)
    if (denied) return { ok: false, ...denied }
    const tx = `tx${++this.tx}`
    let n = 0
    const result = this.domain.reduce(this.state, op, params, {
      principal,
      now: this.now,
      tx,
      newId: (prefix) => `${prefix}_${createHash("sha256").update(`${tx}:${n++}`).digest("hex").slice(0, 20)}`,
      rows: this.rows
    })
    if (result.ok) {
      this.state = result.state
      this.rows.apply(result.writes ?? [])
      this.outbox.push(...(result.outbox ?? []))
    }
    this.ledger.set(ledgerKey, result)
    return result
  }
}

export const NOW = "2026-10-01T12:00:00.000Z"
export const human = (id: string, name = "Alice"): Participant => ({ id, kind: "human", display_name: name })
export const agent = (id: string, owner?: string): Participant => ({
  id,
  kind: "agent",
  display_name: "mux",
  agent_class: "mux",
  acp_session: "mux",
  ...(owner ? { owner_user: owner } : {})
})
export const text = (value: string) => ({ type: "text" as const, text: value })

/** An in-memory core host (the Rust tests' `Host`): the head plus every message by seq. */
export class CoreHost {
  head: ConversationHead
  messages: Array<Message> = []
  nextId = 1
  now = NOW
  budget = false

  constructor(head?: ConversationHead) {
    if (head) this.head = head
    else {
      const result = create({ id: "conv_TEST", actor: "user_local", title: "mux", participants: [human("user_local"), agent("agent_mux")], now: NOW })
      if (!result.ok) throw new Error(result.code)
      this.head = result.head
    }
  }

  find(id: string): Message | undefined {
    return this.messages.find((message) => message.id === id)
  }

  request(actor: string, key: string, op: Op, extra: Partial<OpRequest> = {}): OpRequest {
    const targetId = targetMessageId(op)
    const replyId = op.kind === "message.send" ? op.reply_to?.message_id : undefined
    return {
      actor,
      idempotency_key: key,
      op,
      now: this.now,
      new_message_id: `msg_${String(this.nextId).padStart(26, "0")}`,
      target: targetId ? (this.find(targetId) ?? null) : null,
      reply_target: replyId ? (this.find(replyId) ?? null) : null,
      last_message: this.messages.at(-1) ?? null,
      ...(this.budget ? { recent: [...this.messages].reverse().slice(0, 5) } : {}),
      ...extra
    }
  }

  run(actor: string, key: string, op: Op, extra: Partial<OpRequest> = {}): ApplyResult {
    const result = apply(this.head, this.request(actor, key, op, extra))
    if (!result.ok) return result
    this.commit(op, result.commit)
    return result
  }

  commit(op: Op, commit: Commit): void {
    if (isSend(op)) this.nextId++
    this.head = commit.head
    const message = commit.message
    if (message) {
      const index = this.messages.findIndex((stored) => stored.id === message.id)
      if (index >= 0) this.messages[index] = message
      else this.messages.push(message)
    }
  }

  send(actor: string, key: string, body: string): Message {
    const result = this.run(actor, key, { kind: "message.send", client_msg_id: key, parts: [text(body)] })
    if (!result.ok) throw new Error(`send refused: ${result.code}`)
    return result.commit.message!
  }

  advance(ms: number): void {
    this.now = formatRfc3339Millis(Date.parse(this.now) + ms)
  }
}

/** xorshift64*: the same deterministic generator as the Rust op-sequence test. */
export class Rng {
  private state: bigint
  constructor(seed: bigint) {
    this.state = ((seed * 0x9e37_79b9_7f4a_7c15n) | 1n) & 0xffff_ffff_ffff_ffffn
  }
  next(): bigint {
    let x = this.state
    x ^= x >> 12n
    x ^= (x << 25n) & 0xffff_ffff_ffff_ffffn
    x ^= x >> 27n
    this.state = x
    return (x * 0x2545_f491_4f6c_dd1dn) & 0xffff_ffff_ffff_ffffn
  }
  below(bound: number): number {
    return Number(this.next() % BigInt(bound))
  }
  pick<T>(values: ReadonlyArray<T>): T {
    return values[this.below(values.length)]!
  }
}
