import type { SqlStore } from "@cmux/ownership"
import type { CloudTransport } from "./cloud-vm-api-config.ts"
import type { TeamVmCreateSpec } from "./team-vm-api-config.ts"

/**
 * The team VM ledger (decision TVM-LEDGER by a9, 2026-10-04): one durable row per provider VM this
 * lane created or found in a team's record, kept in the team's TeamVmDO next to the VM record.
 *
 * - A create writes the INTENT (name, env, team, who asked) before the provider call, and confirms
 *   the provider id after it. A crash in between leaves an `unconfirmed` row; reconcile resolves it
 *   by an EXACT name lookup (`confirmed` or `absent`), never by prefix or a provider list.
 * - A VM in the team record from before the ledger enters as `backfilled` (exact id only).
 * - Only a ledger id can be deleted (`deleted`, with deleted_at); a provider VM in no ledger is
 *   never adopted or deleted, whatever its name.
 */
export type LedgerState = "unconfirmed" | "confirmed" | "backfilled" | "absent" | "deleted"

export interface LedgerRow {
  readonly transport?: CloudTransport
  readonly name: string
  readonly provider_id: string | null
  readonly env: string
  readonly team: string
  readonly epoch: number
  readonly created_by: string
  readonly created_at: number
  readonly state: LedgerState
  readonly deleted_at: number | null
}

const COLUMNS = "name, provider_id, env, team, epoch, created_by, created_at, state, deleted_at, transport"
/** Safely inside the VM API's 24-hour idempotency retention window. */
const API_RECOVERY_MS = 23 * 60 * 60_000

export class TeamVmLedger {
  constructor(private readonly sql: SqlStore) {
    sql.exec(
      `CREATE TABLE IF NOT EXISTS team_vm_ledger (name TEXT PRIMARY KEY, provider_id TEXT UNIQUE, env TEXT NOT NULL, team TEXT NOT NULL, epoch INTEGER NOT NULL, created_by TEXT NOT NULL, created_at INTEGER NOT NULL, state TEXT NOT NULL, deleted_at INTEGER)`
    )
    const columns = new Set(sql.exec<{ name: string }>(`PRAGMA table_info(team_vm_ledger)`).map((c) => c.name))
    for (const [name, definition] of [["transport", "TEXT NOT NULL DEFAULT 'direct'"], ["api_spec", "TEXT"], ["api_sent_key", "TEXT"], ["api_sent_at", "INTEGER"]] as const) {
      if (!columns.has(name)) sql.exec(`ALTER TABLE team_vm_ledger ADD COLUMN ${name} ${definition}`)
    }
  }

  rows(): LedgerRow[] {
    return this.sql.exec<LedgerRow>(`SELECT ${COLUMNS} FROM team_vm_ledger ORDER BY created_at, name`)
  }

  byId(id: string): LedgerRow | undefined {
    return this.sql.exec<LedgerRow>(`SELECT ${COLUMNS} FROM team_vm_ledger WHERE provider_id = ?`, id)[0]
  }

  byName(name: string): LedgerRow | undefined {
    return this.sql.exec<LedgerRow>(`SELECT ${COLUMNS} FROM team_vm_ledger WHERE name = ?`, name)[0]
  }

  /**
   * The row an earlier create for `epoch` wrote, whatever reconcile made of it (unconfirmed,
   * confirmed or absent; never deleted, and deletes never reach a future epoch): the next create
   * for that epoch must ask for the same name, so a VM made under an older prefix is found again.
   */
  createRowFor(epoch: number): LedgerRow | undefined {
    return this.sql.exec<LedgerRow>(`SELECT ${COLUMNS} FROM team_vm_ledger WHERE epoch = ? AND state IN ('unconfirmed', 'confirmed', 'absent') ORDER BY created_at LIMIT 1`, epoch)[0]
  }

  unconfirmed(): LedgerRow[] {
    return this.sql.exec<LedgerRow>(`SELECT ${COLUMNS} FROM team_vm_ledger WHERE state = 'unconfirmed' ORDER BY created_at`)
  }

