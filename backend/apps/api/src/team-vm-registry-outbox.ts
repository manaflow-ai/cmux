import type { SqlStore } from "@cmux/ownership"
import type { LedgerRow } from "./team-vm-ledger.ts"
import type { RegistryEvent, RegistryEventKind } from "./team-vm-registry.ts"

/** Sends of one registry event before it stops waking the object (it stays in the table, logged as an error). */
export const REGISTRY_MAX_ATTEMPTS = 20

/**
 * A team instance's registry outbox: events go into this table in the same synchronous step as
 * the ledger write, then to the registry instance; a failed send stays and retries with the alarm.
 */
export class RegistryOutbox {
  constructor(private readonly sql: SqlStore) {
    sql.exec(
      `CREATE TABLE IF NOT EXISTS team_vm_registry_outbox (key TEXT PRIMARY KEY, kind TEXT NOT NULL, team TEXT NOT NULL, name TEXT NOT NULL, provider_id TEXT, at INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0)`
    )
    sql.exec(`CREATE TABLE IF NOT EXISTS team_vm_registry_seed (id INTEGER PRIMARY KEY CHECK (id = 1), at INTEGER NOT NULL)`)
  }

  /** Events still to deliver (not counting given-up ones). */
  size(): number {
    return this.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM team_vm_registry_outbox WHERE attempts < ?`, REGISTRY_MAX_ATTEMPTS)[0]?.n ?? 0
  }

  enqueue(kind: RegistryEventKind, team: string, name: string, providerId: string | null): void {
    this.sql.exec(`INSERT OR IGNORE INTO team_vm_registry_outbox (key, kind, team, name, provider_id, at) VALUES (?, ?, ?, ?, ?, ?)`, `${kind}:${providerId ?? name}`, kind, team, name, providerId, Date.now())
  }

  /**
   * One-time seed: ledger rows written before the registry existed send their event once
   * (idempotent at the registry by provider id, so a row that already reached it changes nothing).
   */
  seed(rows: ReadonlyArray<LedgerRow>): void {
    if (this.sql.exec(`SELECT 1 AS x FROM team_vm_registry_seed WHERE id = 1`).length > 0) return
    for (const row of rows) {
      if (!row.provider_id) continue
      if (row.state === "confirmed" || row.state === "backfilled") this.enqueue(row.state === "confirmed" ? "created" : "backfilled", row.team, row.name, row.provider_id)
      else if (row.state === "deleted") {
        this.enqueue("created", row.team, row.name, row.provider_id)
        this.enqueue("deleted", row.team, row.name, row.provider_id)
      }
    }
    this.sql.exec(`INSERT OR IGNORE INTO team_vm_registry_seed (id, at) VALUES (1, ?)`, Date.now())
  }

  /** Test only: forget the seed. */
  resetSeed(): void {
    this.sql.exec(`DELETE FROM team_vm_registry_seed`)
  }

  /** Sends up to 50 events; a failing one does not block the others. Returns true when one failed. */
  async drain(send: (ev: RegistryEvent) => Promise<void>): Promise<boolean> {
    if (this.size() === 0) return false
    const rows = this.sql.exec<{ key: string; kind: RegistryEventKind; team: string; name: string; provider_id: string | null; attempts: number }>(
      `SELECT key, kind, team, name, provider_id, attempts FROM team_vm_registry_outbox WHERE attempts < ? ORDER BY at, rowid LIMIT 50`,
      REGISTRY_MAX_ATTEMPTS
    )
    let failed = false
    let delivered = false
    for (const r of rows) {
      try {
        await send({ kind: r.kind, team: r.team, name: r.name, provider_id: r.provider_id })
        this.sql.exec(`DELETE FROM team_vm_registry_outbox WHERE key = ?`, r.key)
        delivered = true
      } catch (e) {
        failed = true
        this.sql.exec(`UPDATE team_vm_registry_outbox SET attempts = attempts + 1 WHERE key = ?`, r.key)
        const level = r.attempts + 1 >= REGISTRY_MAX_ATTEMPTS ? "error" : "warn"
        console[level](JSON.stringify({ msg: level === "error" ? "team vm registry event given up" : "team vm registry event not delivered", kind: r.kind, team: r.team, error: String(e).slice(0, 200) }))
      }
    }
    // The registry answers again: events given up during an outage get a new set of attempts.
    if (delivered) this.sql.exec(`UPDATE team_vm_registry_outbox SET attempts = 0 WHERE attempts >= ?`, REGISTRY_MAX_ATTEMPTS)
    return failed
  }
}
