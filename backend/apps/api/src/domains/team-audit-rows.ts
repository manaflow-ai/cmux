import type { Domain, RowReader, RowWrite } from "@cmux/ownership"
import type { AuditCategory, AuditRecord } from "./team-audit.ts"

/**
 * TeamDO keeps its audit records as rows too (cx-3bi.4), so `team.audit.list` can answer from the
 * owner (the billing role reads only billing records, spec H12 b). Every committed `audit.append`
 * outbox item becomes an `audit` row (n = the record's number) in the same commit, from one place,
 * so no reducer can append a record without its row. Records from before this change live only in
 * the audit_events projection. The table is private (TEAM_PRIVATE_TABLES): subscribers never get it.
 */
export const TABLE_AUDIT = "audit"

export const withAuditRows = <S>(domain: Domain<S>): Domain<S> => ({
  ...domain,
  reduce: (state, op, params, ctx) => {
    const r = domain.reduce(state, op, params, ctx)
    if (!r.ok || !r.outbox) return r
    const rows: Array<RowWrite> = r.outbox.filter((o) => o.kind === "audit.append").map((o) => {
      const rec = o.payload as AuditRecord
      return { table: TABLE_AUDIT, op: "upsert", key: String(rec.n), n: rec.n, row: rec }
    })
    return rows.length === 0 ? r : { ...r, writes: [...(r.writes ?? []), ...rows] }
  }
})

/** Records the read returns: public ids and the summary, never the chain's tx. */
const entryOf = (r: AuditRecord) => ({ n: r.n, op: r.op, actor: r.actor, at: r.at, category: r.category ?? ("admin" as AuditCategory), summary: r.summary, detail: r.detail, hash: r.hash })

/** Rows a filtered page scans at most, so a sparse category never makes one read unbounded. */
const SCAN_MAX = 2000

/** Newest first below `before`; `only` keeps one category. next_cursor: pass as `before` for the next page, null at the end. */
export const auditPage = (rows: RowReader | undefined, before: number | undefined, limit: number, only?: AuditCategory) => {
  const entries: Array<ReturnType<typeof entryOf>> = []
  let cursor = before
  let scanned = 0
  for (;;) {
    const batch = rows?.range<AuditRecord>(TABLE_AUDIT, { ...(cursor === undefined ? {} : { before: cursor }), limit: 200, desc: true }) ?? []
    for (const b of batch) {
      scanned++
      cursor = b.n ?? cursor
      if (only && (b.row.category ?? "admin") !== only) continue
      entries.push(entryOf(b.row))
      if (entries.length >= limit) return { entries, next_cursor: cursor ?? null }
    }
    if (batch.length < 200) return { entries, next_cursor: null }
    if (scanned >= SCAN_MAX) return { entries, next_cursor: cursor ?? null }
  }
}
