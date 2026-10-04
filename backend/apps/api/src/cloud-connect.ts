import type { Principal, SqlStore, StoredRow } from "@cmux/ownership"
import { CloudMachineConnectInfo, cloudServicesProblem, overlayAddress } from "@cmux/protocol"
import type { ReadResult } from "./owner-do.ts"
import { decodeParams } from "./domains/common.ts"
import { personalTeamIdFor } from "./domains/user.ts"
import { TABLE_MACHINE, type MachineRow } from "./domains/cloud.ts"

/**
 * connect_info and the link-token access check (state-placement.md 5.8 items 3-5, decision
 * CLOUD-CONNECT-ACCESS): on a team machine every member, with the services the team policy
 * cloud.connectServices allows; on a personal machine only its creator (creator grants are not
 * built yet). Agents act as their principal. daemon only together with ssh (cloudServicesProblem).
 */

export interface Rows {
  get<T>(table: string, key: string): StoredRow<T> | undefined
  range<T>(table: string, range: { limit: number }): Array<StoredRow<T>>
}

const LINK_SERVICES = ["daemon", "ssh"] as const

/** The machine a selector names: by id, or by its overlay host id (also before bind, so not_bound answers). */
export const machineBySelector = (rows: Rows | undefined, sel: { machine?: string; host?: string }): MachineRow | undefined => {
  if (sel.machine !== undefined) return rows?.get<MachineRow>(TABLE_MACHINE, sel.machine)?.row
  return rows?.range<MachineRow>(TABLE_MACHINE, { limit: 1000 }).find((r) => r.row.host_id === sel.host)?.row
}

/** The services `p` may dial on `row` given the team's policy set, or a refusal. */
export const allowedServices = (entity: string, row: MachineRow, p: Principal, policy: ReadonlyArray<string>): { ok: true; services: Array<string> } | { ok: false; code: string; message: string } => {
  if (entity === personalTeamIdFor(row.creator) && p.user !== row.creator) return { ok: false, code: "auth.forbidden", message: "a personal machine is reachable only by its creator" }
  let services: Array<string> = LINK_SERVICES.filter((s) => policy.includes(s))
  // FINDER-FS: never daemon without ssh, whatever the stored policy says.
  if (cloudServicesProblem(services)) services = services.filter((s) => s !== "daemon")
  if (services.length === 0) return { ok: false, code: "auth.forbidden", message: "the team policy allows no link service on this machine" }
  return { ok: true, services }
}

/** Every connect_info and link_token mint, outside the op stream: who, when, what; never a secret. */
export class AccessAudit {
  constructor(private readonly sql: SqlStore) {
    sql.exec(`CREATE TABLE IF NOT EXISTS cloud_access_audit (id INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL, entry TEXT NOT NULL)`)
  }

  record(entry: Record<string, unknown>): void {
    this.sql.exec(`INSERT INTO cloud_access_audit (at, entry) VALUES (?, ?)`, entry.at, JSON.stringify(entry))
  }

  list(limit = 100): Array<Record<string, unknown>> {
    return this.sql.exec<{ entry: string }>(`SELECT entry FROM cloud_access_audit ORDER BY id DESC LIMIT ?`, limit).map((r) => JSON.parse(r.entry) as Record<string, unknown>)
  }
}

export const who = (p: Principal) => ({ by: p.identity, user: p.user ?? null, install: p.install ?? null, agent: p.agent ?? null })

/** cloud.machine.connect_info: no credential in a read (contract 1.7). */
export const connectInfo = async (entity: string, rows: Rows | undefined, p: Principal, params: unknown, policy: () => Promise<ReadonlyArray<string>>, audit: AccessAudit): Promise<ReadResult> => {
  const d = decodeParams<{ machine?: string; host?: string }>(CloudMachineConnectInfo, params)
  if (!d.ok) return d
  if ((d.value.machine === undefined) === (d.value.host === undefined)) return { ok: false, code: "validation.invalid", message: "give exactly one of machine and host" }
  const row = machineBySelector(rows, d.value)
  if (!row) return { ok: false, code: "cloud.machine.not_found", message: "no such machine in this team" }
  if (!row.host || !row.wg_public_key) return { ok: false, code: "cloud.machine.not_bound", message: "the machine is still provisioning" }
  const allowed = allowedServices(entity, row, p, await policy())
  if (!allowed.ok) return allowed
  audit.record({ op: "connect_info", machine: row.id, host: row.host, ...who(p), services: allowed.services, at: Date.now() })
  return {
    ok: true,
    value: {
      machine: row.id,
      host: row.host,
      epoch: row.epoch ?? 1,
      state: row.status,
      // vpc_endpoint, public_ipv6 and gateway come from TeamDO's peer map (lane 12), which does not exist yet.
      peer: { wg_public_key: row.wg_public_key, overlay_address: await overlayAddress(row.host), vpc_endpoint: null, public_ipv6: null },
      gateway: null,
      services: allowed.services,
      daemon: { version: row.daemon?.version ?? null, capabilities: [...(row.daemon?.capabilities ?? [])] },
      revision: row.revision
    },
    revision: ""
  }
}
