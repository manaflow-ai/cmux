import type { Principal, SqlStore, StoredRow } from "@cmux/ownership"
import { CloudMachineConnectInfo, CloudMachineLinkToken, cloudServicesProblem, overlayAddress } from "@cmux/protocol"
import { LINK_TOKEN_MAX_TTL_S, newJti, signLinkToken, signingKid, type SigningKeys } from "./link-token.ts"
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

/** Retention of connect/link audit rows: 400 days, above the 365-day policy floor (coordinator decision). */
export const ACCESS_AUDIT_KEEP_MS = 400 * 86_400_000
/** Rows deleted per alarm pass, so one wake stays short; the next pass comes at once while old rows remain. */
export const ACCESS_AUDIT_PRUNE_BATCH = 500

/** Every connect_info and link_token mint, outside the op stream: who, when, what; never a secret. */
export class AccessAudit {
  constructor(private readonly sql: SqlStore) {
    sql.exec(`CREATE TABLE IF NOT EXISTS cloud_access_audit (id INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL, entry TEXT NOT NULL)`)
  }

  record(entry: Record<string, unknown>): void {
    this.sql.exec(`INSERT INTO cloud_access_audit (at, entry) VALUES (?, ?)`, entry.at, JSON.stringify(entry))
  }

  /** When the oldest row passes the retention window (coordinator decision: 400 days), or null. */
  pruneDueAt(): number | null {
    const at = this.sql.exec<{ at: number | null }>(`SELECT min(at) AS at FROM cloud_access_audit`)[0]?.at
    return at === null || at === undefined ? null : at + ACCESS_AUDIT_KEEP_MS
  }

  /** Deletes at most `limit` rows older than the retention window; returns how many. */
  prune(now: number, limit = ACCESS_AUDIT_PRUNE_BATCH): number {
    const ids = this.sql.exec<{ id: number }>(`SELECT id FROM cloud_access_audit WHERE at < ? ORDER BY at LIMIT ?`, now - ACCESS_AUDIT_KEEP_MS, limit)
    for (const r of ids) this.sql.exec(`DELETE FROM cloud_access_audit WHERE id = ?`, r.id)
    return ids.length
  }

  list(limit = 100): Array<Record<string, unknown>> {
    return this.sql.exec<{ entry: string }>(`SELECT entry FROM cloud_access_audit ORDER BY id DESC LIMIT ?`, limit).map((r) => JSON.parse(r.entry) as Record<string, unknown>)
  }
}

export const who = (p: Principal) => ({ by: p.identity, user: p.user ?? null, install: p.install ?? null, agent: p.agent ?? null })

