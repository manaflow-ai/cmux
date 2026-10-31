import type { SqlStore } from "@cmux/ownership"
import { personalTeamIdFor, userIdFor } from "./domains/user.ts"

export interface PersonalTenantMarker {
  readonly version: 1
  readonly project: string
  readonly team: string
  readonly user: string
  readonly stack_user: string
  readonly nonce: string
}
export interface PersonalTenantIntent {
  readonly marker: PersonalTenantMarker
  readonly phase: "prepared" | "creating" | "ready"
  readonly tenant: string | null
  readonly attempts: number
  readonly createdAt: number
  readonly nextAt: number | null
}
export const validTenantId = (id: unknown): id is string => typeof id === "string" && /^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/.test(id)
export const isPersonalMarker = (value: unknown): value is PersonalTenantMarker => {
  if (!value || typeof value !== "object") return false
  const m = value as Record<string, unknown>
  return m.version === 1 && typeof m.project === "string" && m.project.length > 0 && m.project.length <= 128 && m.project.trim() === m.project && !/[\r\n]/.test(m.project) &&
    typeof m.user === "string" && typeof m.team === "string" && validTenantId(m.stack_user) && typeof m.nonce === "string" && /^[a-f0-9-]{36}$/.test(m.nonce) &&
    userIdFor(m.project, m.stack_user) === m.user && personalTeamIdFor(m.user) === m.team
}
export const samePersonalMarker = (a: unknown, b: PersonalTenantMarker): boolean => isPersonalMarker(a) &&
  a.project === b.project && a.team === b.team && a.user === b.user && a.stack_user === b.stack_user && a.nonce === b.nonce

/** TeamDO's private external-effect ledger; no table is created by a read or an unknown owner. */
export class PersonalTenantStore {
  constructor(private readonly sql: SqlStore) {}
  read(): PersonalTenantIntent | null {
    if (!this.sql.exec("SELECT 1 FROM sqlite_master WHERE type='table' AND name='team_vm_api_personal'").length) return null
    const row = this.sql.exec<{ marker: string; phase: string; tenant: string | null; attempts: number; created_at: number; next_at: number | null }>("SELECT marker, phase, tenant, attempts, created_at, next_at FROM team_vm_api_personal WHERE id=1")[0]
    if (!row) throw new Error("personal tenant ledger is empty")
    const marker: unknown = JSON.parse(row.marker)
    if (!isPersonalMarker(marker) || !["prepared", "creating", "ready"].includes(row.phase) || !Number.isSafeInteger(Number(row.attempts)) || Number(row.attempts) < 0 || !Number.isSafeInteger(Number(row.created_at)) || (row.next_at !== null && !Number.isSafeInteger(Number(row.next_at))) || (row.phase === "ready" ? !validTenantId(row.tenant) || row.next_at !== null : row.tenant !== null)) throw new Error("personal tenant ledger is invalid")
    return { marker, phase: row.phase as PersonalTenantIntent["phase"], tenant: row.tenant, attempts: Number(row.attempts), createdAt: Number(row.created_at), nextAt: row.next_at === null ? null : Number(row.next_at) }
  }
  reserve(marker: PersonalTenantMarker, now: number): PersonalTenantIntent {
    return this.sql.transaction(() => {
      this.sql.exec("CREATE TABLE IF NOT EXISTS team_vm_api_personal (id INTEGER PRIMARY KEY CHECK(id=1), marker TEXT NOT NULL, phase TEXT NOT NULL CHECK(phase IN ('prepared','creating','ready')), tenant TEXT, attempts INTEGER NOT NULL, created_at INTEGER NOT NULL, next_at INTEGER)")
      this.sql.exec("INSERT OR IGNORE INTO team_vm_api_personal (id, marker, phase, attempts, created_at) VALUES (1, ?, 'prepared', 0, ?)", JSON.stringify(marker), now)
      const row = this.read()
      if (!row || !samePersonalMarker(row.marker, marker)) throw new Error("personal tenant reservation conflict")
      return row
    })
  }
  sent(intent: PersonalTenantIntent, now: number): PersonalTenantIntent {
    return this.sql.transaction(() => {
      const before = this.read()
      if (!before || before.phase !== "prepared" || before.attempts !== intent.attempts || !samePersonalMarker(before.marker, intent.marker)) throw new Error("personal tenant send conflict")
      this.sql.exec("UPDATE team_vm_api_personal SET phase='creating', attempts=attempts+1, created_at=?, next_at=? WHERE id=1", now, now + 5000)
      const row = this.read()
      if (!row || row.phase !== "creating") throw new Error("personal tenant send conflict")
      return row
    })
  }
  ready(intent: PersonalTenantIntent, tenant: string): void {
    if (!validTenantId(tenant)) throw new Error("invalid personal tenant")
    this.sql.exec("UPDATE team_vm_api_personal SET phase='ready', tenant=?, next_at=NULL WHERE id=1 AND marker=? AND phase IN ('prepared','creating')", tenant, JSON.stringify(intent.marker))
    const row = this.read()
    if (!row || row.phase !== "ready" || row.tenant !== tenant || !samePersonalMarker(row.marker, intent.marker)) throw new Error("personal tenant receipt conflict")
  }
  retry(intent: PersonalTenantIntent, now: number, definitelyUnsent = false): void {
    const deadline = intent.createdAt + 24 * 3600_000
    const next = now >= deadline ? null : Math.min(deadline, now + Math.min(3600_000, 5000 * 2 ** Math.min(intent.attempts, 10)))
    this.sql.exec("UPDATE team_vm_api_personal SET phase=?, attempts=attempts+1, next_at=? WHERE id=1 AND marker=? AND phase=? AND attempts=? AND phase<>'ready'", definitelyUnsent ? "prepared" : intent.phase, next, JSON.stringify(intent.marker), intent.phase, intent.attempts)
  }
  parkPrepared(): void { this.sql.exec("UPDATE team_vm_api_personal SET next_at=NULL WHERE id=1 AND phase='prepared'") }
  /** Clear a due wake time; the next explicit create resumes a non-ready intent. */
  park(): void { this.sql.exec("UPDATE team_vm_api_personal SET next_at=NULL WHERE id=1 AND phase<>'ready'") }
}
