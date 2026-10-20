import type { OwnerFrame } from "@cmux/ownership"

/**
 * A host that left its owner loses its read replica (plans/cmux-next/object-sync/DESIGN.md
 * phase 3): when TeamDO commits `host.remove`, `server.revoke`, a member cleanup that orphans the
 * member's hosts, or the owner's `host.replica.purge`, it queues each host here and tells its
 * HostDO to purge the stored streams and close every replica socket (`HostDO.dropReplica`). The
 * queue is TeamDO SQL with a backoff per host, so a failed or lost RPC is retried by the alarm
 * until HostDO confirms; the drop is idempotent there.
 *
 * A removed host is also tombstoned in HostDO (later upgrades get 410): `hostDelete` drops the
 * install index, so the same install enrolls again under a new id. An orphaned host is not: its
 * record and id stay, and the former owner can enroll it again after rejoining, so only the stored
 * streams and sockets go, and TeamDO.hostReplicaRole refuses the orphaned record meanwhile. A
 * purged host is not either: it keeps its id. A Mac that was off publishes again at its next lease
 * while its own switch is on; an open publisher is closed 4403 like every replica socket, and its
 * daemon stays off until the app clears the replica (its off switch or a sign-out).
 */

type Sql = DurableObjectStorage["sql"]

export interface LeavingHost {
  readonly host: string
  /** True when the host id is gone for good (removed or revoked), false when it was orphaned. */
  readonly tombstone: boolean
  readonly reason: string
}

/** The hosts a freshly committed op took from their owner (a replayed op changed nothing). */
export const hostsLeavingOwner = (op: string, frames: ReadonlyArray<OwnerFrame>): Array<LeavingHost> => {
  const result = frames.find((f) => f.t === "result") as { value?: unknown; replayed?: boolean } | undefined
  if (!result || result.replayed || frames.some((f) => f.t === "reject")) return []
  // Both results name the host that left: host.remove {host}, server.revoke {host, install, owner_user}.
  if (op === "host.remove" || op === "server.revoke") {
    const host = (result.value as { host?: unknown } | undefined)?.host
    return typeof host === "string" ? [{ host, tombstone: true, reason: "the host was removed" }] : []
  }
  // The owner's delete: the host keeps its id and may publish again.
  if (op === "host.replica.purge") {
    const host = (result.value as { host?: unknown } | undefined)?.host
    return typeof host === "string" ? [{ host, tombstone: false, reason: "the owner deleted the replica" }] : []
  }
  if (op === "team.member.cleaned") {
    const orphaned = (result.value as { orphaned?: unknown } | undefined)?.orphaned
    return Array.isArray(orphaned) ? orphaned.filter((h): h is string => typeof h === "string").map((host) => ({ host, tombstone: false, reason: "the host's owner left the team" })) : []
  }
  return []
}

export interface ReplicaDropTarget {
  dropReplica(reason: string, tombstone: boolean): Promise<boolean>
}

const BATCH = 50

export class HostReplicaDrops {
  constructor(
    private readonly sql: Sql,
    private readonly target: (host: string) => ReplicaDropTarget
  ) {
    sql.exec(`CREATE TABLE IF NOT EXISTS host_replica_drop (host TEXT PRIMARY KEY, reason TEXT NOT NULL, tombstone INTEGER NOT NULL, attempts INTEGER NOT NULL, retry_at INTEGER NOT NULL)`)
  }

  /** Queues each host (a later tombstone wins over an earlier orphan drop of the same host). */
  queue(hosts: ReadonlyArray<LeavingHost>, now: number): void {
    for (const h of hosts)
      this.sql.exec(
        `INSERT INTO host_replica_drop (host, reason, tombstone, attempts, retry_at) VALUES (?, ?, ?, 0, ?) ON CONFLICT(host) DO UPDATE SET tombstone = MAX(tombstone, excluded.tombstone), reason = CASE WHEN excluded.tombstone > tombstone THEN excluded.reason ELSE reason END, attempts = 0, retry_at = excluded.retry_at`,
        h.host,
        h.reason,
        h.tombstone ? 1 : 0,
        now
      )
  }

  /** When the alarm must run for a pending drop, or null. */
  nextAt(now: number): number | null {
    const r = this.sql.exec<{ at: number | null }>(`SELECT MIN(retry_at) AS at FROM host_replica_drop`).toArray()[0]
    return r?.at === null || r?.at === undefined ? null : Math.max(now, Number(r.at))
  }

  /** Tells each due host's HostDO; a confirmed drop leaves the queue, a failure backs off for that host only. */
  async flush(now: number): Promise<void> {
    const due = this.sql.exec<{ host: string; reason: string; tombstone: number; attempts: number }>(`SELECT host, reason, tombstone, attempts FROM host_replica_drop WHERE retry_at <= ? ORDER BY retry_at LIMIT ${BATCH}`, now).toArray()
    for (const { host, reason, tombstone, attempts } of due) {
      let ok = false
      try {
        ok = await this.target(host).dropReplica(reason, tombstone === 1)
      } catch (e) {
        console.error(JSON.stringify({ msg: "host replica drop failed", host, error: String(e).slice(0, 200) }))
      }
      if (ok) this.sql.exec(`DELETE FROM host_replica_drop WHERE host = ? AND tombstone <= ?`, host, tombstone)
      else this.sql.exec(`UPDATE host_replica_drop SET attempts = ?, retry_at = ? WHERE host = ?`, attempts + 1, now + Math.min(5 * 60_000, 1000 * 2 ** (attempts + 1)), host)
    }
  }
}
