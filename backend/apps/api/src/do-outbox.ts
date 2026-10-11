import type { OutboxRow } from "@cmux/ownership"

/**
 * DO-to-DO outbox items (lane 15 need E4). Each item is an op for another owner object:
 * `kind` is the op, `payload` the params, `entity` the idempotency key. Delivery is at least
 * once; the target's ledger (or a max-merge reducer such as inbox.bump) makes it idempotent.
 */
export interface TargetItem {
  readonly id: number
  readonly op: string
  readonly params: unknown
  readonly key: string
}

export interface TargetBatch {
  readonly class: string
  readonly name: string
  readonly items: ReadonlyArray<TargetItem>
  /** Outbox ids that a newer item with the same coalesce key replaced (mark sent, never delivered). */
  readonly superseded: ReadonlyArray<number>
}

/** Groups target rows by object in outbox order and keeps only the newest item per coalesce key. */
export const groupTargets = (rows: ReadonlyArray<OutboxRow>): Array<TargetBatch> => {
  const groups = new Map<string, { class: string; name: string; rows: Array<OutboxRow> }>()
  for (const r of rows) {
    if (!r.target) continue
    const k = `${r.target.class}\u0000${r.target.name}`
    const g = groups.get(k) ?? { class: r.target.class, name: r.target.name, rows: [] }
    g.rows.push(r)
    groups.set(k, g)
  }
  return [...groups.values()].map((g) => {
    const newest = new Map<string, number>()
    for (const r of g.rows) if (r.target?.coalesce) newest.set(r.target.coalesce, r.id)
    const keep = g.rows.filter((r) => !r.target?.coalesce || newest.get(r.target.coalesce) === r.id)
    const superseded = g.rows.filter((r) => !keep.includes(r)).map((r) => r.id)
    return { class: g.class, name: g.name, superseded, items: keep.map((r) => ({ id: r.id, op: r.kind, params: r.payload, key: r.entity })) }
  })
}

/** What the target object returns for one batch: the ids it committed (applied or replayed). */
export interface DeliverResult {
  readonly done: ReadonlyArray<number>
}
