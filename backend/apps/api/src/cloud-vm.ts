import type { OwnerFrame, Principal, SqlStore } from "@cmux/ownership"
import { CloudVmEventEmit, CloudVmSelfGet, CloudVmStatusReport, VM_EVENT_DATA, VM_EVENT_DATA_MAX_BYTES, VM_EVENT_RATE, VM_STATUS_MIN_INTERVAL_MS, type CloudOpDef, type VmEventKind } from "@cmux/protocol"
import { Exit, Schema } from "effect"
import type { Env } from "./env.ts"
import type { SubmitResult } from "./owner-do.ts"
import { decodeParams } from "./domains/common.ts"
import { publicMachine, TABLE_MACHINE, type MachineRow } from "./domains/cloud.ts"
import { reportsActivity } from "./cloud-idle.ts"

/**
 * The VM daemon's own-machine ops (VM install at bind; coordinator and a9, 2026-10-05) and the VM
 * install registration at bind. A cloud.vm.* call passes only for a kind "vm" install whose grant
 * has vm-self, for its bound machine, while that machine still names this install (an epoch raise
 * or re-bind replaces the install, so an old one can do nothing here).
 */

export type VmReply = { readonly ok: true; readonly value: unknown } | { readonly ok: false; readonly code: string; readonly message: string; readonly details?: unknown }
interface Rows {
  get<T>(table: string, key: string): { readonly row: T; readonly n: number | null } | undefined
}

const forbidden = (message: string) => ({ ok: false as const, code: "auth.forbidden", message })

/** The gate every cloud.vm.* op runs first. */
type Refusal = Extract<VmReply, { ok: false }>
export const vmGate = (entity: string, p: Principal, machine: string, rows: Rows | undefined): { ok: true; row: MachineRow } | Refusal => {
  if (p.kind !== "install" || p.install_kind !== "vm" || !p.grant_classes?.includes("vm-self") || p.agent !== undefined) return forbidden("VM installs only")
  if (p.team !== entity || p.bound_machine !== machine) return forbidden("a VM install speaks only for its own machine")
  const row = rows?.get<MachineRow>(TABLE_MACHINE, machine)?.row
  if (!row || row.status === "deleting" || row.status === "failed") return { ok: false as const, code: "cloud.machine.not_found", message: "no such machine" }
  if (row.vm_install !== p.install) return forbidden("this machine is bound to another VM install")
  return { ok: true, row }
}

export const vmSelfGet = (entity: string, p: Principal, params: unknown, rows: Rows | undefined): VmReply => {
  const d = decodeParams<{ machine: string }>(CloudVmSelfGet as unknown as CloudOpDef, params)
  if (!d.ok) return d
  const g = vmGate(entity, p, d.value.machine, rows)
  return g.ok ? { ok: true, value: { machine: publicMachine(g.row) } } : g
}

/** Coalesced status reports: the latest per machine, applied at most once per 10 s. */
export class VmStatusQueue {
  constructor(private readonly sql: SqlStore) {}
  private ready = false
  private table() {
    if (!this.ready) {
      this.sql.exec(`CREATE TABLE IF NOT EXISTS cloud_vm_status (machine TEXT PRIMARY KEY, report TEXT NOT NULL, received_at INTEGER NOT NULL, applied_at INTEGER NOT NULL, activity_at INTEGER NOT NULL DEFAULT 0)`)
      // A table from before activity_at (development only): add the column once.
      if (!this.sql.exec<{ name: string }>(`SELECT name FROM pragma_table_info('cloud_vm_status')`).some((c) => c.name === "activity_at")) this.sql.exec(`ALTER TABLE cloud_vm_status ADD COLUMN activity_at INTEGER NOT NULL DEFAULT 0`)
    }
    this.ready = true
  }
  /** Stores the report; true when it may apply now. */
  offer(machine: string, report: unknown, now: number): boolean {
    this.table()
    const cur = this.sql.exec<{ applied_at: number }>(`SELECT applied_at FROM cloud_vm_status WHERE machine = ?`, machine)[0]
    const applyNow = !cur || now - Number(cur.applied_at) >= VM_STATUS_MIN_INTERVAL_MS
    this.sql.exec(
      `INSERT INTO cloud_vm_status (machine, report, received_at, applied_at) VALUES (?, ?, ?, ?) ON CONFLICT(machine) DO UPDATE SET report = excluded.report, received_at = excluded.received_at, applied_at = CASE WHEN ? THEN excluded.applied_at ELSE applied_at END`,
      machine, JSON.stringify(report), now, applyNow ? now : 0, applyNow ? 1 : 0
    )
    if (applyNow && reportsActivity(report)) this.sql.exec(`UPDATE cloud_vm_status SET activity_at = ? WHERE machine = ?`, now, machine)
    return applyNow
  }
  /** When the last report with the activity capability was applied (the cost backstop's "last heard"), or null. */
  lastActivityAt(machine: string): number | null {
    if (!this.ready && this.sql.exec<{ n: number }>(`SELECT count(*) AS n FROM sqlite_master WHERE name = 'cloud_vm_status'`)[0]?.n === 0) return null
    this.table()
    const r = this.sql.exec<{ t: number }>(`SELECT activity_at AS t FROM cloud_vm_status WHERE machine = ?`, machine)[0]
    return r && Number(r.t) > 0 ? Number(r.t) : null
  }

