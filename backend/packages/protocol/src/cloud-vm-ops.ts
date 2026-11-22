import { Schema } from "effect"
import { CloudMachine, MachineId } from "./cloud-machine-ops.ts"
import { def, mutationErrors } from "./op-def.ts"

/**
 * The VM daemon's own-machine ops (VM install at bind; coordinator and a9, 2026-10-05). Only a kind
 * "vm" install whose grant has `vm-self` may call them, and only for its bound machine
 * (params.machine = the install's bound_machine, and the machine still names this install). No
 * idempotency key: a report and an event are fresh facts, never replayed. Off MCP, hidden on the CLI.
 */

const Millis = Schema.Int.check(Schema.isGreaterThanOrEqualTo(0))
const Short = (max: number) => Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(max))
const VM_ERRORS = [...mutationErrors.filter((c) => c !== "revision.conflict" && c !== "idempotency.conflict"), "cloud.machine.not_found", "cloud.rate_limited"]
const vmDef = <P extends Schema.Top, R extends Schema.Top>(name: string, cls: "read" | "mutation", params: P, result: R, docs: string) =>
  def({
    name,
    owner: "cloud:CloudDO",
    class: cls,
    ...(cls === "mutation" ? { idempotency: "none" as const } : {}),
    // The no-key mutations keep the catalog rule for key-less ops (install only, execute, off MCP and CLI).
    risk: cls === "read" ? "read" : "execute",
    target: "team",
    principals: ["install"],
    params,
    result,
    errors: VM_ERRORS,
    docs: docs + (cls === "mutation" ? " No idempotency key: a report or event is a fresh fact and nothing replays." : "") + " VM installs only (kind vm, grant vm-self, its own bound machine).",
    cli: { path: "", visible: false },
    mcp: { expose: "never", group: "cloud" }
  })

export const CloudVmSelfGet = vmDef("cloud.vm.self.get", "read", Schema.Struct({ machine: MachineId }), Schema.Struct({ machine: CloudMachine }), "The VM's own machine record (the public machine view).")

/** At most one report is applied per 10 s per machine; a newer one in that window replaces the pending one (latest wins). */
export const VM_STATUS_MIN_INTERVAL_MS = 10_000
export const VmActivity = Schema.Struct({
  last_user_input_at: Schema.optionalKey(Millis),
  last_agent_action_at: Schema.optionalKey(Millis),
  active_sessions: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0), Schema.isLessThanOrEqualTo(10_000))
})
export const CloudVmStatusReport = vmDef(
  "cloud.vm.status.report",
  "mutation",
  Schema.Struct({
    machine: MachineId,
    state: Schema.Literals(["running", "degraded", "stopping"]),
    daemon: Schema.Struct({ version: Short(64), capabilities: Schema.Array(Short(64)).check(Schema.isMaxLength(32)) }),
    health: Schema.optionalKey(Schema.Struct({ disk_free_mb: Schema.optionalKey(Schema.Int.check(Schema.isGreaterThanOrEqualTo(0))), load: Schema.optionalKey(Schema.Number.check(Schema.isGreaterThanOrEqualTo(0))) })),
    /** For CloudDO's idle pause: the VM reports, CloudDO never polls it. */
    activity: VmActivity
  }),
  Schema.Struct({ applied: Schema.Boolean }),
  "Report the VM's state, daemon and activity. Coalesced: at most 1 applied per 10 s per machine (applied: false = held, the latest held report applies when the window ends)."
)

/** v1 event kinds and their data (data JSON at most 4 KB; never secrets or page content). */
const Title = Short(200)
const AgentData = Schema.Struct({ title: Schema.optionalKey(Title), agent: Schema.optionalKey(Short(64)), session: Schema.optionalKey(Short(64)) })
export const VM_EVENT_DATA = {
  "agent.started": AgentData,
  "agent.finished": Schema.Struct({ title: Schema.optionalKey(Title), agent: Schema.optionalKey(Short(64)), session: Schema.optionalKey(Short(64)), outcome: Schema.optionalKey(Schema.Literals(["success", "failure", "cancelled"])) }),
  "agent.needs_input": AgentData,
  notification: Schema.Struct({ title: Title, body: Schema.optionalKey(Short(1000)) }),
  "browser.lease.changed": Schema.Struct({ tab: Short(64), state: Schema.Literals(["acquired", "released"]) }),
  "cua.session.started": Schema.Struct({ session: Short(64) }),
  "cua.session.ended": Schema.Struct({ session: Short(64) }),
  "service.port.opened": Schema.Struct({ port: Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: 65535 })), proto: Schema.Literals(["tcp", "udp"]), process: Schema.optionalKey(Short(64)) }),
  "service.port.closed": Schema.Struct({ port: Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: 65535 })) })
} as const
export type VmEventKind = keyof typeof VM_EVENT_DATA
export const VM_EVENT_KINDS = Object.keys(VM_EVENT_DATA) as ReadonlyArray<VmEventKind>
export const VM_EVENT_DATA_MAX_BYTES = 4096
/** Per install: 10 events per second, burst 50; excess answers cloud.rate_limited {retry_after_ms}. */
export const VM_EVENT_RATE = { per_second: 10, burst: 50 } as const

export const CloudVmEventEmit = vmDef(
  "cloud.vm.event.emit",
  "mutation",
  Schema.Struct({ machine: MachineId, kind: Schema.Literals(VM_EVENT_KINDS as unknown as [VmEventKind, ...Array<VmEventKind>]), at: Millis, data: Schema.Unknown }),
  Schema.Struct({ delivered: Schema.Boolean }),
  "Send one event to the team's subscribers as the ephemeral team event cloud.machine.event (never stored). v1 kinds only; data per kind, at most 4 KB, URL query strings and fragments removed; 10/s, burst 50 per install."
)

export const cloudVmOps = [CloudVmSelfGet, CloudVmStatusReport, CloudVmEventEmit] as const
