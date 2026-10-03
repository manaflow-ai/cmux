import { DurableObject } from "cloudflare:workers"
import type { Env } from "./env.ts"

/**
 * AccountIndexDO: one per provider account key (for example
 * `github:installation:42`). Maps a webhook's account to the team connections
 * that linked it. Written only by ConnectionDOs (idempotent add/remove after
 * their own commit); not an owner of shared state, so no op protocol: a lost
 * entry only drops webhooks for that connection until it re-links.
 */
export class AccountIndexDO extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS links (team TEXT NOT NULL, connection TEXT NOT NULL, added_at INTEGER NOT NULL, PRIMARY KEY (team, connection))`)
    const columns = ctx.storage.sql.exec<{ name: string }>(`PRAGMA table_info(links)`).toArray().map((c) => c.name)
    if (!columns.includes("failures")) ctx.storage.sql.exec(`ALTER TABLE links ADD COLUMN failures INTEGER NOT NULL DEFAULT 0`)
  }

  /**
   * Records the outcome of one push handoff per link and returns each link's
   * consecutive failures, so a receiver can stop retrying for a link that
   * keeps failing (a dead letter) without dropping healthy links.
   */
  async noteDeliveries(outcomes: ReadonlyArray<{ team: string; connection: string; ok: boolean }>): Promise<Array<{ team: string; connection: string; failures: number }>> {
    return outcomes.map((o) => {
      this.ctx.storage.sql.exec(`UPDATE links SET failures = CASE WHEN ? THEN 0 ELSE failures + 1 END WHERE team = ? AND connection = ?`, o.ok ? 1 : 0, o.team, o.connection)
      const f = this.ctx.storage.sql.exec<{ failures: number }>(`SELECT failures FROM links WHERE team = ? AND connection = ?`, o.team, o.connection).toArray()[0]?.failures ?? 0
      return { team: o.team, connection: o.connection, failures: Number(f) }
    })
  }

  async add(team: string, connection: string): Promise<void> {
    this.ctx.storage.sql.exec(`INSERT OR IGNORE INTO links (team, connection, added_at) VALUES (?, ?, ?)`, team, connection, Date.now())
  }

  async remove(team: string, connection: string): Promise<void> {
    this.ctx.storage.sql.exec(`DELETE FROM links WHERE team = ? AND connection = ?`, team, connection)
  }

  async list(): Promise<Array<{ team: string; connection: string }>> {
    return this.ctx.storage.sql.exec<{ team: string; connection: string }>(`SELECT team, connection FROM links ORDER BY added_at LIMIT 100`).toArray()
  }
}
