import { DurableObject } from "cloudflare:workers"
import type { Env } from "./env.ts"
import { STOP_CLAIM_LEASE_MS, STOP_DONE_TTL_MS } from "./integrations/gmail-stop.ts"

/**
 * AccountIndexDO: one per provider account key (for example
 * `github:installation:42`). Maps a webhook's account to the team connections
 * that linked it. Written only by ConnectionDOs (idempotent add/remove after
 * their own commit); not an owner of shared state, so no op protocol: a lost
 * entry only drops webhooks for that connection until it re-links.
 */
/** Objects created before 9eda094b7a4 have links without the failure count. */
export const upgradeLinks = (sql: SqlStorage) => {
  const columns = sql.exec<{ name: string }>(`PRAGMA table_info(links)`).toArray().map((c) => c.name)
  if (!columns.includes("failures")) sql.exec(`ALTER TABLE links ADD COLUMN failures INTEGER NOT NULL DEFAULT 0`)
}

export class AccountIndexDO extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS links (team TEXT NOT NULL, connection TEXT NOT NULL, added_at INTEGER NOT NULL, PRIMARY KEY (team, connection))`)
    upgradeLinks(ctx.storage.sql)
    // One users.stop per mailbox (integrations/gmail-stop.ts): who is stopping, and whether it finished.
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS stop_claim (id INTEGER PRIMARY KEY CHECK (id = 1), connection TEXT NOT NULL, state TEXT NOT NULL, at INTEGER NOT NULL)`)
  }

  /** `go`: this connection sends the stop; `done`: another already stopped this mailbox; `busy`: another is stopping now. */
  async claimStop(connection: string, now: number): Promise<"go" | "done" | "busy"> {
    const c = this.ctx.storage.sql.exec<{ connection: string; state: string; at: number }>(`SELECT connection, state, at FROM stop_claim WHERE id = 1`).toArray()[0]
    if (c?.state === "done" && now - Number(c.at) < STOP_DONE_TTL_MS) return "done"
    // A running stop (also one by this connection, in a concurrent drain) is not started twice.
    if (c?.state === "running" && now - Number(c.at) < STOP_CLAIM_LEASE_MS) return "busy"
    this.ctx.storage.sql.exec(`INSERT OR REPLACE INTO stop_claim (id, connection, state, at) VALUES (1, ?, 'running', ?)`, connection, now)
    return "go"
  }

  async finishStop(connection: string, ok: boolean): Promise<void> {
    if (ok) this.ctx.storage.sql.exec(`UPDATE stop_claim SET state = 'done', at = ? WHERE id = 1 AND connection = ?`, Date.now(), connection)
    else this.ctx.storage.sql.exec(`DELETE FROM stop_claim WHERE id = 1 AND connection = ? AND state = 'running'`, connection)
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
    // A new link starts a new watch: an earlier finished stop no longer covers this mailbox.
    this.ctx.storage.sql.exec(`DELETE FROM stop_claim`)
  }

  async remove(team: string, connection: string): Promise<void> {
    this.ctx.storage.sql.exec(`DELETE FROM links WHERE team = ? AND connection = ?`, team, connection)
  }

  async list(): Promise<Array<{ team: string; connection: string }>> {
    return this.ctx.storage.sql.exec<{ team: string; connection: string }>(`SELECT team, connection FROM links ORDER BY added_at LIMIT 100`).toArray()
  }
}
