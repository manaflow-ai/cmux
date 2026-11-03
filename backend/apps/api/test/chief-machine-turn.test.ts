import { describe, expect, it, vi } from "vitest"
import { machineAuthState, machineHarness, machineSignInURL, runMachineAgent, type MachineAgentPorts, type MachineState } from "../src/chief-brain/brain-machine.ts"
import type { StoredEvent } from "../src/hand-wire.ts"
import { env } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import type { ChiefBrainDO } from "../src/chief-brain/brain-do.ts"
import type { Env } from "../src/env.ts"
import { personalTeamIdFor } from "../src/domains/user.ts"
import type { DefaultChiefMachine } from "../src/chief-default-hand.ts"

const fixture = (initial: MachineState | null = null) => {
  let state = initial
  const events: Array<StoredEvent> = [
    { seq: 1, session: "machine-session", at: 1, event: { kind: "text", text: "Built the hello page at https://hello.example.test" } },
    { seq: 2, session: "machine-session", at: 2, event: { kind: "turn_end", stop_reason: "end_turn" } },
  ]
  const ports: MachineAgentPorts = {
    load: () => state, save: (s) => { state = structuredClone(s) },
    authorize: vi.fn(async () => undefined), auth: vi.fn(async () => "ready" as const),
    start: vi.fn(async () => ({ ok: true as const, value: { session: "machine-session" } })),
    events: vi.fn(async (_session, after) => ({ ok: true as const, value: { events: events.filter((e) => e.seq > after), last_seq: 2, head_seq: 2 } })),
    stop: vi.fn(async () => undefined), event: vi.fn(), now: () => 100,
  }
  return { ports, state: () => state }
}

