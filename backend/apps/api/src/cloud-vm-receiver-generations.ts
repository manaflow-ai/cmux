import type { SqlStore } from "@cmux/ownership"
import { createHash } from "node:crypto"

type Phase = "idle" | "starting" | "ready" | "stopped"
export interface ReceiverGeneration { machine: string; generation: string; phase: Phase }
export interface ReceiverTransition { phase: "read" | "begin" | "ready" | "end"; expected?: string; attempt?: string }
interface Saved { machine: string; scope: string; generation: string; previous: string; attempt: string; phase: Exclude<Phase, "idle"> }
type Reply = { ok: true; value: ReceiverGeneration } | { ok: false; code: "revision.conflict"; message: string }
export interface ReceiverTransitionAudit { phase: ReceiverTransition["phase"]; machine: string; changed: boolean; outcome: "ok" | "refused"; generation?: string }
const hash = (value: unknown) => createHash("sha256").update(JSON.stringify(value)).digest("hex")
const version = (s: string) => /^[0-9a-f]{64}$/.test(s)
const conflict = (): Reply => ({ ok: false, code: "revision.conflict", message: "the receiving incarnation changed or is no longer live" })

/** One private row per machine. Recreating the owner never resets an attempt.
 * Call only after authenticating and rechecking the original live VM scope.
 * A changed scope starts closed; the previous scope cannot authorize a write.
 */
export class VmReceiverGenerations {
  constructor(private readonly sql: SqlStore) {}

  apply(machine: string, scope: string, request: ReceiverTransition, audit: (entry: ReceiverTransitionAudit) => void): Reply {
    if (!version(scope)) throw new Error("receiving incarnation unavailable")
    this.sql.exec("CREATE TABLE IF NOT EXISTS cloud_vm_receiver_generation (machine TEXT PRIMARY KEY, scope TEXT NOT NULL, generation TEXT NOT NULL, previous TEXT NOT NULL, attempt TEXT NOT NULL, phase TEXT NOT NULL)")
    return this.sql.transaction(() => {
      const stored = this.sql.exec<Saved>("SELECT machine, scope, generation, previous, attempt, phase FROM cloud_vm_receiver_generation WHERE machine = ?", machine)[0]
      if (stored && (!version(stored.scope) || !version(stored.generation) || !version(stored.previous)
        || !/^[0-9a-f]{32}$/.test(stored.attempt) || !["starting", "ready", "stopped"].includes(stored.phase))) throw new Error("receiving incarnation unavailable")
      const current = stored?.scope === scope ? stored : undefined
      const view: ReceiverGeneration = current
        ? { machine, generation: current.generation, phase: current.phase }
        : { machine, generation: hash(["cmux-vm-receiver-generation-v1", scope, "idle"]), phase: "idle" }
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
      changed = true
      return finish({ ok: true, value: { machine, generation: next.generation, phase: next.phase } })
    })
  }
}
