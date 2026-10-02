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
