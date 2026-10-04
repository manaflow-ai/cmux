import type { SqlStore } from "@cmux/ownership"
import type { GuardedCloudDriver } from "./cloud-driver.ts"

/** The orphan report runs at most once per hour per CloudDO, only for a team that has had machines. */
export const SWEEP_EVERY_MS = 3600_000

export interface Suspect {
  readonly name: string
  readonly provider_id: string
}

/**
 * The hourly orphan report (P1-2, decision in the review: deletion only by ledger). It lists the
 * provider VMs tagged for this team under this environment's cld prefix and REPORTS, as an
 * error-level `cloud.orphan.suspect`, any that no live machine row and no ledger row names. It never
 * deletes: a provider list is not proof of ownership. The last run and its suspects live in a side
 * table (not the op stream), so a report commits no event.
 */
export class OrphanSweep {
  constructor(private readonly sql: SqlStore) {
    sql.exec(`CREATE TABLE IF NOT EXISTS cloud_sweep (id INTEGER PRIMARY KEY CHECK (id = 1), at INTEGER NOT NULL, suspects TEXT NOT NULL DEFAULT '[]')`)
  }

  private row() {
    return this.sql.exec<{ at: number; suspects: string }>(`SELECT at, suspects FROM cloud_sweep WHERE id = 1`)[0]
  }

  /** When the next report is due; null before the first wake that starts the clock. */
  dueAt(): number | null {
    const r = this.row()
    return r ? Number(r.at) + SWEEP_EVERY_MS : null
  }

  suspects(): Array<Suspect> {
    return JSON.parse(this.row()?.suspects ?? "[]") as Array<Suspect>
  }

  /** The first call starts the clock (no list right after the first machine); later calls report once per hour. */
  async maybeRun(now: number, team: string, driver: GuardedCloudDriver, known: ReadonlySet<string>, stream: string): Promise<void> {
    const r = this.row()
    if (!r) {
      this.sql.exec(`INSERT INTO cloud_sweep (id, at) VALUES (1, ?)`, now)
      return
    }
    if (now < Number(r.at) + SWEEP_EVERY_MS) return
    const listed = await driver.listOurs(team)
    const suspects = listed.filter((v) => !known.has(v.name)).map((v) => ({ name: v.name, provider_id: v.id }))
    for (const s of suspects) console.error(JSON.stringify({ level: "error", event: "cloud.orphan.suspect", stream, name: s.name, provider_id: s.provider_id, team }))
    this.sql.exec(`UPDATE cloud_sweep SET at = ?, suspects = ? WHERE id = 1`, now, JSON.stringify(suspects))
  }
}
