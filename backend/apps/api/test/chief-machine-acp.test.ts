import { describe, expect, it } from "vitest"
import { machineAgentEvents, startMachineAgent, stopMachineAgent, type MachineRpc } from "../src/chief-brain/brain-machine-acp.ts"

const args = { operation: "owner/chief/conversation/run", harness: "claude" as const, cwd: "/home/cmux/proj", prompt: "build me a hello page" }
const absent = () => Object.assign(new Error("not found"), { code: -32002 })
type Row = Record<string, unknown>
const fixture = () => {
  const calls: Array<{ method: string; params: Row }> = []
  let info: Row | null = null
  let delivery: Row | null = null
  let rows: Array<Row> = []
  let head = 0
  let cut = Infinity
  let lostCreate = false
  let lostQueue = false
  let outcome: unknown = { stopReason: "end_turn" }
  let outcomeError: Error | null = null
  let created = 0
  let queued = 0
  const rpc: MachineRpc = async (method, raw) => {
    const params = raw as Row
    calls.push({ method, params })
    if (method === "_acpmux/info") {
      if (!info) throw absent()
      return info
    }
    if (method === "session/new") {
      const meta = (params._meta as { acpmux: Row }).acpmux
      if (info) throw Object.assign(new Error("name taken"), { code: -32602 })
      created++
      info = { sessionId: "exact-session-id", name: meta.name, harness: meta.harness, cwd: params.cwd, policy: meta.policy, tags: meta.tags, createdAt: 42, stateSeq: 3 }
      if (lostCreate) { lostCreate = false; throw new Error("create reply lost") }
      return { sessionId: info.sessionId }
    }
    if (method === "_acpmux/send_queue") {
      const request = params.request as Row
      const prompt = ((request._meta as { acpmux: Row }).acpmux).promptId
      if (!delivery) {
        queued++
        delivery = { deliveryId: "delivery-id", target: request.sessionId, promptId: prompt, status: "delivered" }
      }
      if (lostQueue) { lostQueue = false; throw new Error("queue reply lost") }
      return delivery
    }
    if (method === "_acpmux/send_status") return delivery
    if (method === "_acpmux/events") {
      const after = params.afterSeq as number
      const found = rows.filter((r) => (r.seq as number) > after).slice(0, cut)
      const hasMore = rows.filter((r) => (r.seq as number) > after).length > found.length
      return { events: found, hasMore, lastSeq: head, pageThrough: hasMore ? found.at(-1)?.seq : head, createdAt: info?.createdAt }
    }
    if (method === "_acpmux/wait") {
      if ((params.until as Array<string>)[0] !== "promptOutcome") return { timedOut: true }
      if (outcomeError) throw outcomeError
      return outcome
    }
    if (method === "_acpmux/kill") return {}
    throw new Error(`unexpected ${method}`)
  }
  return {
    rpc, calls, created: () => created, queued: () => queued,
    loseCreate: () => { lostCreate = true }, loseQueue: () => { lostQueue = true },
    info: () => info!, delivery: () => delivery!,
    page: (events: Array<Row>, last = events.at(-1)?.seq as number ?? 0, limit = Infinity) => { rows = events; head = last; cut = limit },
    outcome: (value: unknown) => { outcome = value }, outcomeError: (value: Error) => { outcomeError = value },
    prompt: () => delivery?.promptId,
  }
}
const event = (seq: number, kind: string, msg: unknown = {}, dir = "mux"): Row => ({ sessionId: "exact-session-id", seq, at: seq, dir, kind, msg })
const text = (seq: number, value: string): Row => event(seq, "notification", { method: "session/update", params: { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: value } } } }, "in")

