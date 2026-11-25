import { DurableObject } from "cloudflare:workers"
import type { Env } from "./env.ts"

/**
 * DomainDO: one per lowercased email domain, the single writer of which team
 * owns it (spec/enterprise.md section 2). Called only by TeamDO after it saw
 * the team's DNS TXT record. The first team to verify owns the domain until it
 * releases it; a claim by the owner again is a no-op, so retries are safe.
 * Sign-in discovery reads the owner here without scanning any table.
 */
export class DomainDO extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    ctx.storage.sql.exec(
      `CREATE TABLE IF NOT EXISTS owner (id INTEGER PRIMARY KEY CHECK (id = 1), domain TEXT NOT NULL, team TEXT NOT NULL, verified_at INTEGER NOT NULL)`
    )
  }

  private current(): { domain: string; team: string; verified_at: number } | undefined {
    return this.ctx.storage.sql.exec<{ domain: string; team: string; verified_at: number }>(`SELECT domain, team, verified_at FROM owner WHERE id = 1`).toArray()[0]
  }

  /** Makes `team` the owner unless another team owns the domain. Idempotent for the owner. */
  async claim(domain: string, team: string, now: number): Promise<{ ok: true; verified_at: number } | { ok: false; owner: string }> {
    const row = this.current()
    // One object per domain: a call naming another domain is a routing bug, never an ownership change.
    if (row && row.domain !== domain) throw new Error(`DomainDO for ${row.domain} called for ${domain}`)
    if (row && row.team !== team) return { ok: false, owner: row.team }
    if (row) return { ok: true, verified_at: row.verified_at }
    this.ctx.storage.sql.exec(`INSERT INTO owner (id, domain, team, verified_at) VALUES (1, ?, ?, ?)`, domain, team, now)
    return { ok: true, verified_at: now }
  }

  /** Drops the claim when `team` owns it; anything else is a no-op. */
  async release(team: string): Promise<void> {
    this.ctx.storage.sql.exec(`DELETE FROM owner WHERE id = 1 AND team = ?`, team)
  }

  /** The owning team, or null (sign-in discovery). */
  async owner(): Promise<string | null> {
    return this.current()?.team ?? null
  }
}
