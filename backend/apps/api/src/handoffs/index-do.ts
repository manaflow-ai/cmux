import { DurableObject } from "cloudflare:workers"
import type { Env } from "../env.ts"
import type { HandoffIndexEntry, HandoffStatus } from "./handoff-do.ts"

export type HandoffListItem = { readonly id: string; readonly sessionId: string; readonly status: HandoffStatus; readonly summary: string | null; readonly createdAt: string; readonly updatedAt: string }
export type HandoffListCursor = { readonly createdAt: number; readonly id: string }
type Row = { id: string; session_id: string; status: string; summary: string | null; created_at: number; updated_at: number }

/**
 * HandoffIndexDO: one per owner (name = the owner's user id), the AccountIndexDO pattern. It lists
 * the owner's hand-offs newest first with their status: the "come back from anywhere" list. It owns
 * no hand-off state: each HandoffDO writes its row after its own change (a late, older write
 * changes nothing), and a lost write is retried by that HandoffDO's alarm.
 */
export class HandoffIndexDO extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS handoffs (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, status TEXT NOT NULL, summary TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, version INTEGER NOT NULL)`)
    ctx.storage.sql.exec(`CREATE INDEX IF NOT EXISTS handoffs_newest ON handoffs (created_at DESC, id DESC)`)
  }

  async put(e: HandoffIndexEntry): Promise<void> {
    this.ctx.storage.sql.exec(
      `INSERT INTO handoffs (id, session_id, status, summary, created_at, updated_at, version) VALUES (?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT (id) DO UPDATE SET status = excluded.status, summary = excluded.summary, updated_at = excluded.updated_at, version = excluded.version WHERE excluded.version > handoffs.version`,
      e.id, e.sessionId, e.status, e.summary, e.createdAt, e.updatedAt, e.version
    )
  }

  /** Newest first; `before` is the last row of the previous page. */
  async list(limit: number, before?: HandoffListCursor): Promise<{ readonly handoffs: ReadonlyArray<HandoffListItem>; readonly next: HandoffListCursor | null }> {
    const sql = this.ctx.storage.sql
    const rows = (before
      ? sql.exec(`SELECT * FROM handoffs WHERE created_at < ? OR (created_at = ? AND id < ?) ORDER BY created_at DESC, id DESC LIMIT ?`, before.createdAt, before.createdAt, before.id, limit + 1)
      : sql.exec(`SELECT * FROM handoffs ORDER BY created_at DESC, id DESC LIMIT ?`, limit + 1)
    ).toArray() as Array<Row>
    const page = rows.slice(0, limit)
    const last = page.at(-1)
    return {
      handoffs: page.map((r) => ({ id: r.id, sessionId: r.session_id, status: r.status as HandoffStatus, summary: r.summary, createdAt: new Date(r.created_at).toISOString(), updatedAt: new Date(r.updated_at).toISOString() })),
      next: rows.length > limit && last ? { createdAt: last.created_at, id: last.id } : null
    }
  }
}
