import type { SqlStore, StoredRow } from "@cmux/ownership"
import type { GuardedCloudDriver } from "./cloud-driver.ts"
import { TABLE_LEDGER, TABLE_MACHINE, TABLE_TOMBSTONE, type LedgerRow, type MachineRow } from "./domains/cloud.ts"

/** The orphan report runs at most once per hour per CloudDO, only while the team has rows. */
export const SWEEP_EVERY_MS = 3600_000
/** Abandoned names looked up by name per report (they are not always tagged for this team). */
const MAX_ABANDONED_LOOKUPS = 20

export type SuspectReason = "unknown" | "deleted" | "create_failed" | "delete_failed" | "create_cancelled" | "abandoned_create" | "metadata_mismatch" | "deleting"

export interface Suspect {
  readonly name: string
  readonly provider_id: string
  readonly reason: SuspectReason
}

/** The rows the report reads (the engine's row store). */
export interface ReportRows {
  get<T>(table: string, key: string): StoredRow<T> | undefined
  range<T>(table: string, range: { limit: number }): Array<StoredRow<T>>
}

/**
 * Which provider VMs to report (N1): every VM tagged for this team under this environment's cld
 * prefix, plus every VM under an abandoned create's recorded name, unless a pending call names it
 * or its machine is live (not deleting or failed). The reason says what CloudDO knows of the name.
 * Report only: nothing here deletes.
 */
export const collectSuspects = async (driver: GuardedCloudDriver, team: string, rows: ReportRows): Promise<Array<Suspect>> => {
  const ledger = rows.range<LedgerRow>(TABLE_LEDGER, { limit: 1000 }).map((r) => r.row)
  const byName = new Map<string, Array<LedgerRow>>()
  for (const l of ledger) byName.set(l.provider_name, [...(byName.get(l.provider_name) ?? []), l])
  const found = new Map<string, string>()
  for (const v of await driver.listOurs(team)) found.set(v.name, v.id)
  for (const l of ledger.filter((x) => x.state === "abandoned").slice(0, MAX_ABANDONED_LOOKUPS)) {
    if (found.has(l.provider_name)) continue
    const vm = await driver.peek(l.provider_name)
    if (vm) found.set(l.provider_name, vm.id)
  }
  const out: Array<Suspect> = []
  for (const [name, id] of found) {
    const named = byName.get(name) ?? []
    if (named.some((l) => l.state === "pending")) continue
    const machineId = named[0]?.machine ?? `vm_${name.slice(-20)}`
    const machine = rows.get<MachineRow>(TABLE_MACHINE, machineId)?.row
    if (machine && machine.status !== "deleting" && machine.status !== "failed") continue
    const abandoned = named.find((l) => l.state === "abandoned")
    const reason: SuspectReason = abandoned
      ? (abandoned.abandon_reason ?? "abandoned_create")
      : machine?.delete_failed
        ? "delete_failed"
        : machine?.status === "failed"
          ? "create_failed"
          : machine?.status === "deleting"
            ? "deleting"
            : named.some((l) => l.op === "create" && l.state === "cancelled")
              ? "create_cancelled"
              : rows.get(TABLE_TOMBSTONE, machineId)
                ? "deleted"
                : "unknown"
    out.push({ name, provider_id: id, reason })
  }
  return out.sort((a, b) => (a.name < b.name ? -1 : 1))
}

/**
 * The hourly orphan report (deletion only by ledger). The last run and its suspects live in a side
 * table (not the op stream), so a report commits no event. A failed list is logged and waits an hour.
 */
export class OrphanSweep {
  constructor(private readonly sql: SqlStore) {
    sql.exec(`CREATE TABLE IF NOT EXISTS cloud_sweep (id INTEGER PRIMARY KEY CHECK (id = 1), at INTEGER NOT NULL, suspects TEXT NOT NULL DEFAULT '[]')`)
  }

  private row() {
    return this.sql.exec<{ at: number; suspects: string }>(`SELECT at, suspects FROM cloud_sweep WHERE id = 1`)[0]
  }

  /** The last run (or the start of the clock); null before the first wake. */
  at(): number | null {
    const r = this.row()
    return r ? Number(r.at) : null
  }

  dueAt(): number | null {
    const at = this.at()
    return at === null ? null : at + SWEEP_EVERY_MS
  }

  suspects(): Array<Suspect> {
    return JSON.parse(this.row()?.suspects ?? "[]") as Array<Suspect>
  }

  /** The first call starts the clock; later calls report once per hour. Never throws (N3). */
  async maybeRun(now: number, team: string, stream: string, collect: () => Promise<Array<Suspect>>): Promise<void> {
    const r = this.row()
    if (!r) {
      this.sql.exec(`INSERT INTO cloud_sweep (id, at) VALUES (1, ?)`, now)
      return
    }
    if (now < Number(r.at) + SWEEP_EVERY_MS) return
    let suspects: Array<Suspect>
    try {
      suspects = await collect()
    } catch (e) {
      const code = e instanceof Error && "code" in e ? String((e as { code: unknown }).code) : "error"
      console.error(JSON.stringify({ level: "error", event: "cloud.orphan.sweep_failed", stream, team, code, error: e instanceof Error ? e.message : String(e) }))
      this.sql.exec(`UPDATE cloud_sweep SET at = ? WHERE id = 1`, now)
      return
    }
    for (const s of suspects) console.error(JSON.stringify({ level: "error", event: "cloud.orphan.suspect", stream, team, name: s.name, provider_id: s.provider_id, reason: s.reason }))
    this.sql.exec(`UPDATE cloud_sweep SET at = ?, suspects = ? WHERE id = 1`, now, JSON.stringify(suspects))
  }
}