  /** When the next held report may apply, or null. */
  dueAt(): number | null {
    if (!this.ready && this.sql.exec<{ n: number }>(`SELECT count(*) AS n FROM sqlite_master WHERE name = 'cloud_vm_status'`)[0]?.n === 0) return null
    this.table()
    const r = this.sql.exec<{ t: number | null }>(`SELECT min(applied_at) AS t FROM cloud_vm_status WHERE received_at > applied_at`)[0]
    return r?.t === null || r?.t === undefined ? null : Number(r.t) + VM_STATUS_MIN_INTERVAL_MS
  }
  /** Held reports whose window ended, marked applied. */
  takeDue(now: number): Array<{ machine: string; report: unknown }> {
    if (this.dueAt() === null) return []
    const due = this.sql.exec<{ machine: string; report: string }>(`SELECT machine, report FROM cloud_vm_status WHERE received_at > applied_at AND applied_at + ? <= ?`, VM_STATUS_MIN_INTERVAL_MS, now)
    for (const d of due) this.sql.exec(`UPDATE cloud_vm_status SET applied_at = ?, activity_at = CASE WHEN ? THEN ? ELSE activity_at END WHERE machine = ?`, now, reportsActivity(JSON.parse(d.report)) ? 1 : 0, now, d.machine)
    return due.map((d) => ({ machine: d.machine, report: JSON.parse(d.report) as unknown }))
  }
}

export const vmStatusReport = (entity: string, p: Principal, params: unknown, rows: Rows | undefined, queue: VmStatusQueue, apply: (machine: string, report: unknown) => void, now: number): VmReply => {
  const d = decodeParams<typeof CloudVmStatusReport.params.Type>(CloudVmStatusReport as unknown as CloudOpDef, params)
  if (!d.ok) return d
  const g = vmGate(entity, p, d.value.machine, rows)
  if (!g.ok) return g
  const report = { ...d.value, install: p.install }
  const applied = queue.offer(d.value.machine, report, now)
  if (applied) apply(d.value.machine, report)
  return { ok: true, value: { applied } }
}