describe("default Chief machine turn", () => {
  it("runs the original build on the hand with its own provider route and returns its result", async () => {
    const f = fixture()
    expect(await runMachineAgent(f.ports, "hand_a", "/home/cmux/proj", "claude", "build me a hello page", "scoped-run", 1000)).toEqual({ ok: true, text: "Built the hello page at https://hello.example.test" })
    expect(f.ports.start).toHaveBeenCalledExactlyOnceWith({ operation: "scoped-run", harness: "claude", cwd: "/home/cmux/proj", prompt: "build me a hello page" })
    expect(f.ports.authorize).toHaveBeenCalledTimes(3)
    expect(f.state()?.phase).toBe("done")
    expect(f.ports.stop).toHaveBeenCalledWith("machine-session")
  })

  it("keeps the request pending while signed out and executes nothing on repeated wakes", async () => {
    const f = fixture()
    f.ports.auth = vi.fn(async () => "signed_out")
    expect(await runMachineAgent(f.ports, "hand_a", "/home/cmux/proj", "codex", "build me X", "scoped-run", 1000)).toEqual({ pending: "auth" })
    expect(await runMachineAgent(f.ports, "hand_a", "/home/cmux/proj", "codex", "build me X", "scoped-run", 1000)).toEqual({ pending: "auth" })
    expect(f.ports.start).not.toHaveBeenCalled()
    expect(f.state()).toMatchObject({ phase: "waiting_auth", after: 0 })
  })

  it("reconciles the same durable operation when a start response was lost", async () => {
    const f = fixture()
    const start = vi.fn<MachineAgentPorts["start"]>().mockRejectedValueOnce(new Error("connection lost after dispatch")).mockResolvedValue({ ok: true, value: { session: "machine-session" } })
    f.ports.start = start
    expect(await runMachineAgent(f.ports, "hand_a", "/home/cmux/proj", "claude", "build me X", "scoped-run", 1000)).toEqual({ pending: "provisioning" })
    expect(f.state()?.phase).toBe("dispatching")
    expect(await runMachineAgent(f.ports, "hand_a", "/home/cmux/proj", "claude", "build me X", "scoped-run", 1000)).toMatchObject({ ok: true })
    expect(start.mock.calls[0]).toEqual(start.mock.calls[1])
    expect(start.mock.calls[0]?.[0].operation).toBe("scoped-run")
  })

  it("resumes a known session from the durable cursor without starting a second build", async () => {
    const f = fixture({ phase: "running", operation: "scoped-run", hand: "hand_a", cwd: "/home/cmux/proj", session: "machine-session", after: 1, text: "Built the hello page at https://hello.example.test" })
    expect(await runMachineAgent(f.ports, "hand_a", "/home/cmux/proj", "claude", "build me X", "scoped-run", 1000)).toEqual({ ok: true, text: "Built the hello page at https://hello.example.test" })
    expect(f.ports.start).not.toHaveBeenCalled()
    expect(f.ports.events).toHaveBeenCalledWith("machine-session", 1, 900)
  })

  it("resumes event reads after a lost transport reply and stops a timed-out session", async () => {
    const f = fixture({ phase: "running", operation: "scoped-run", hand: "hand_a", cwd: "/home/cmux/proj", session: "machine-session", after: 1, text: "The build is running" })
    f.ports.events = vi.fn(async () => { throw new Error("chief.machine.transport_unavailable") })
    expect(await runMachineAgent(f.ports, "hand_a", "/home/cmux/proj", "claude", "build me X", "scoped-run", 1000)).toEqual({ pending: "provisioning" })
    expect(f.state()).toMatchObject({ phase: "running", after: 1 })
    expect(await runMachineAgent(f.ports, "hand_a", "/home/cmux/proj", "claude", "build me X", "scoped-run", 99)).toEqual({ ok: false, reason: "chief.machine.timeout" })
    expect(f.ports.stop).toHaveBeenCalledWith("machine-session")
  })

  it("rejects revoked authority before execution and does not confuse unknown with signed out", async () => {
    const refused = fixture()
    refused.ports.authorize = vi.fn(async () => { throw new Error("revoked") })
    await expect(runMachineAgent(refused.ports, "hand_a", "/home/cmux/proj", "claude", "build me X", "scoped-run", 1000)).rejects.toThrow("revoked")
    expect(refused.ports.start).not.toHaveBeenCalled()
    const unknown = fixture()
    unknown.ports.auth = vi.fn(async () => "unknown")
    expect(await runMachineAgent(unknown.ports, "hand_a", "/home/cmux/proj", "claude", "build me X", "scoped-run", 1000)).toMatchObject({ ok: true })
  })

  it("fails explicitly on permission requests and preserves the owner's restrictions", async () => {
    const f = fixture()
    f.ports.events = vi.fn(async () => ({ ok: true, value: { events: [{ seq: 1, session: "machine-session", at: 1, event: { kind: "permission" as const, permission_id: "p1" } }], last_seq: 1, head_seq: 1 } }))
    expect(await runMachineAgent(f.ports, "hand_a", "/home/cmux/proj", "claude", "build me X", "scoped-run", 1000)).toEqual({ ok: false, reason: "chief.machine.permission_required" })
    expect(f.ports.stop).toHaveBeenCalledWith("machine-session")
  })

  it("does not discard a long build reply or the URL it contains", async () => {
    const f = fixture()
    const text = "x".repeat(100_000) + "\nhttps://hello.example.test"
    f.ports.events = vi.fn(async () => ({ ok: true, value: { events: [{ seq: 1, session: "machine-session", at: 1, event: { kind: "text" as const, text } }, { seq: 2, session: "machine-session", at: 2, event: { kind: "turn_end" as const } }], last_seq: 2, head_seq: 2 } }))
    expect(await runMachineAgent(f.ports, "hand_a", "/home/cmux/proj", "claude", "build me X", "scoped-run", 1000)).toEqual({ ok: true, text })
  })

  it("accepts only provider sign-in pages and rejects credential-bearing or unrelated URLs", () => {
    expect(machineSignInURL("https://claude.ai/oauth/authorize?client_id=abc", "claude")).toBe("https://claude.ai/oauth/authorize?client_id=abc")
    expect(machineSignInURL("https://auth.openai.com/codex/device", "codex")).toBe("https://auth.openai.com/codex/device")
    for (const url of ["https://evil.test/oauth/authorize", "https://claude.ai/settings", "https://user:pass@claude.ai/oauth/authorize", "https://auth.openai.com/codex/device"]) expect(machineSignInURL(url, "claude")).toBeNull()
  })

  it("offers sign-in for a fresh image's conclusive own-auth check, while unknown stays unknown", () => {
    expect(machineAuthState({ state: "signedOut", source: "authCheck" })).toBe("signed_out")
    expect(machineAuthState({ state: "expired", source: "turn" })).toBe("signed_out")
    expect(machineAuthState({ state: "unknown", source: "none" })).toBe("unknown")
    expect(machineAuthState({ state: "signedOut", source: "none" })).toBe("unknown")
    expect(machineAuthState({ state: "routeUnreachable", source: "routeProbe" })).toBe("unknown")
    expect(machineAuthState({ state: "ready", source: "authCheck" })).toBe("ready")
  })

  it("uses only provider-backed Claude/Codex harnesses", () => {
    expect(machineHarness(null)).toBe("claude")
    expect(machineHarness("codex")).toBe("codex")
    expect(machineHarness("claude-sr")).toBeNull()
    expect(machineHarness("opencode")).toBeNull()
  })
})

