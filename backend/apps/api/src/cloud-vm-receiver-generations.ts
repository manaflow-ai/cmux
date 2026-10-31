import type { SqlStore } from "@cmux/ownership"
import { createHash } from "node:crypto"
import { GrantId, InstallId, UserId } from "@cmux/protocol"
import { Schema } from "effect"

type Phase = "idle" | "starting" | "ready" | "stopped"
export interface ReceiverGeneration { machine: string; generation: string; phase: Phase }
export interface ReceiverTransition { phase: "read" | "begin" | "ready" | "end"; expected?: string; attempt?: string }
interface Saved { machine: string; scope: string; generation: string; previous: string; attempt: string; phase: Exclude<Phase, "idle"> }
export interface OriginalReceiverGrant { user: string; install: string; grant: string }
export interface StoredReceiverAuthority { machine: string; scope: string; generation: string; identity: OriginalReceiverGrant }
interface Context { scope: string; generation: string; vm_user: string; vm_install: string; vm_grant: string }
type Reply = { ok: true; value: ReceiverGeneration } | { ok: false; code: "revision.conflict"; message: string }
export interface ReceiverTransitionAudit { phase: ReceiverTransition["phase"]; machine: string; changed: boolean; outcome: "ok" | "refused"; generation?: string }
const hash = (value: unknown) => createHash("sha256").update(JSON.stringify(value)).digest("hex")
const version = (s: string) => /^[0-9a-f]{64}$/.test(s)
const conflict = (): Reply => ({ ok: false, code: "revision.conflict", message: "the receiving incarnation changed or is no longer live" })
const viewOf = (machine: string, scope: string, stored: Saved | undefined): ReceiverGeneration => stored?.scope === scope
  ? { machine, generation: stored.generation, phase: stored.phase }
  : { machine, generation: hash(["cmux-vm-receiver-generation-v1", scope, "idle", ...(stored ? [stored.generation] : [])]), phase: "idle" }

/** One private row per machine. Recreating the owner never resets an attempt.
 * Call only after authenticating and rechecking the original live VM scope.
 * A changed scope starts closed; the previous scope cannot authorize a write.
 */
export class VmReceiverGenerations {
  constructor(private readonly sql: SqlStore) {}

  private ensure(): void {
    this.sql.exec("CREATE TABLE IF NOT EXISTS cloud_vm_receiver_generation (machine TEXT PRIMARY KEY, scope TEXT NOT NULL, generation TEXT NOT NULL, previous TEXT NOT NULL, attempt TEXT NOT NULL, phase TEXT NOT NULL)")
    this.sql.exec("CREATE TABLE IF NOT EXISTS cloud_vm_receiver_original_grant (machine TEXT PRIMARY KEY, scope TEXT NOT NULL, generation TEXT NOT NULL, vm_user TEXT NOT NULL, vm_install TEXT NOT NULL, vm_grant TEXT NOT NULL)")
  }

  private saved(machine: string): Saved | undefined {
    const stored = this.sql.exec<Saved>("SELECT machine, scope, generation, previous, attempt, phase FROM cloud_vm_receiver_generation WHERE machine = ?", machine)[0]
    if (stored && (!version(stored.scope) || !version(stored.generation) || !version(stored.previous)
      || !/^[0-9a-f]{32}$/.test(stored.attempt) || !["starting", "ready", "stopped"].includes(stored.phase))) throw new Error("receiving incarnation unavailable")
    return stored
  }

  current(machine: string, scope: string): ReceiverGeneration {
    if (!version(scope)) throw new Error("receiving incarnation unavailable")
    this.ensure()
    return viewOf(machine, scope, this.saved(machine))
  }

  /** The trusted machine owner closes authority before a power transition.
   * Keep the generation tombstone so a delayed READY or begin retry cannot revive it.
   */
  close(machine: string, audit: (entry: ReceiverTransitionAudit) => void): void {
    if (!Number(this.sql.exec<{ n: number }>("SELECT count(*) AS n FROM sqlite_master WHERE name = 'cloud_vm_receiver_generation'")[0]?.n ?? 0)) return
    this.ensure()
    this.sql.transaction(() => {
      const row = this.saved(machine)
      if (!row || row.phase === "stopped") return
      this.sql.exec("UPDATE cloud_vm_receiver_generation SET phase = 'stopped' WHERE machine = ? AND generation = ?", machine, row.generation)
      audit({ phase: "end", machine, changed: true, outcome: "ok", generation: row.generation })
    })
  }

