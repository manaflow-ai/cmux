import type { Env } from "./env.ts"
import { socketOwnerNamespace, socketOwnerPage, type SocketOwnerCursor } from "./socket-registry.ts"

type Pending = SocketOwnerCursor & { install: string; version: string; retry_at: number }
const TABLE = `CREATE TABLE IF NOT EXISTS socket_authority_fanout (install TEXT PRIMARY KEY, version TEXT NOT NULL, cls TEXT NOT NULL DEFAULT '', name TEXT NOT NULL DEFAULT '', agent TEXT NOT NULL DEFAULT '', retry_at INTEGER NOT NULL DEFAULT 0)`

/** Durable cursor over the existing registry; notices carry no credentials or trusted authority values. */
export class InstallAuthorityFanout {
  constructor(private readonly sql: SqlStorage, private readonly env: Env) {}

  enqueue(install: string, version: string): void {
    this.sql.exec(TABLE)
    this.sql.exec(`INSERT INTO socket_authority_fanout (install, version) VALUES (?, ?) ON CONFLICT (install) DO UPDATE SET version = excluded.version, cls = '', name = '', agent = '', retry_at = 0 WHERE version != excluded.version`, install, version)
  }

  nextAt(now: number): number | null {
    if (!this.exists()) return null
    const row = this.sql.exec<{ at: number | null }>(`SELECT MIN(retry_at) AS at FROM socket_authority_fanout`).toArray()[0]
    return row?.at === null || row?.at === undefined ? null : Math.max(now, row.at)
  }

  /** One bounded page per alarm. Failure keeps its first unconfirmed owner for a later alarm. */
  async run(user: string, now: number): Promise<void> {
    if (!this.exists()) return
    const pending = this.sql.exec<Pending>(`SELECT * FROM socket_authority_fanout WHERE retry_at <= ? ORDER BY retry_at, install LIMIT 1`, now).toArray()[0]
    if (!pending) return
    const owners = socketOwnerPage(this.sql, pending.install, pending, now)
    const results = await Promise.all(owners.map(async (owner) => {
      const ns = socketOwnerNamespace(this.env, owner.cls)
      if (!ns) return false
      try {
        await (ns.get(ns.idFromName(owner.name)) as unknown as {
          recheckInstallAuthority(entity: string, user: string, install: string): Promise<void>
        }).recheckInstallAuthority(owner.name, user, pending.install)
        return true
      } catch { return false }
    }))
    const failed = results.indexOf(false)
    if (failed < 0 && owners.length < 128) {
      this.sql.exec(`DELETE FROM socket_authority_fanout WHERE install = ? AND version = ?`, pending.install, pending.version)
      return
    }
    const cursor = owners[(failed < 0 ? owners.length : failed) - 1] ?? pending
    // A newer incarnation resets the cursor while an older page is in flight; the old page cannot acknowledge it.
    this.sql.exec(`UPDATE socket_authority_fanout SET cls = ?, name = ?, agent = ?, retry_at = ? WHERE install = ? AND version = ?`,
      cursor.cls, cursor.name, cursor.agent, failed < 0 ? 0 : now + 5_000, pending.install, pending.version)
  }

  private exists(): boolean {
    return this.sql.exec(`SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'socket_authority_fanout'`).toArray().length > 0
  }
}
