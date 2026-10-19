import type { OwnerFrame } from "@cmux/ownership"

/**
 * A host that left its owner loses its read replica (plans/cmux-next/object-sync/DESIGN.md
 * phase 3): when TeamDO commits `host.remove`, `server.revoke`, or a member cleanup that orphans
 * the member's hosts, it queues each host here and tells its HostDO to purge the stored streams
 * and close every replica socket (`HostDO.dropReplica`). The queue is TeamDO SQL, so a failed or
 * lost RPC is retried by the alarm until HostDO confirms; the drop is idempotent there.
 *
 * New sockets are refused before the drop arrives: TeamDO.hostReplicaRole reads the same committed
 * host record (deleted or orphaned: no role).
 */

type Sql = DurableObjectStorage["sql"]

/** The host ids an op's committed result took from their owner. */
export const hostsLeavingOwner = (op: string, frames: ReadonlyArray<OwnerFrame>): Array<string> => {
  const result = frames.find((f) => f.t === "result") as { value?: unknown } | undefined
  if (!result || frames.some((f) => f.t === "reject")) return []
  // Both results name the host that left: host.remove {host}, server.revoke {host, install, owner_user}.
  if (op === "host.remove" || op === "server.revoke") {
    const host = (result.value as { host?: unknown } | undefined)?.host
    return typeof host === "string" ? [host] : []
  }
  if (op === "team.member.cleaned") {
    const orphaned = (result.value as { orphaned?: unknown } | undefined)?.orphaned
    return Array.isArray(orphaned) ? orphaned.filter((h): h is string => typeof h === "string") : []
  }
  return []
}

export interface ReplicaDropTarget {
  dropReplica(reason: string): Promise<boolean>
}

export class HostReplicaDrops {
  private attempts = 0
  private retryAt: number | null = null

  constructor(
    private readonly sql: Sql,
    private readonly target: (host: string) => ReplicaDropTarget
  ) {
    sql.exec(`CREATE TABLE IF NOT EXISTS host_replica_drop (host TEXT PRIMARY KEY, reason TEXT NOT NULL, at INTEGER NOT NULL)`)
  }

  queue(hosts: ReadonlyArray<string>, reason: string, now: number): void {
    for (const host of hosts) this.sql.exec(`INSERT INTO host_replica_drop (host, reason, at) VALUES (?, ?, ?) ON CONFLICT(host) DO NOTHING`, host, reason, now)
  }

  /** When the alarm must run for a pending drop, or null. */
  nextAt(now: number): number | null {
    const n = Number(this.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM host_replica_drop`).toArray()[0]?.n ?? 0)
    return n === 0 ? null : Math.max(now, this.retryAt ?? now)
  }

  /** Tells each queued host's HostDO; a confirmed drop leaves the queue, a failure backs off. */
  async flush(now: number): Promise<void> {
    if (this.retryAt !== null && now < this.retryAt) return
    const pending = this.sql.exec<{ host: string; reason: string }>(`SELECT host, reason FROM host_replica_drop ORDER BY at LIMIT 50`).toArray()
    let failed = false
    for (const { host, reason } of pending) {
      try {
        if (await this.target(host).dropReplica(reason)) this.sql.exec(`DELETE FROM host_replica_drop WHERE host = ?`, host)
        else failed = true
      } catch (e) {
        failed = true
        console.error(JSON.stringify({ msg: "host replica drop failed", host, error: String(e).slice(0, 200) }))
      }
    }
    if (failed) {
      this.attempts += 1
      this.retryAt = now + Math.min(5 * 60_000, 1000 * 2 ** this.attempts)
    } else {
      this.attempts = 0
      this.retryAt = null
    }
  }
}