describe("durable default-machine ACP adapter", () => {
  it("reconciles a lost create reply and sends one stable scoped prompt", async () => {
    const f = fixture()
    f.loseCreate()
    const first = await startMachineAgent(f.rpc, args)
    const second = await startMachineAgent(f.rpc, args)
    expect(second).toEqual(first)
    expect(f.created()).toBe(1)
    expect(f.queued()).toBe(1)
    const queue = f.calls.find((c) => c.method === "_acpmux/send_queue")!.params.request as Row
    expect(queue.sessionId).toBe("exact-session-id")
    expect(queue.prompt).toEqual([{ type: "text", text: args.prompt }])
    expect((queue._meta as { acpmux: Row }).acpmux).toMatchObject({ steer: false, resend: true })
  })

  it("joins a persisted delivery after its first response was lost", async () => {
    const f = fixture()
    f.loseQueue()
    await expect(startMachineAgent(f.rpc, args)).rejects.toThrow("queue reply lost")
    const recovered = await startMachineAgent(f.rpc, args)
    expect(recovered.session).toContain("delivery-id")
    expect(f.created()).toBe(1)
    expect(f.queued()).toBe(1)
  })

  it("does not create on an ambiguous lookup and refuses a changed request under the same key", async () => {
    const f = fixture()
    await expect(startMachineAgent(async () => { throw new Error("lookup timed out") }, args)).rejects.toThrow("lookup timed out")
    await startMachineAgent(f.rpc, args)
    await expect(startMachineAgent(f.rpc, { ...args, prompt: "different build" })).rejects.toThrow("protocol_invalid")
    expect(f.created()).toBe(1)
    expect(f.queued()).toBe(1)
  })

  it("marks only a definitive refused create as safe for a fresh auth check", async () => {
    const f = fixture()
    const refused: MachineRpc = async (method, params, ms, feature) => {
      if (method === "session/new") throw Object.assign(new Error("auth required"), { code: -32000 })
      return f.rpc(method, params, ms, feature)
    }
    await expect(startMachineAgent(refused, args)).rejects.toMatchObject({ beforePrompt: true, code: -32000 })
    expect(f.queued()).toBe(0)
    const uncertain: MachineRpc = async (method, params, ms, feature) => {
      if (method === "session/new") throw new Error("chief.machine.transport_unavailable")
      return f.rpc(method, params, ms, feature)
    }
    await expect(startMachineAgent(uncertain, args)).rejects.not.toHaveProperty("beforePrompt")
    expect(f.queued()).toBe(0)
  })

  it("rejects a returned alias, changed policy, or replacement journal before reading output", async () => {
    for (const mutation of [{ sessionId: "replacement-id" }, { createdAt: 99 }, { policy: "ask" }, { harness: "codex" }]) {
      const f = fixture()
      const started = await startMachineAgent(f.rpc, args)
      Object.assign(f.info(), mutation)
      await expect(machineAgentEvents(f.rpc, started.session, 0, 0)).rejects.toThrow("protocol_invalid")
      expect(f.calls.filter((c) => c.method === "_acpmux/events")).toHaveLength(0)
    }
  })

  it("keeps full long text across pages and advances through unmapped journal records", async () => {
    const f = fixture()
    const started = await startMachineAgent(f.rpc, args)
    const large = "x".repeat(600_000)
    f.page([text(1, large), event(2, "usage"), text(3, "https://hello.example.test"), event(4, "turn_result", { promptId: f.prompt() })], 9, 2)
    const one = await machineAgentEvents(f.rpc, started.session, 0, 0)
    expect(one.events.map((e) => e.event)).toEqual([{ kind: "text", text: large }])
    expect(one.last_seq).toBe(2)
    expect(one.head_seq).toBe(9)
    const two = await machineAgentEvents(f.rpc, started.session, one.last_seq, 0)
    expect(two.events.map((e) => e.event)).toEqual([{ kind: "text", text: "https://hello.example.test" }, { kind: "turn_end", stop_reason: "end_turn" }])
    expect(two.last_seq).toBe(9)
  })

  it("ignores replayed and subagent text, and waits for the original durable result", async () => {
    const f = fixture()
    const started = await startMachineAgent(f.rpc, args)
    const subagent = text(2, "child words")
    const childParams = (subagent.msg as { params: Row }).params
    childParams._meta = { acpmux: { subagent: null } }
    f.page([{ ...text(1, "replayed"), kind: "notification.replay" }, subagent, event(3, "turn_end", { stopReason: "end_turn" })])
    expect((await machineAgentEvents(f.rpc, started.session, 0, 0)).events).toEqual([])
    f.page([event(4, "turn_result", { promptId: f.prompt() })])
    f.outcomeError(Object.assign(new Error("the original run failed"), { code: -32000 }))
    expect((await machineAgentEvents(f.rpc, started.session, 3, 0)).events[0]?.event).toEqual({ kind: "error", message: "The machine agent failed.", code: -32000 })
  })

  it("waits past unbound turn_error for the exact prompt's authoritative auth refusal", async () => {
    for (const kind of ["auth.signed_out", "auth.expired"]) {
      const f = fixture()
      const started = await startMachineAgent(f.rpc, args)
      f.page([event(1, "turn_error", { code: -32603, errorKind: kind })])
      expect((await machineAgentEvents(f.rpc, started.session, 0, 0)).events).toEqual([])
      f.page([event(2, "turn_result", { promptId: "some-other-prompt", status: "failed", code: -32603, errorKind: kind })])
      expect((await machineAgentEvents(f.rpc, started.session, 1, 0)).events).toEqual([])
      f.page([event(3, "turn_result", { promptId: f.prompt(), status: "failed", code: -32603, errorKind: kind })])
      f.outcomeError(Object.assign(new Error("provider refused the original prompt"), { code: -32603 }))
      expect((await machineAgentEvents(f.rpc, started.session, 2, 0)).events[0]?.event).toEqual({ kind: "error", message: "The machine agent failed.", code: -32603, error_kind: kind })
    }
  })

  it("does not infer auth from error text, unrelated kinds or an inconsistent prompt outcome", async () => {
    for (const [kind, code] of [["agent.exited", -32603], ["auth.signed_out", -32000], [undefined, -32603]] as const) {
      const f = fixture()
      const started = await startMachineAgent(f.rpc, args)
      f.page([event(1, "turn_result", { promptId: f.prompt(), status: "failed", code: -32603, errorKind: kind, errorText: "Not logged in" })])
      f.outcomeError(Object.assign(new Error("Not logged in"), { code }))
      expect((await machineAgentEvents(f.rpc, started.session, 0, 0)).events[0]?.event).toEqual({ kind: "error", message: "The machine agent failed.", code })
    }
  })

  it("uses one bounded condition wait and preserves the journal on stop", async () => {
    const f = fixture()
    const started = await startMachineAgent(f.rpc, args)
    f.page([], 0)
    await machineAgentEvents(f.rpc, started.session, 0, 1000)
    expect(f.calls.find((c) => c.method === "_acpmux/wait")?.params).toEqual({ sessions: ["exact-session-id"], until: ["ready", "permission", "closed"], afterSeq: { "exact-session-id": 3 }, timeoutMs: 1000 })
    await stopMachineAgent(f.rpc, started.session)
    expect(f.calls.at(-1)).toEqual({ method: "_acpmux/kill", params: { sessionId: "exact-session-id", purge: false } })
  })

  it("reports a durable delivery refusal and never declares cancellation a successful build", async () => {
    const f = fixture()
    const started = await startMachineAgent(f.rpc, args)
    f.delivery().status = "failed"
    expect((await machineAgentEvents(f.rpc, started.session, 0, 0)).events[0]?.event.kind).toBe("error")
    f.delivery().status = "delivered"
    f.page([event(1, "turn_result", { promptId: f.prompt() })])
    f.outcome({ stopReason: "cancelled" })
    expect((await machineAgentEvents(f.rpc, started.session, 0, 0)).events[0]?.event).toEqual({ kind: "error", message: "The machine build was cancelled." })
    f.outcome({ stopReason: "end_turn" })
    f.page([event(1, "turn_result", { promptId: f.prompt(), status: "cancelled" })])
    expect((await machineAgentEvents(f.rpc, started.session, 0, 0)).events[0]?.event.kind).toBe("error")
  })
})