describe("default Chief activation", () => {
  const activation = async (suffix: string, check: (b: ChiefBrainDO, chief: { id: string; owner_user: string; cloud_machine: DefaultChiefMachine | null }) => Promise<void>) => {
    const testEnv = env as unknown as Env
    const owner = `user_machine_${suffix}`, agent = `agent_machine_${suffix}`
    const binding = { workspace: `chief-default-${owner}`, team: personalTeamIdFor(owner), machine: "machine_default", provider: "freestyle", connection_machine: "vm_abcdefghijklmnopqrst", install: "inst_default" }
    const chief = { id: agent, owner_user: owner, display_name: "Chief", is_default: false, is_hosted_default: true, archived_at: null, brain_place: null, harness: null, cloud_machine: null as DefaultChiefMachine | null }
    const fake = {
      ...testEnv,
      CHIEF_BRAIN_ENABLED: "1", HANDS_ENABLED: "1",
      USER_DO: { idFromName: (x: string) => x, get: () => ({ readOp: async (_entity: string, _principal: unknown, op: string) => ({ ok: true, revision: "user:1", value: op === "chief.list" ? { chiefs: [chief] } : { installs: [{ id: binding.install, kind: "vm", grant: "grant_default", revoked_at: null, bound_team: binding.team, bound_machine: binding.connection_machine }], grants: [{ id: "grant_default", grantee: binding.install, revoked_at: null, expires_at: null, op_classes: ["vm-self"] }] } }) }) },
      CLOUD_DO: { idFromName: (x: string) => x, get: () => ({ readOp: async () => ({ ok: true, revision: "cloud:1", value: { machine: { creator: owner, status: "paused" } } }) }) },
    } as unknown as Env
    const stub = testEnv.CHIEF_BRAIN_DO.get(testEnv.CHIEF_BRAIN_DO.idFromName(agent))
    const inDO = runInDurableObject as unknown as <T>(stub: unknown, cb: (b: ChiefBrainDO) => Promise<T>) => Promise<T>
    await inDO(stub, async (b) => {
      const object = b as unknown as { env: Env }
      const original = object.env
      object.env = fake
      try { await check(b, chief) } finally { object.env = original }
    })
  }

  it("adopts the fixed hosted Chief, holds the first turn until binding, then clears pending", async () => {
    await activation("bind", async (b, chief) => {
      expect(await b.activateDefault(chief.id, chief.owner_user)).toMatchObject({ ok: true, config: { enabled: true } })
      expect(await b.admit(chief.id, chief.owner_user, false)).toEqual({ ok: false, reason: "provisioning_pending" })
      chief.cloud_machine = { workspace: `chief-default-${chief.owner_user}`, team: personalTeamIdFor(chief.owner_user), machine: "machine_default", provider: "freestyle", connection_machine: "vm_abcdefghijklmnopqrst", install: "inst_default" }
      expect(await b.activateDefault(chief.id, chief.owner_user)).toMatchObject({ ok: true, machine: { harness: "claude" } })
      expect(b.sql.exec(`SELECT 1 FROM cb_config WHERE name = 'default_machine_pending'`).toArray()).toEqual([])
      expect(await b.admit(chief.id, chief.owner_user, true)).toMatchObject({ ok: true, machine: { harness: "claude" } })
    })
  })

  it("never enables a Chief whose owner explicitly disabled it", async () => {
    await activation("disabled", async (b, chief) => {
      b.sql.exec(`INSERT INTO cb_config (name, value) VALUES ('enabled', '0')`)
      expect(await b.activateDefault(chief.id, chief.owner_user)).toEqual({ ok: false, reason: "disabled" })
      expect(b.config().enabled).toBe(false)
      expect(b.sql.exec(`SELECT 1 FROM cb_config WHERE name = 'default_machine_pending'`).toArray()).toEqual([])
    })
  })

  it("keeps an existing enabled hosted Chief on its current route until machine binding", async () => {
    await activation("enabled", async (b, chief) => {
      b.sql.exec(`INSERT INTO cb_config (name, value) VALUES ('enabled', '1')`)
      expect(await b.activateDefault(chief.id, chief.owner_user)).toMatchObject({ ok: true })
      expect(b.sql.exec(`SELECT 1 FROM cb_config WHERE name = 'default_machine_pending'`).toArray()).toEqual([])
    })
  })
})
