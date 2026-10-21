/**
 * Guarded pruning of pi-durable's entry log in a Chief brain object (2026-10-16). The brain starts a
 * fresh pi context every turn (`pi.reset`), but pi keeps every older entry (each turn's whole input
 * and transcript, about 100 KB a turn), so one conversation's object would fill at about 100k turns.
 * pi-durable has no compaction API yet (.cmux-scratch/hq1f-cloud-chief/pi-durable-compaction-request.md).
 *
 * Rule: for a pi conversation with no task still running and no submission queued or placed, the
 * entries before its newest head marker's range (min of the marker's id and its `head`) are never
 * read again (pi derives context from the newest head marker onwards), so they go. Runs only when
 * Nothing in this brain reads pi context at an older point (`at`): runs and steps are the brain's own
 * cb_step rows, and the turn reads only the newest context. A future history view over pi entries
 * would have to keep more ranges. CHIEF_BRAIN_PRUNE_PI is "1" (on in staging; off in production until a week of staging soak).
 */
/** The agents SDK's PiHarness prefixes pi-durable's tables (DEFAULT_PREFIX "pi_"). */
const P = "pi_"
const tableExists = (sql: SqlStorage, name: string) => sql.exec(`SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?`, name).toArray().length > 0

export const prunePiEntries = (sql: SqlStorage): { readonly deleted: number; readonly skipped: ReadonlyArray<string> } => {
  if (!tableExists(sql, `${P}entries`) || !tableExists(sql, `${P}tasks`) || !tableExists(sql, `${P}submissions`)) return { deleted: 0, skipped: [] }
  let deleted = 0
  const skipped: Array<string> = []
  for (const c of sql.exec<{ id: number }>(`SELECT DISTINCT conversation_id AS id FROM ${P}entries`).toArray()) {
    const busyTasks = Number(sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM ${P}tasks WHERE conversation_id = ? AND status != 'terminal'`, c.id).one().n)
    const pending = Number(sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM ${P}submissions WHERE conversation_id = ? AND status IN ('queued', 'placed')`, c.id).one().n)
    if (busyTasks > 0 || pending > 0) {
      skipped.push(`conversation ${c.id}: ${busyTasks} running tasks, ${pending} pending submissions`)
      continue
    }
    const head = sql.exec<{ id: number; head: number | null }>(`SELECT id, head FROM ${P}entries WHERE conversation_id = ? AND head IS NOT NULL ORDER BY id DESC LIMIT 1`, c.id).toArray()[0]
    if (!head) continue
    const keepFrom = Math.min(Number(head.id), head.head === null ? Number(head.id) : Number(head.head))
    const n = Number(sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM ${P}entries WHERE conversation_id = ? AND id < ?`, c.id, keepFrom).one().n)
    if (n > 0) sql.exec(`DELETE FROM ${P}entries WHERE conversation_id = ? AND id < ?`, c.id, keepFrom)
    deleted += n
  }
  return { deleted, skipped }
}
