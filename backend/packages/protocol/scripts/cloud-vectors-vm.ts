/**
 * The VM daemon's own-machine cases of backend/catalog/cloud-vectors.json (VM install at bind,
 * 2026-10-05): cloud.vm.self.get, cloud.vm.status.report, cloud.vm.event.emit, and one ephemeral
 * cloud.machine.event per v1 kind. Synthetic data only.
 */
type Json = null | boolean | number | string | Array<Json> | { [k: string]: Json }
type Obj = { [k: string]: Json }

export const vmCases = (h: {
  kase: (name: string, op: string, params: Obj, responses: Array<Obj>, opts?: { key?: string; mutation?: boolean; principal?: Obj; note?: string }) => void
  readOk: (op: string, value: Json, revision?: string) => Obj
  readErr: (status: number, tag: string, code: string, message: string) => Obj
  events: Array<Obj>
  stream: string
  tx: () => string
  vm: (n: number) => string
  host: (n: number) => string
  M1: Obj
  seq: () => number
}) => {
  const { kase, readOk, readErr, events, stream, tx, vm, host, M1, seq } = h
  const VM_P = { kind: "install", install_kind: "vm", grant_classes: ["vm-self"], bound_machine: vm(1) }
  /** No key, no replay, no stream event: a report or event is a fresh fact. */
  const vmOk = (op: string, value: Obj): Obj => ({ http: { path: "/v1/ops", status: 200 }, body: { ok: true, op, value, transaction: tx(), idempotency_key: "", replayed: false, stream: "", sequence: 0 } })
  const vmErr = (op: string, code: string, message: string, details?: Obj): Obj => ({
    http: { path: "/v1/ops", status: 200 },
    body: { ok: false, op, error: { code, message, retryable: false, ...(details ? { details } : {}) }, transaction: tx(), idempotency_key: "", replayed: false, stream: "", sequence: 0 }
  })
  const opts = (note: string) => ({ mutation: true, principal: VM_P, note })

  kase("vm.self.get", "cloud.vm.self.get", { machine: vm(1) }, [readOk("cloud.vm.self.get", { machine: M1 })], { principal: VM_P, note: "The VM's own machine (public view). VM installs only: kind vm, grant vm-self, params.machine = its bound machine." })
  kase("vm.self.get.other_machine", "cloud.vm.self.get", { machine: vm(2) }, [readErr(403, "Forbidden", "auth.forbidden", "a VM install speaks only for its own machine")], { principal: VM_P })
  const report = { machine: vm(1), state: "running", daemon: { version: "0.41.0", capabilities: ["terminal", "files"] }, health: { disk_free_mb: 20480, load: 0.4 }, activity: { last_user_input_at: 1790000000000, last_agent_action_at: 1790000005000, active_sessions: 2 } }
  kase("vm.status.report", "cloud.vm.status.report", report, [vmOk("cloud.vm.status.report", { applied: true }), vmOk("cloud.vm.status.report", { applied: false })], opts("responses[0] applies at once; responses[1] came within 10 s and is held (latest wins): it applies when the window ends. Activity feeds CloudDO's idle pause; only a daemon change emits cloud.machine.upsert."))
  kase("vm.event.emit", "cloud.vm.event.emit", { machine: vm(1), kind: "agent.finished", at: 1790000010000, data: { title: "Done: https://example.com/pr/1?token=x", outcome: "success" } }, [vmOk("cloud.vm.event.emit", { delivered: true })], opts("Delivered as the ephemeral cloud.machine.event (URL query strings and fragments removed)."))
  kase("vm.event.emit.rate_limited", "cloud.vm.event.emit", { machine: vm(1), kind: "service.port.opened", at: 1790000010000, data: { port: 3000, proto: "tcp" } }, [vmErr("cloud.vm.event.emit", "cloud.rate_limited", "too many VM events; slow down", { retry_after_ms: 100 })], opts("10 per second, burst 50 per install; wait retry_after_ms."))
  kase("vm.event.emit.invalid", "cloud.vm.event.emit", { machine: vm(1), kind: "notification", at: 1790000010000, data: { title: "x", url: "https://example.com" } }, [vmErr("cloud.vm.event.emit", "validation.invalid", "invalid data for notification")], opts("Unknown fields, unknown kinds and data over 4 KB are refused."))

  events.push({ name: "machine.upsert.no_report", event: "cloud.machine.upsert", stream, seq: seq(), data: { machine: { ...M1, status: "paused", pause_reason: "no_report", revision: "57" } }, note: "The cost backstop paused it: no report from its VM for 24 h after its last start or bind. The app shows why; a start clears pause_reason." })
  const at = 1790000020000
  const kinds: Array<[string, Obj]> = [
    ["agent.started", { title: "Fix the flaky test", agent: "claude", session: "s1" }],
    ["agent.finished", { title: "Done: https://example.com/pr/1", agent: "claude", session: "s1", outcome: "success" }],
    ["agent.needs_input", { title: "Approve the migration?", agent: "codex", session: "s2" }],
    ["notification", { title: "Build finished", body: "All 412 tests passed." }],
    ["browser.lease.changed", { tab: "tab_1", state: "acquired" }],
    ["cua.session.started", { session: "cua_1" }],
    ["cua.session.ended", { session: "cua_1" }],
    ["service.port.opened", { port: 3000, proto: "tcp", process: "node" }],
    ["service.port.closed", { port: 3000 }]
  ]
  for (const [kind, data] of kinds)
    events.push({
      name: `machine.event.${kind}`,
      event: "cloud.machine.event",
      stream,
      ephemeral: true,
      data: { machine: vm(1), host: host(1), kind, at, data },
      note: "Ephemeral frame {t: ephemeral, stream, event, data}: never stored, no seq, no cursor; members of the team receive it, never a VM install."
    })
}
