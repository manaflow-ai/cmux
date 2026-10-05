import type { SqlStore } from "@cmux/ownership"
import type { MachineRow } from "./domains/cloud.ts"

/**
 * The one path that ends VM installs (coordinator, 2026-10-05): every terminal machine state
 * (failed, deleting, removed by a finished delete, cleared) and every bind that does not keep its
 * install queues a durable revoke here; the queue retries from the alarm until UserDO confirms.
 * `cloud_vm_install` remembers each machine's current VM install, so a removed row still revokes.
 */

const RETRY_MS = [5_000, 30_000, 120_000, 600_000, 3_600_000]
export type Revoke = (a: { creator: string; install: string; why: string }) => Promise<boolean>

export class VmInstallRevokes {
  private ready = false
  constructor(private readonly sql: SqlStore) {}

  private tables() {
    if (this.ready) return
    this.sql.exec(`CREATE TABLE IF NOT EXISTS cloud_vm_install (machine TEXT PRIMARY KEY, install TEXT NOT NULL, creator TEXT NOT NULL)`)
    this.sql.exec(`CREATE TABLE IF NOT EXISTS cloud_vm_revoke (install TEXT PRIMARY KEY, creator TEXT NOT NULL, why TEXT NOT NULL, attempts INTEGER NOT NULL, due_at INTEGER NOT NULL, done INTEGER NOT NULL DEFAULT 0)`)
    this.ready = true
  }
  private exists() {
    return this.ready || Number(this.sql.exec<{ n: number }>(`SELECT count(*) AS n FROM sqlite_master WHERE name = 'cloud_vm_revoke'`)[0]?.n ?? 0) > 0
  }

  /** A bind committed: the machine's VM install is now `install` (a different previous one is revoked). */
  bound(machine: string, install: string, creator: string, now: number) {
    this.tables()
    const prev = this.sql.exec<{ install: string; creator: string }>(`SELECT install, creator FROM cloud_vm_install WHERE machine = ?`, machine)[0]
    if (prev && prev.install !== install) this.queue(prev.install, prev.creator, "re-bind", now)
    this.sql.exec(`INSERT INTO cloud_vm_install (machine, install, creator) VALUES (?, ?, ?) ON CONFLICT(machine) DO UPDATE SET install = excluded.install, creator = excluded.creator`, machine, install, creator)
  }

  /** After a commit that touched `machine`: a machine that is gone, failed or deleting loses its VM install. */
  reconcile(machine: string, row: MachineRow | undefined, now: number) {
    if (!this.exists() && !row?.vm_install) return
    this.tables()
    if (row && row.status !== "failed" && row.status !== "deleting") return
    // A machine bound before this table existed still names its install on the row.
    const cur = this.sql.exec<{ install: string; creator: string }>(`SELECT install, creator FROM cloud_vm_install WHERE machine = ?`, machine)[0] ?? (row?.vm_install ? { install: row.vm_install, creator: row.creator } : undefined)
    if (!cur) return
    this.queue(cur.install, cur.creator, row ? row.status : "removed", now)
    this.sql.exec(`DELETE FROM cloud_vm_install WHERE machine = ?`, machine)
  }

  /** Queue one revoke (idempotent by install). */
  queue(install: string, creator: string, why: string, now: number) {
    this.tables()
    this.sql.exec(`INSERT INTO cloud_vm_revoke (install, creator, why, attempts, due_at) VALUES (?, ?, ?, 0, ?) ON CONFLICT(install) DO NOTHING`, install, creator, why, now)
  }

  dueAt(): number | null {
    if (!this.exists()) return null
    this.tables()
    const r = this.sql.exec<{ t: number | null }>(`SELECT min(due_at) AS t FROM cloud_vm_revoke WHERE done = 0`)[0]
    return r?.t === null || r?.t === undefined ? null : Number(r.t)
  }

  /** Runs the due revokes; a failure backs off and stays queued. */
  async drain(now: number, revoke: Revoke): Promise<void> {
    if (!this.exists()) return
    this.tables()
    const due = this.sql.exec<{ install: string; creator: string; why: string; attempts: number }>(`SELECT install, creator, why, attempts FROM cloud_vm_revoke WHERE done = 0 AND due_at <= ? LIMIT 20`, now)
    for (const d of due) {
      const ok = await revoke({ creator: d.creator, install: d.install, why: d.why }).catch(() => false)
      // Kept as done (not deleted): a later commit naming the machine again must not queue it twice (review P3).
      if (ok) this.sql.exec(`UPDATE cloud_vm_revoke SET done = 1 WHERE install = ?`, d.install)
      else this.sql.exec(`UPDATE cloud_vm_revoke SET attempts = attempts + 1, due_at = ? WHERE install = ?`, now + RETRY_MS[Math.min(Number(d.attempts), RETRY_MS.length - 1)]!, d.install)
    }
  }

  pending(): Array<{ install: string; why: string; attempts: number }> {
    if (!this.exists()) return []
    return this.sql.exec<{ install: string; why: string; attempts: number }>(`SELECT install, why, attempts FROM cloud_vm_revoke WHERE done = 0 ORDER BY install`).map((r) => ({ ...r, attempts: Number(r.attempts) }))
  }
}
