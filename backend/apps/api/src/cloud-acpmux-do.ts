import type { Principal } from "@cmux/ownership"
import type { GuardedCloudDriver } from "./cloud-driver.ts"
import type { GuestExecResult } from "./providers/contract.ts"
import {
  ACPMUX_EXIT_TEAM_VM,
  ACPMUX_EXIT_UNSUPPORTED,
  ACPMUX_PREPARE_TIMEOUT_MS,
  ACPMUX_STDIN_EXEC_TIMEOUT_MS,
  acpmuxKeyedStartCommand,
  acpmuxPersonHoldsCommand,
  acpmuxPersonHoldsFrames,
  acpmuxPrepareCommand,
  isAcpmuxKeyLine,
  isAcpmuxNonce,
  redactGuestLine
} from "./cloud-acpmux-guest.ts"
import type { MachineRow } from "./domains/cloud.ts"

/**
 * CloudDO's half of the keyed acpmux start on an app-server Cloud machine (cx-kvmz, cx-0q7o
 * slice 2e): RPC methods, NOT ops. Nothing here submits, writes an op-log row or a ledger row, or
 * keeps a param: the key K reaches only the stdin of the keyed start's provider exec, and the one
 * audit row per call holds {action, machine, who, at, outcome}.
 *
 * Only the machine's single owner may do either (hq-84 rule): the caller's session created the
 * machine, and the team (personal or shared) has exactly one member, the creator (a TeamDO lookup;
 * a failed lookup refuses). Team VMs (TeamVmDO) are a different object, never
 * reached from here; a team machine marker on the guest refuses too.
 *
 * No outcome carries a provider error, the command, its stdin or the guest's raw output: a code,
 * plus for a failed start the guest's last stderr line with every long hex or base64 run removed.
 */
export type AcpmuxRefusal =
  | "forbidden"
  | "not_found"
  | "not_single_owner"
  | "owner_unconfirmed"
  | "team_vm"
  | "not_running"
  | "busy"
  | "unsupported"
  | "timeout"
  | "start_failed"
  | "holds_failed"
  | "provider_failed"
  | "bad_request"

export type AcpmuxReply<A> = { readonly ok: true; readonly value: A } | { readonly ok: false; readonly refusal: AcpmuxRefusal; readonly line?: string }

export interface AcpmuxHost {
  readonly team: string
  /** The machine row of this team, or undefined. */
  machine(id: string): MachineRow | undefined
  driver(row: MachineRow): GuardedCloudDriver | null | Promise<GuardedCloudDriver | null>
  /** The team's members (TeamDO, as the creator), or null when the lookup failed. */
  members(team: string, user: string): Promise<{ readonly count: number; readonly users: ReadonlyArray<string> } | null>
  audit(entry: { action: string; machine: string; who: string; at: number; outcome: string }): void
  /** Machines with a keyed start in flight in this object (one at a time per machine). */
  readonly starting: Set<string>
}

const refuse = <A>(refusal: AcpmuxRefusal, line?: string): AcpmuxReply<A> => ({ ok: false, refusal, ...(line ? { line } : {}) })

/** The machine, when the caller is its single owner and it is running; else the refusal. */
const singleOwnerRunning = async (host: AcpmuxHost, principal: Principal, machine: string): Promise<MachineRow | AcpmuxRefusal> => {
  // A person's session only: no install token, no agent, no VM install.
  if (principal.kind !== "session" || principal.agent !== undefined || principal.install !== undefined || !principal.user || principal.team !== host.team) return "forbidden"
  const row = host.machine(machine)
  if (!row) return "not_found"
  if (row.creator !== principal.user) return "not_single_owner"
  // Every team, the creator's personal team too: exactly one member, the creator (TeamDO; a failed lookup refuses).
  const m = await host.members(host.team, row.creator).catch(() => null)
  if (!m) return "owner_unconfirmed"
  if (m.count !== 1 || m.users.length !== 1 || m.users[0] !== row.creator) return "not_single_owner"
  if (row.status !== "running") return "not_running"
  return row
}

/** One guest exec; a provider failure is only a code (its cause is dropped, never logged). */
const guestExec = async (host: AcpmuxHost, row: MachineRow, command: string, timeoutMs: number, stdin: Uint8Array | null): Promise<GuestExecResult | null> => {
  const driver = await Promise.resolve().then(() => host.driver(row)).catch(() => null)
  if (!driver) return null
  return driver.execStdin(row.provider_name, { team: host.team, machine: row.id }, command, stdin, timeoutMs).catch(() => null)
}

const commonRefusal = (r: GuestExecResult): AcpmuxRefusal | null => (r.exitCode === ACPMUX_EXIT_TEAM_VM ? "team_vm" : r.exitCode === 124 ? "timeout" : null)