/** cloud.machine.connect_info: no credential in a read (contract 1.7). */
export const connectInfo = async (entity: string, rows: Rows | undefined, p: Principal, params: unknown, policy: () => Promise<ReadonlyArray<string>>, audit: () => AccessAudit): Promise<ReadResult> => {
  const d = decodeParams<{ machine?: string; host?: string }>(CloudMachineConnectInfo, params)
  if (!d.ok) return d
  if ((d.value.machine === undefined) === (d.value.host === undefined)) return { ok: false, code: "validation.invalid", message: "give exactly one of machine and host" }
  const row = machineBySelector(rows, d.value)
  if (!row) return { ok: false, code: "cloud.machine.not_found", message: "no such machine in this team" }
  if (!row.host || !row.wg_public_key) return { ok: false, code: "cloud.machine.not_bound", message: "the machine is still provisioning" }
  const allowed = allowedServices(entity, row, p, await policy())
  if (!allowed.ok) return allowed
  audit().record({ op: "connect_info", machine: row.id, host: row.host, ...who(p), services: allowed.services, at: Date.now() })
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

export type MintReply = { readonly ok: true; readonly value: unknown } | { readonly ok: false; readonly code: string; readonly message: string; readonly details?: unknown }

/** CLOUD-LINK-FOLLOWUPS (2): the install kinds whose `cmux link` may dial a machine. vm, daemon and web never mint. */
export const LINK_INSTALL_KINDS: ReadonlyArray<string> = ["cli", "mac", "ios"]

/**
 * cloud.machine.link_token (5.8 items 5-6): install principals only (never a session, never an
 * agent token), a grant that covers execute, services a subset of what connect_info lists for this
 * caller. Each call mints a fresh token (no key, no replay, no stream event); the mint is audited
 * (kid, jti, services, exp, the request's internal key), never the token.
 */
export const mintLinkToken = async (
  args: { entity: string; rows: Rows | undefined; p: Principal; params: unknown; request: string; environment: string; keys: SigningKeys | null },
  policy: () => Promise<ReadonlyArray<string>>,
  /** Lazy: an object nobody created must not get the audit table (review P3-1). */
  audit: () => AccessAudit
): Promise<MintReply> => {
  const { entity, p } = args
  if (p.kind !== "install" || !p.install || p.agent !== undefined) return { ok: false, code: "auth.forbidden", message: "link tokens are minted only for an install's cmux link" }
  if (!LINK_INSTALL_KINDS.includes(p.install_kind ?? ""))
    return { ok: false, code: "cloud.link.install_refused", message: "only the cli, mac app and ios installs mint link tokens", details: { install_kind: p.install_kind ?? null, allowed: [...LINK_INSTALL_KINDS] } }
  // execute, or the narrow cloud-link class of the iPhone and Mac installs (this op and a restricted team_vm.ssh_cert only).
  if (!p.grant_classes?.includes("execute") && !p.grant_classes?.includes("cloud-link")) return { ok: false, code: "auth.forbidden", message: "grant does not cover execute or cloud-link" }
  const d = decodeParams<{ host: string; services: ReadonlyArray<string> }>(CloudMachineLinkToken, args.params)
  if (!d.ok) return d
  const row = machineBySelector(args.rows, { host: d.value.host })
  if (!row) return { ok: false, code: "cloud.machine.not_found", message: "no such machine in this team" }
  if (!row.host || !row.wg_public_key) return { ok: false, code: "cloud.machine.not_bound", message: "the machine is still provisioning" }
  // Coordinator decision: no dial to a machine that cannot answer, and no automatic start (start costs
  // money and a slot): the client shows "Start machine?" and calls cloud.machine.start.
  if (row.status === "paused" || row.status === "pausing" || row.status === "starting") return { ok: false, code: "cloud.machine.paused", message: "the machine is paused; start it first", details: { machine: row.id, state: row.status } }
  if (row.status === "deleting" || row.status === "failed") return { ok: false, code: "cloud.machine.not_bound", message: `the machine is ${row.status === "deleting" ? "being deleted" : "failed"}` }
  const allowed = allowedServices(entity, row, p, await policy())
  if (!allowed.ok) return allowed
  if (!d.value.services.every((s) => allowed.services.includes(s))) return { ok: false, code: "auth.forbidden", message: "a service you asked for is not one you may dial on this machine" }
  if (!args.keys) return { ok: false, code: "owner.unreachable", message: "link signing keys are not configured on this deployment" }
  const iat = Math.floor(Date.now() / 1000)
  const claims = { iss: `cmux:cloud:${args.environment}`, aud: row.host, sub: p.install, svc: [...d.value.services], epoch: row.epoch ?? 1, iat, exp: iat + LINK_TOKEN_MAX_TTL_S, jti: newJti(), team: entity }
  const kid = signingKid(args.keys, Date.now())
  if (!kid) return { ok: false, code: "owner.unreachable", message: "no link signing key has been published long enough to sign" }
  const token = await signLinkToken(claims, kid, args.keys.keys[kid]!)
  audit().record({ op: "link_token", request: args.request, machine: row.id, host: row.host, ...who(p), kid, jti: claims.jti, svc: claims.svc, exp: claims.exp, at: Date.now() })
  return { ok: true, value: { token, expires_at: claims.exp * 1000, host: row.host, epoch: claims.epoch, services: claims.svc } }
}