  /** Private lookup context, never permission. The caller must revalidate the
   * original grant and scope; a ready phase alone cannot authorize a token.
   * Older rows without this context remain closed until a fresh attempt.
   */
  storedAuthority(machine: string): StoredReceiverAuthority | null {
    this.ensure()
    const row = this.saved(machine)
    if (!row || row.phase !== "ready") return null
    const context = this.sql.exec<Context>("SELECT scope, generation, vm_user, vm_install, vm_grant FROM cloud_vm_receiver_original_grant WHERE machine = ?", machine)[0]
    if (!context || context.scope !== row.scope || context.generation !== row.generation) return null
    if (!Schema.is(UserId)(context.vm_user) || !Schema.is(InstallId)(context.vm_install) || !Schema.is(GrantId)(context.vm_grant)) throw new Error("receiving incarnation unavailable")
    return { machine, scope: row.scope, generation: row.generation, identity: { user: context.vm_user, install: context.vm_install, grant: context.vm_grant } }
  }

  apply(machine: string, scope: string, request: ReceiverTransition, audit: (entry: ReceiverTransitionAudit) => void, identity?: OriginalReceiverGrant): Reply {
    if (!version(scope)) throw new Error("receiving incarnation unavailable")
    this.ensure()
    return this.sql.transaction(() => {
      const stored = this.saved(machine)
      const current = stored?.scope === scope ? stored : undefined
      // Closed scopes still observe the machine's latest stored incarnation.
      // A delayed initial request must not reset a newer authority scope.
      const view = viewOf(machine, scope, stored)
      let changed = false
      const finish = (reply: Reply): Reply => {
        audit({ phase: request.phase, machine, changed, outcome: reply.ok ? "ok" : "refused", ...(reply.ok ? { generation: reply.value.generation } : {}) })
        return reply
      }
      if (request.phase === "read") return finish({ ok: true, value: view })
      // A retry may observe ready or stopped, but may never revive either.
      if (request.phase === "begin" && current && current.previous === request.expected && current.attempt === request.attempt) return finish({ ok: true, value: view })
      if (request.expected !== view.generation) return finish(conflict())
      let next: Saved
      if (request.phase === "begin") {
        if (!["idle", "stopped"].includes(view.phase) || !request.attempt || !/^[0-9a-f]{32}$/.test(request.attempt)) return finish(conflict())
        next = { machine, scope, generation: hash(["cmux-vm-receiver-generation-v1", scope, view.generation, request.attempt]), previous: view.generation, attempt: request.attempt, phase: "starting" }
      } else {
        if (!current || (request.phase === "ready" && current.phase === "stopped")) return finish(conflict())
        const phase = request.phase === "ready" ? "ready" : "stopped"
        if (phase === current.phase) return finish({ ok: true, value: view })
        next = { ...current, phase }
      }
      this.sql.exec("INSERT INTO cloud_vm_receiver_generation (machine, scope, generation, previous, attempt, phase) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(machine) DO UPDATE SET scope = excluded.scope, generation = excluded.generation, previous = excluded.previous, attempt = excluded.attempt, phase = excluded.phase",
        machine, scope, next.generation, next.previous, next.attempt, next.phase)
      if (request.phase === "begin") {
        if (identity) {
          if (!Schema.is(UserId)(identity.user) || !Schema.is(InstallId)(identity.install) || !Schema.is(GrantId)(identity.grant)) throw new Error("receiving incarnation unavailable")
          this.sql.exec("INSERT INTO cloud_vm_receiver_original_grant (machine, scope, generation, vm_user, vm_install, vm_grant) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(machine) DO UPDATE SET scope = excluded.scope, generation = excluded.generation, vm_user = excluded.vm_user, vm_install = excluded.vm_install, vm_grant = excluded.vm_grant",
            machine, scope, next.generation, identity.user, identity.install, identity.grant)
        } else this.sql.exec("DELETE FROM cloud_vm_receiver_original_grant WHERE machine = ?", machine)
      }
      changed = true
      return finish({ ok: true, value: { machine, generation: next.generation, phase: next.phase } })
    })
  }
}