const parseJsonObject = (line: string): Record<string, unknown> | null => {
  try {
    const v: unknown = JSON.parse(line)
    return v !== null && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : null
  } catch {
    return null
  }
}

const finish = <A>(host: AcpmuxHost, action: string, principal: Principal, machine: string, reply: AcpmuxReply<A>): AcpmuxReply<A> => {
  const outcome = reply.ok ? "ok" : reply.refusal
  host.audit({ action, machine, who: principal.identity, at: Date.now(), outcome })
  // No part of the request body or of the guest's output: the action, machine and outcome only.
  console.log(JSON.stringify({ msg: "cloud acpmux", action, team: host.team, machine, outcome }))
  return reply
}

/**
 * Restarts the machine's acpmux with the caller's key `keyLine` (64 lowercase hex and a newline).
 * The key goes only to the second exec's stdin; `keyLine` (this object's copy of the RPC
 * argument) is zeroed before this returns, whatever happens.
 */
export const acpmuxKeyedStartOn = async (host: AcpmuxHost, principal: Principal, machine: string, keyLine: Uint8Array): Promise<AcpmuxReply<{ personInstance: string }>> => {
  const done = (r: AcpmuxReply<{ personInstance: string }>) => finish(host, "acpmux.keyed_start", principal, machine, r)
  try {
    if (!(keyLine instanceof Uint8Array) || !isAcpmuxKeyLine(keyLine)) return done(refuse("bad_request"))
    const owned = await singleOwnerRunning(host, principal, machine)
    if (typeof owned === "string") return done(refuse(owned))
    if (host.starting.has(machine)) return done(refuse("busy"))
    host.starting.add(machine)
    try {
      const prepared = await guestExec(host, owned, acpmuxPrepareCommand(), ACPMUX_PREPARE_TIMEOUT_MS, null)
      if (!prepared) return done(refuse("provider_failed"))
      const preparedRefusal = commonRefusal(prepared)
      if (preparedRefusal) return done(refuse(preparedRefusal))
      if (prepared.exitCode === ACPMUX_EXIT_UNSUPPORTED) return done(refuse("unsupported"))
      if (prepared.exitCode !== 0) return done(refuse("start_failed", redactGuestLine(prepared.stderr)))
      const started = await guestExec(host, owned, acpmuxKeyedStartCommand(), ACPMUX_STDIN_EXEC_TIMEOUT_MS, keyLine)
      keyLine.fill(0)
      if (!started) return done(refuse("provider_failed"))
      const startedRefusal = commonRefusal(started)
      if (startedRefusal) return done(refuse(startedRefusal))
      // `acp --json` prints the status object pretty (cli/output.rs print_json): parse all of stdout.
      const status = parseJsonObject(started.stdout.trim())
      const instance = status?.personInstance
      if (started.exitCode !== 0 || status?.personKey !== true || typeof instance !== "string" || instance.length === 0 || instance.length > 256) return done(refuse("start_failed", redactGuestLine(started.stderr)))
      return done({ ok: true, value: { personInstance: instance } })
    } finally {
      host.starting.delete(machine)
    }
  } finally {
    if (keyLine instanceof Uint8Array) keyLine.fill(0)
  }
}

/** `_acpmux/person_holds {nonce}` on the machine's acpmux; the app checks the proof against its own key. */
export const acpmuxPersonHoldsOn = async (host: AcpmuxHost, principal: Principal, machine: string, nonce: unknown): Promise<AcpmuxReply<{ instance: string; proof: string }>> => {
  const done = (r: AcpmuxReply<{ instance: string; proof: string }>) => finish(host, "acpmux.person_holds", principal, machine, r)
  if (!isAcpmuxNonce(nonce)) return done(refuse("bad_request"))
  const owned = await singleOwnerRunning(host, principal, machine)
  if (typeof owned === "string") return done(refuse(owned))
  const held = await guestExec(host, owned, acpmuxPersonHoldsCommand(), ACPMUX_STDIN_EXEC_TIMEOUT_MS, new TextEncoder().encode(acpmuxPersonHoldsFrames(nonce)))
  if (!held) return done(refuse("provider_failed"))
  const heldRefusal = commonRefusal(held)
  if (heldRefusal) return done(refuse(heldRefusal))
  const answer = held.stdout.split("\n").map(parseJsonObject).find((f) => f?.id === 2)
  const result = answer?.result as Record<string, unknown> | undefined
  const instance = result?.instance, proof = result?.proof
  if (typeof instance !== "string" || instance.length === 0 || instance.length > 256 || typeof proof !== "string" || !/^[0-9a-f]{64}$/.test(proof)) return done(refuse("holds_failed"))
  return done({ ok: true, value: { instance, proof } })
}
