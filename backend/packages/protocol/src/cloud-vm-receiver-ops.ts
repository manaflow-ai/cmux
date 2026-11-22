import { Schema } from "effect"
import { isPattern } from "./json-checks.ts"
import { MachineId } from "./cloud-machine-ops.ts"
import { def, mutationErrors } from "./op-def.ts"

const Generation = Schema.String.check(isPattern(/^[0-9a-f]{64}$/))
export const CloudVmReceiverLifecycleParams = Schema.Struct({
  machine: MachineId,
  phase: Schema.Literals(["read", "begin", "ready", "end"]),
  expected: Schema.optionalKey(Generation),
  attempt: Schema.optionalKey(Schema.String.check(isPattern(/^[0-9a-f]{32}$/)))
})
export const CloudVmReceiverLifecycleView = Schema.Struct({
  machine: MachineId, generation: Generation, phase: Schema.Literals(["idle", "starting", "ready", "stopped"])
})

/** VM-only lifecycle metadata; each retry rechecks the original live grant. */
export const CloudVmReceiverLifecycle = def({
  name: "cloud.vm.receiver.lifecycle", owner: "cloud:CloudDO", class: "mutation", idempotency: "none", risk: "execute", target: "team",
  principals: ["install"], params: CloudVmReceiverLifecycleParams, result: CloudVmReceiverLifecycleView,
  errors: [...mutationErrors.filter((c) => c !== "idempotency.conflict"), "cloud.machine.not_found", "cloud.rate_limited"],
  docs: "Record the bound VM's receiver incarnation. read takes only machine and phase; begin needs expected generation and a 32-hex attempt ID; ready/end need expected generation. Begin/ready require running; retirement remains available through park. Retries preserve terminal state. No idempotency key: every call rechecks current VM authority instead of replaying a response. VM installs only (kind vm, grant vm-self, own bound machine). Listener and token consumers require separate wiring.",
  cli: { path: "", visible: false }, mcp: { expose: "never", group: "cloud" }
})