  /** Writes the create intent before the provider call; a name an earlier reconcile found `absent` opens again. */
  recordIntent(row: { name: string; env: string; team: string; epoch: number; created_by: string; now: number; transport?: CloudTransport; api_spec?: TeamVmCreateSpec }): void {
    this.sql.exec(
      `INSERT INTO team_vm_ledger (name, provider_id, env, team, epoch, created_by, created_at, state, deleted_at, transport, api_spec) VALUES (?, NULL, ?, ?, ?, ?, ?, 'unconfirmed', NULL, ?, ?)
       ON CONFLICT (name) DO UPDATE SET state = 'unconfirmed', created_by = excluded.created_by, created_at = excluded.created_at WHERE team_vm_ledger.state = 'absent'`,
      row.name,
      row.env,
      row.team,
      row.epoch,
      row.created_by,
      row.now,
      row.transport ?? "direct",
      row.api_spec ? JSON.stringify(row.api_spec) : null
    )
  }

  apiCreate(name: string): { api_spec: string | null; api_sent_key: string | null; api_sent_at: number | null } | undefined {
    return this.sql.exec<{ api_spec: string | null; api_sent_key: string | null; api_sent_at: number | null }>(`SELECT api_spec, api_sent_key, api_sent_at FROM team_vm_ledger WHERE name = ? AND transport = 'vm-api'`, name)[0]
  }

  /** Commit context and deadline before the POST. Unknown results never reopen a later window. */
  claimApiSend(name: string, context: string, now: number): boolean {
    const row = this.byName(name)
    if (!row || (row.state !== "unconfirmed" && row.state !== "absent")) return false
    const r = this.apiCreate(name)
    if (!r || !Number.isSafeInteger(now) || (r.api_sent_key === null) !== (r.api_sent_at === null) ||
      (r.api_sent_key !== null && r.api_sent_key !== context) || (r.api_sent_at !== null && (!Number.isSafeInteger(r.api_sent_at) || now < r.api_sent_at || now >= r.api_sent_at + API_RECOVERY_MS))) return false
    this.sql.exec(`UPDATE team_vm_ledger SET api_sent_key = COALESCE(api_sent_key, ?), api_sent_at = COALESCE(api_sent_at, ?) WHERE name = ? AND transport = 'vm-api' AND state IN ('unconfirmed', 'absent')`, context, now, name)
    const confirmed = this.apiCreate(name)
    return confirmed?.api_sent_key === context && confirmed.api_sent_at !== null && now < confirmed.api_sent_at + API_RECOVERY_MS
  }

  /** The provider answered with the VM's id (the create, or an exact name lookup). */
  confirm(name: string, id: string): void {
    this.sql.exec(`UPDATE team_vm_ledger SET provider_id = ?, state = 'confirmed' WHERE name = ? AND state IN ('unconfirmed', 'absent')`, id, name)
  }

  markAbsent(name: string): void {
    this.sql.exec(`UPDATE team_vm_ledger SET state = 'absent' WHERE name = ? AND state = 'unconfirmed'`, name)
  }

  markDeleted(id: string, now: number): void {
    this.sql.exec(`UPDATE team_vm_ledger SET state = 'deleted', deleted_at = ? WHERE provider_id = ?`, now, id)
  }

  /**
   * The team record's VM from before the ledger: added by its exact id, marked `backfilled`.
   * A row with the record's name that has no id yet takes the id instead. Returns true when it wrote.
   */
  backfill(row: { id: string; name: string; env: string; team: string; epoch: number; now: number }): boolean {
    if (this.byId(row.id)) return false
    const named = this.byName(row.name)
    if (named) {
      if (named.provider_id !== null) {
        // Should not happen (deletes never reach a future epoch): the record's VM has a name another id holds.
        console.error(JSON.stringify({ msg: "team vm ledger name holds another id", team: row.team, name: row.name, vm: row.id, ledger_id: named.provider_id }))
        return false
      }
      this.confirm(row.name, row.id)
      return true
    }
    this.sql.exec(
      `INSERT INTO team_vm_ledger (name, provider_id, env, team, epoch, created_by, created_at, state, deleted_at) VALUES (?, ?, ?, ?, ?, 'backfill', ?, 'backfilled', NULL)`,
      row.name,
      row.id,
      row.env,
      row.team,
      row.epoch,
      row.now
    )
    return true
  }
}