/** Removes the query string and fragment of every http(s) URL in a text (a9: never query strings). */
export const stripUrlQueries = (s: string) => s.replace(/(https?:\/\/[^\s?#]*)[?#][^\s]*/gi, "$1")
const stripDeep = (v: unknown): unknown =>
  typeof v === "string" ? stripUrlQueries(v) : v && typeof v === "object" ? Object.fromEntries(Object.entries(v as Record<string, unknown>).map(([k, x]) => [k, stripDeep(x)])) : v

/** Token bucket per install (memory only; a restart refills): 10 per second, burst 50. */
export class VmEventBuckets {
  private readonly buckets = new Map<string, { tokens: number; at: number }>()
  take(install: string, now: number): number | null {
    const b = this.buckets.get(install) ?? { tokens: VM_EVENT_RATE.burst, at: now }
    const tokens = Math.min(VM_EVENT_RATE.burst, b.tokens + ((now - b.at) / 1000) * VM_EVENT_RATE.per_second)
    if (tokens < 1) {
      this.buckets.set(install, { tokens, at: now })
      return Math.ceil(((1 - tokens) / VM_EVENT_RATE.per_second) * 1000)
    }
    this.buckets.set(install, { tokens: tokens - 1, at: now })
    return null
  }
}

export const vmEventEmit = (entity: string, p: Principal, params: unknown, rows: Rows | undefined, buckets: VmEventBuckets, send: (frame: unknown) => void, now: number): VmReply => {
  const d = decodeParams<{ machine: string; kind: VmEventKind; at: number; data: unknown }>(CloudVmEventEmit as unknown as CloudOpDef, params)
  if (!d.ok) return d
  const g = vmGate(entity, p, d.value.machine, rows)
  if (!g.ok) return g
  if (new TextEncoder().encode(JSON.stringify(d.value.data ?? null)).byteLength > VM_EVENT_DATA_MAX_BYTES) return { ok: false, code: "validation.invalid", message: `event data is larger than ${VM_EVENT_DATA_MAX_BYTES} bytes` }
  const schema = VM_EVENT_DATA[d.value.kind] as unknown as Schema.Codec<unknown, unknown>
  const data = Schema.decodeUnknownExit(schema)(d.value.data ?? {}, { onExcessProperty: "error" })
  if (!Exit.isSuccess(data)) return { ok: false, code: "validation.invalid", message: `invalid data for ${d.value.kind}` }
  const wait = buckets.take(p.install!, now)
  if (wait !== null) return { ok: false, code: "cloud.rate_limited", message: "too many VM events; slow down", details: { retry_after_ms: wait } }
  // The VM's clock is not trusted for ordering: `at` is clamped to the server time plus one minute (review P3).
  send({ t: "ephemeral", stream: `cloud:${entity}`, event: "cloud.machine.event", data: { machine: g.row.id, host: g.row.host ?? null, kind: d.value.kind, at: Math.min(d.value.at, now + 60_000), data: stripDeep(data.value) } })
  return { ok: true, value: { delivered: true } }
}

/**
 * Registers the VM install at bind under the machine's creator (kind vm, bound to the team and the
 * machine, default grant vm-self) through UserDO's internal install.register_server. The key names
 * the machine, epoch and public key, so a retried bind gets the same install.
 */
export const registerVmInstall = async (
  env: Env,
  a: { creator: string; team: string; machine: string; epoch: number; jwk: { kty: string; crv: string; x: string; y: string }; ssoTeam?: string }
): Promise<{ ok: true; id: string; grant: string } | { ok: false; code: string; message: string }> => {
  const stub = env.USER_DO.get(env.USER_DO.idFromName(a.creator)) as unknown as { submit(e: string, p: Principal, f: unknown): Promise<SubmitResult> }
  // The VM install counts as registered from the SSO that created its machine (the creator's SSO team), else its machine's team (review P2).
  const server: Principal = { identity: `system:cloud:${a.team}`, kind: "system", user: a.creator, team: a.team, sso_team: a.ssoTeam ?? a.team }
  const frame = {
    t: "op",
    op: "install.register_server",
    params: { public_jwk: a.jwk, kind: "vm", name: "Cloud VM", device_name: a.machine.slice(0, 80), platform: "linux", bound_team: a.team, bound_machine: a.machine },
    idempotency_key: `vm-install:${a.machine}:${a.epoch}:${a.jwk.x}`,
    origin: "user"
  }
  const r = await stub.submit(a.creator, server, frame)
  const f = r.frames.find((x: OwnerFrame) => x.t === "result" || x.t === "reject") as { t: string; value?: { id: string; grant: string }; code?: string; message?: string } | undefined
  if (!f || f.t !== "result" || !f.value) return { ok: false, code: f?.code ?? "owner.unreachable", message: f?.message ?? "VM install registration failed" }
  return { ok: true, id: f.value.id, grant: f.value.grant }
}

/** Sends an ephemeral frame (never committed) to the subscribed, live sockets `may` admits. */
export const sendEphemeral = (sockets: ReadonlyArray<WebSocket>, frame: unknown, may: (ws: WebSocket, a: { subscribed?: boolean; principal: Principal }) => boolean) => {
  const text = JSON.stringify(frame)
  for (const ws of sockets) {
    const a = ws.deserializeAttachment() as { subscribed?: boolean; principal: Principal } | null
    if (!a?.subscribed || !may(ws, a)) continue
    try {
      ws.send(text)
    } catch {}
  }
}

/**
 * Revokes a VM install (review P2): a refused bind, a re-bind and a machine delete each end the VM
 * install that no longer speaks for a live machine. Best effort; a failure is logged (the install can
 * still do nothing: the VM ops need the machine to name it, and every other entry point refuses VM tokens).
 */
export const revokeVmInstall = async (env: Env, a: { creator: string; team: string; install: string | undefined; why: string }): Promise<boolean> => {
  if (!a.install) return true
  const stub = env.USER_DO.get(env.USER_DO.idFromName(a.creator)) as unknown as { revokeByTeam(e: string, team: string, install: string, by: string, key: string): Promise<{ ok: boolean; code?: string }> }
  const r = await stub.revokeByTeam(a.creator, a.team, a.install, a.creator, `vm-revoke:${a.install}`).catch(() => ({ ok: false, code: "owner.unreachable" }))
  // A user or install that no longer exists has nothing left to revoke (review P3: no endless retry).
  if (!r.ok && r.code === "selector.not_found") return true
  if (!r.ok) console.warn(JSON.stringify({ msg: "vm install revoke failed", team: a.team, install: a.install, why: a.why, code: r.code }))
  return r.ok
}

