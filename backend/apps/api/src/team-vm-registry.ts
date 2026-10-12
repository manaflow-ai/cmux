import type { SqlStore } from "@cmux/ownership"

/**
 * The team VM registry (a9, 2026-10-04), kept in one reserved TeamVmDO instance
 * (TEAM_VM_REGISTRY): every team that has a team VM, and one row per provider VM id that a
 * team's ledger confirmed, backfilled or deleted. Events are idempotent by provider id: a
 * retried event changes nothing, a backfill never counts on top of a create, and a delete
 * counts once. Counts are read from these rows; nothing polls.
 */
export type RegistryEventKind = "intent" | "created" | "backfilled" | "deleted"

export interface RegistryEvent {
  readonly kind: RegistryEventKind
  readonly team: string
  readonly name: string
  readonly provider_id: string | null
}

export interface RegistryCounts {
  readonly teams: number
  readonly created: number
  readonly backfilled: number
  readonly deleted: number
  readonly live: number
}

export class TeamVmRegistry {
  constructor(private readonly sql: SqlStore) {
    sql.exec(`CREATE TABLE IF NOT EXISTS tvm_registry_team (team TEXT PRIMARY KEY, first_at INTEGER NOT NULL)`)
    sql.exec(
      `CREATE TABLE IF NOT EXISTS tvm_registry_vm (provider_id TEXT PRIMARY KEY, team TEXT NOT NULL, name TEXT NOT NULL, origin TEXT NOT NULL, at INTEGER NOT NULL, deleted_at INTEGER)`
    )
  }

  event(ev: RegistryEvent, now: number): void {
    this.sql.exec(`INSERT OR IGNORE INTO tvm_registry_team (team, first_at) VALUES (?, ?)`, ev.team, now)
    if (ev.kind === "intent" || !ev.provider_id) return
    if (ev.kind === "deleted") {
      // A delete of an id the registry never saw still counts (once): the row is created deleted.
      this.sql.exec(`INSERT OR IGNORE INTO tvm_registry_vm (provider_id, team, name, origin, at, deleted_at) VALUES (?, ?, ?, 'unknown', ?, ?)`, ev.provider_id, ev.team, ev.name, now, now)
      this.sql.exec(`UPDATE tvm_registry_vm SET deleted_at = ? WHERE provider_id = ? AND deleted_at IS NULL`, now, ev.provider_id)
      return
    }
    this.sql.exec(`INSERT OR IGNORE INTO tvm_registry_vm (provider_id, team, name, origin, at, deleted_at) VALUES (?, ?, ?, ?, ?, NULL)`, ev.provider_id, ev.team, ev.name, ev.kind, now)
  }

  counts(): RegistryCounts {
    const one = (q: string) => this.sql.exec<{ n: number }>(q)[0]?.n ?? 0
    return {
      // Teams with a live team VM (a team whose create never confirmed is registered but not counted).
      teams: one(`SELECT COUNT(DISTINCT team) AS n FROM tvm_registry_vm WHERE deleted_at IS NULL`),
      created: one(`SELECT COUNT(*) AS n FROM tvm_registry_vm WHERE origin = 'created'`),
      backfilled: one(`SELECT COUNT(*) AS n FROM tvm_registry_vm WHERE origin = 'backfilled'`),
      deleted: one(`SELECT COUNT(*) AS n FROM tvm_registry_vm WHERE deleted_at IS NOT NULL`),
      live: one(`SELECT COUNT(*) AS n FROM tvm_registry_vm WHERE deleted_at IS NULL`)
    }
  }

  /** Test only: forget everything (stands for a registry that never saw older ledger rows). */
  clear(): void {
    this.sql.exec(`DELETE FROM tvm_registry_vm`)
    this.sql.exec(`DELETE FROM tvm_registry_team`)
  }

  /** Provider ids any team's ledger holds (live or deleted). */
  knows(id: string): boolean {
    return this.sql.exec(`SELECT 1 AS x FROM tvm_registry_vm WHERE provider_id = ?`, id).length > 0
  }
}

/** Prefix report bounds: pages of this size, at most this many pages, at most this many names in the answer. */
const REPORT_PAGE = 100
const REPORT_MAX_PAGES = 50
const REPORT_MAX_NAMES = 200

/**
 * The operator prefix report (TeamVmDO.prefixReport): pages through the provider account's VMs and
 * names those with `prefix` whose id no team's ledger holds. Report-only; reads nothing else.
 */
export const prefixReport = async (
  driver: { listPage(limit: number, offset: number): Promise<{ readonly vms: ReadonlyArray<{ readonly id: string; readonly slug: string | null }>; readonly size: number; readonly total: number | null }> },
  prefix: string,
  registry: Pick<TeamVmRegistry, "knows">
): Promise<{ prefix: string; listed: number; matched: number; in_registry: number; not_in_registry: string[]; truncated: boolean }> => {
  let listed = 0
  let matched = 0
  let known = 0
  const unknown: string[] = []
  let truncated = false
  for (let page = 0; ; page++) {
    if (page >= REPORT_MAX_PAGES) {
      truncated = true
      break
    }
    const r = await driver.listPage(REPORT_PAGE, page * REPORT_PAGE)
    listed += r.size
    for (const vm of r.vms) {
      if (!vm.slug?.startsWith(prefix)) continue
      matched++
      if (registry.knows(vm.id)) known++
      else if (unknown.length < REPORT_MAX_NAMES) unknown.push(vm.slug)
      else truncated = true
    }
    if (r.size < REPORT_PAGE || (r.total !== null && (page + 1) * REPORT_PAGE >= r.total)) break
  }
  return { prefix, listed, matched, in_registry: known, not_in_registry: unknown, truncated }
}
