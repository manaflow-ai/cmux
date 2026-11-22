import { DatabaseSync } from "node:sqlite"
import { describe, expect, it } from "vitest"
import { machineWakeAt, openWake, placedMachine, readWake, stepWake, wakeStep, type WakeCloud, type WakeRow, type WakeView } from "../src/mux-machine-wake.ts"

// Wake on message for a Chief on its own Cloud machine (RFD 0037): MuxDO's row, with a fake CloudDO.

const sqlOf = (): SqlStorage => {
  const db = new DatabaseSync(":memory:")
  return {
    exec: (query: string, ...args: Array<unknown>) => {
      const st = db.prepare(query)
      const rows = /^\s*(SELECT|INSERT|UPDATE|DELETE)/i.test(query) && /^\s*SELECT/i.test(query) ? st.all(...(args as Array<never>)) : (st.run(...(args as Array<never>)), [])
      return { toArray: () => rows, one: () => rows[0] }
    }
  } as unknown as SqlStorage
}

const fakeCloud = (statuses: Array<string | Error>) => {
  const calls: Array<string> = []
  const cloud: WakeCloud = {
    readOp: async (_e, _p, op) => {
      calls.push(op)
      const s = statuses.length > 1 ? statuses.shift()! : statuses[0]!
      if (s instanceof Error) throw s
      return { ok: true, value: { status: s }, revision: "7" }
    },
    submit: async (_e, _p, frame) => {
      calls.push(`${frame.op} ${frame.idempotency_key}`)
      return { frames: [{ t: "result", value: {} }] } as never
    }
  }
  return { calls, cloud: () => cloud }
}

const viewOf = () => {
  const seen: Array<string> = []
  const view: WakeView = { waking: async (r: WakeRow) => void seen.push(`waking ${r.conversation}`), ended: async (r: WakeRow) => void seen.push(`ended ${r.conversation}`) }
  return { seen, view }
}

const place = { machine: "vm_1", team: "team_1" }

describe("mux machine wake", () => {
  it("reads only a place that names its machine and team", () => {
    expect(placedMachine({ host: "h", install: "i" })).toBeNull()
    expect(placedMachine({ host: "h", install: "i", machine: "vm_1", team: "team_1" })).toEqual(place)
    expect(placedMachine(null)).toBeNull()
  })

  it("starts a paused machine, shows Waking, and ends the line when the host acks", async () => {
    const sql = sqlOf()
    const { calls, cloud } = fakeCloud(["paused", "starting", "running"])
    const { seen, view } = viewOf()
    openWake(sql, place, "conv_a", 1_000)
    await stepWake(sql, cloud, view, "agent_1", "user_1", 1, 1_000)
    expect(calls).toContain("cloud.machine.start chief-machine-wake:agent_1:vm_1:7")
    expect(seen).toEqual(["waking conv_a"])
    expect(machineWakeAt(sql)).toBe(6_000)
    await stepWake(sql, cloud, view, "agent_1", "user_1", 1, 6_000)
    await stepWake(sql, cloud, view, "agent_1", "user_1", 1, 11_000)
    expect(readWake(sql)?.running_at).toBe(11_000)
    // The host acked: no wake left.
    await stepWake(sql, cloud, view, "agent_1", "user_1", 0, 13_000)
    expect(seen).toEqual(["waking conv_a", "ended conv_a"])
    expect(readWake(sql)).toBeNull()
  })

  it("does nothing for a machine that already runs", async () => {
    const sql = sqlOf()
    const { calls, cloud } = fakeCloud(["running"])
    const { seen, view } = viewOf()
    openWake(sql, place, "conv_a", 1_000)
    await stepWake(sql, cloud, view, "agent_1", "user_1", 1, 1_000)
    expect(seen).toEqual([])
    expect(calls).toEqual(["cloud.machine.get"])
    expect(readWake(sql)).toBeNull()
  })

  it("backs off on a failed read and keeps the wake (the message stays queued)", async () => {
    const sql = sqlOf()
    const { cloud } = fakeCloud([new Error("owner.unreachable"), new Error("owner.unreachable"), "paused"])
    const { seen, view } = viewOf()
    openWake(sql, place, "conv_a", 1_000)
    await stepWake(sql, cloud, view, "agent_1", "user_1", 1, 1_000)
    expect(machineWakeAt(sql)).toBe(2_000)
    await stepWake(sql, cloud, view, "agent_1", "user_1", 1, 2_000)
    expect(machineWakeAt(sql)).toBe(4_000)
    expect(readWake(sql)?.tries).toBe(2)
    await stepWake(sql, cloud, view, "agent_1", "user_1", 1, 4_000)
    expect(readWake(sql)?.tries).toBe(0)
    expect(seen).toEqual(["waking conv_a"])
  })

  it("a second message while waking joins the same wake", () => {
    const sql = sqlOf()
    const first = openWake(sql, place, "conv_a", 1_000)
    const second = openWake(sql, place, "conv_b", 2_000)
    expect(second.run).toBe(first.run)
    expect(second.conversation).toBe("conv_a")
  })

  it("decides from the machine's status", () => {
    expect(wakeStep({ ok: true, value: { status: "paused" }, revision: "3" })).toEqual({ act: "start", revision: "3" })
    expect(wakeStep({ ok: true, value: { machine: { status: "running" } } })).toEqual({ act: "running" })
    expect(wakeStep({ ok: true, value: { status: "starting" } })).toEqual({ act: "wait" })
    expect(wakeStep({ ok: false, code: "auth.forbidden" })).toEqual({ act: "retry", error: "auth.forbidden" })
  })
})
