import { describe, expect, it, vi } from "vitest"
import { authorizeMachineHand, machineAuthState, machineHarness, machineLogin, machinePrompt, machineSignInURL, readMachineState, runMachineAgent, wakeDefaultMachine, type MachineAgentPorts, type MachineState } from "../src/chief-brain/brain-machine.ts"
import type { StoredEvent } from "../src/hand-wire.ts"
import { env } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import type { ChiefBrainDO } from "../src/chief-brain/brain-do.ts"
import type { Env } from "../src/env.ts"
import { personalTeamIdFor } from "../src/domains/user.ts"
import { defaultHandId, type DefaultChiefMachine, type DefaultHandScope } from "../src/chief-default-hand.ts"
import { writeConfig } from "../src/chief-brain/brain-store.ts"
import { createdAndBound, frame, person, reply } from "./cloud-bind-support.ts"
import type { Principal } from "@cmux/ownership"

describe("default machine wake against CloudDO", { timeout: 60_000 }, () => {
  const carrier = async () => {
    const x = person()
    const { machine, install } = await createdAndBound(x)
    const chief = `agent_machine_wake_${x.user}`
    const scope: DefaultHandScope = { owner: x.user, chief, workspace: `chief-default-${x.user}`, team: x.team, machine, provider: "fake", connection_machine: machine, install: install.id }
    const testEnv = env as unknown as Env
    const user = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(x.user))
    const fake = {
      ...testEnv,
      // The Chief binding is the only fixture. VM installs, authorization, reads and power
      // admission use the real UserDO and CloudDO, including their different read shapes.
      USER_DO: { idFromName: (name: string) => name, get: () => ({
        readOp: async (entity: string, principal: Principal, op: string, params: unknown) => op === "chief.list"
          ? { ok: true, value: { chiefs: [{ id: chief, owner_user: x.user, archived_at: null, brain_place: null, cloud_machine: scope }] } }
          : user.readOp(entity, principal, op, params),
      }) },
    } as unknown as Env
    return { x, scope, brain: { doEnv: fake } as ChiefBrainDO }
  }

  it("continues provisioning when the actual machine read is already running", async () => {
    const f = await carrier()
    expect(await f.x.stub.readOp(f.x.team, f.x.p, "cloud.machine.get", { machine: f.scope.connection_machine })).toMatchObject({ ok: true, value: { status: "running" } })
    await expect(wakeDefaultMachine(f.brain, f.scope)).resolves.toBe(true)
  })

  it("starts a paused carrier through CloudDO admission and observes it running", async () => {
    const f = await carrier()
    expect(reply(await f.x.stub.submit(f.x.team, f.x.p, frame("cloud.machine.pause", { machine: f.scope.connection_machine })))).toMatchObject({ t: "result" })
    expect(await f.x.stub.readOp(f.x.team, f.x.p, "cloud.machine.get", { machine: f.scope.connection_machine })).toMatchObject({ value: { status: "paused" } })
    await expect(wakeDefaultMachine(f.brain, f.scope)).resolves.toBe(false)
    await expect(wakeDefaultMachine(f.brain, f.scope)).resolves.toBe(true)
    expect(await f.x.stub.fakeControl({})).toMatchObject({ starts: 1, pauses: 1 })
  })
})

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
    f.ports.auth = vi.fn(async () => "signed_out" as const)
    expect(await runMachineAgent(f.ports, "hand_a", "/home/cmux/proj", "codex", "build me X", "scoped-run", 1000)).toEqual({ pending: "auth" })
    expect(await runMachineAgent(f.ports, "hand_a", "/home/cmux/proj", "codex", "build me X", "scoped-run", 1000)).toEqual({ pending: "auth" })
    expect(f.ports.start).not.toHaveBeenCalled()
    expect(f.state()).toMatchObject({ phase: "waiting_auth", after: 0 })
  })

  it("keeps the original request for sign-in when a definitive session refusal clarifies unknown auth", async () => {
    const f = fixture()
    f.ports.auth = vi.fn<MachineAgentPorts["auth"]>().mockResolvedValueOnce("unknown").mockResolvedValueOnce("signed_out")
    f.ports.start = vi.fn(async () => ({ ok: false as const, error: { code: "agent.start_failed", message: "Session refused before prompt dispatch" } }))
    expect(await runMachineAgent(f.ports, "hand_a", "/home/cmux/proj", "claude", "build me original X", "scoped-run", 1000)).toEqual({ pending: "auth" })
    expect(f.state()).toMatchObject({ operation: "scoped-run", phase: "waiting_auth" })
    expect(f.ports.start).toHaveBeenCalledOnce()
    expect(f.ports.events).not.toHaveBeenCalled()
  })

  it("keeps an accepted original request pending when its first turn proves signed out", async () => {
    for (const error_kind of ["auth.signed_out", "auth.expired"] as const) {
      const f = fixture()
      f.ports.auth = vi.fn(async () => "unknown" as const)
      f.ports.events = vi.fn(async () => ({ ok: true as const, value: { events: [{ seq: 46, session: "machine-session", at: 1, event: { kind: "error" as const, code: -32603, error_kind } }], last_seq: 46, head_seq: 46 } }))
      expect(await runMachineAgent(f.ports, "hand_a", "/home/cmux/proj", "claude", "build me original X", "scoped-run", 1000)).toEqual({ pending: "auth" })
      expect(f.state()).toMatchObject({ phase: "waiting_auth", operation: "scoped-run", session: "machine-session", after: 46, authRetrySafe: true })
      expect(await runMachineAgent(f.ports, "hand_a", "/home/cmux/proj", "claude", "build me original X", "scoped-run", 1000)).toEqual({ pending: "auth" })
      expect(f.ports.start).toHaveBeenCalledOnce()
      expect(f.ports.events).toHaveBeenCalledOnce()
      expect(f.ports.stop).toHaveBeenCalledWith("machine-session")
    }
  })

  it("never replays partial work, legacy uncertain work or generic errors as a sign-in retry", async () => {
    const prior: Array<MachineState | null> = [
      null,
      { phase: "running", operation: "scoped-run", hand: "hand_a", cwd: "/home/cmux/proj", session: "machine-session", after: 1, text: "" },
      { phase: "running", operation: "scoped-run", hand: "hand_a", cwd: "/home/cmux/proj", session: "machine-session", after: 1, text: "", authRetrySafe: false },
    ]
    for (const initial of prior) {
      const f = fixture(initial)
      f.ports.events = vi.fn(async () => ({ ok: true as const, value: { events: [{ seq: 2, session: "machine-session", at: 2, event: { kind: "error" as const, error_kind: initial ? "auth.expired" as const : undefined, message: "Not logged in" } }], last_seq: 2, head_seq: 2 } }))
      expect(await runMachineAgent(f.ports, "hand_a", "/home/cmux/proj", "claude", "build me X", "scoped-run", 1000)).toEqual({ ok: false, reason: "chief.machine.agent_error" })
      expect(f.state()?.phase).toBe("failed")
    }
    for (const activity of [{ kind: "text" as const, text: "Starting the build" }, { kind: "tool" as const, update: false, id: "write" }]) {
      const f = fixture()
      f.ports.events = vi.fn<MachineAgentPorts["events"]>().mockResolvedValueOnce({ ok: true, value: { events: [{ seq: 1, session: "machine-session", at: 1, event: activity }], last_seq: 1, head_seq: 2 } }).mockRejectedValueOnce(new Error("connection lost"))
      expect(await runMachineAgent(f.ports, "hand_a", "/home/cmux/proj", "claude", "build me X", "scoped-run", 1000)).toEqual({ pending: "provisioning" })
      expect(f.state()?.authRetrySafe).toBe(false)
      f.ports.events = vi.fn(async () => ({ ok: true as const, value: { events: [{ seq: 2, session: "machine-session", at: 2, event: { kind: "error" as const, error_kind: "auth.expired" as const } }], last_seq: 2, head_seq: 2 } }))
      expect(await runMachineAgent(f.ports, "hand_a", "/home/cmux/proj", "claude", "build me X", "scoped-run", 1000)).toEqual({ ok: false, reason: "chief.machine.agent_error" })
    }
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

  it("keeps the same session and cursor across a temporary Hand or authority-read outage", async () => {
    for (const reason of ["chief.machine.hand_offline", "chief.machine.owner_unavailable", "owner.unreachable"]) {
      const f = fixture({ phase: "running", operation: "scoped-run", hand: "hand_a", cwd: "/home/cmux/proj", session: "machine-session", after: 1, text: "The original result" })
      f.ports.authorize = vi.fn<MachineAgentPorts["authorize"]>().mockRejectedValueOnce(new Error(reason)).mockResolvedValue(undefined)
      expect(await runMachineAgent(f.ports, "hand_a", "/home/cmux/proj", "claude", "build me X", "scoped-run", 1000)).toEqual({ pending: "provisioning" })
      expect(f.state()).toMatchObject({ phase: "running", after: 1, text: "The original result" })
      expect(f.ports.events).not.toHaveBeenCalled()
      expect(await runMachineAgent(f.ports, "hand_a", "/home/cmux/proj", "claude", "build me X", "scoped-run", 1000)).toEqual({ ok: true, text: "The original result" })
      expect(f.ports.start).not.toHaveBeenCalled()
    }
  })

  it("rejects revoked authority before execution and does not confuse unknown with signed out", async () => {
    const refused = fixture()
    refused.ports.authorize = vi.fn(async () => { throw new Error("revoked") })
    await expect(runMachineAgent(refused.ports, "hand_a", "/home/cmux/proj", "claude", "build me X", "scoped-run", 1000)).rejects.toThrow("revoked")
    expect(refused.ports.start).not.toHaveBeenCalled()
    const unknown = fixture()
    unknown.ports.auth = vi.fn(async () => "unknown" as const)
    expect(await runMachineAgent(unknown.ports, "hand_a", "/home/cmux/proj", "claude", "build me X", "scoped-run", 1000)).toMatchObject({ ok: true })
  })

  it("rejects a revoked Hand even when its display info is ok and a session was saved", async () => {
    const f = fixture({ phase: "running", operation: "scoped-run", hand: "hand_a", cwd: "/home/cmux/proj", session: "machine-session", after: 1, text: "" })
    const scope = { owner: "user_revoked", chief: "agent_revoked", workspace: "chief-default-user_revoked", team: "team_revoked", machine: "machine_revoked", provider: "freestyle", connection_machine: "vm_abcdefghijklmnopqrst", install: "inst_revoked" }
    const fake = { HAND_DO: { idFromName: (x: string) => x, get: () => ({ info: async () => ({ ok: true, value: { revoked_at: Date.now(), paired_at: 1, level: "full", profile: "sandbox", online: true, hello: { profile: "sandbox", roots: ["/home/cmux/proj"] } } }) }) } } as unknown as Env
    f.ports.authorize = () => authorizeMachineHand(fake, scope, "/home/cmux/proj")
    await expect(runMachineAgent(f.ports, "hand_a", "/home/cmux/proj", "claude", "build me X", "scoped-run", 1000)).rejects.toThrow("hand.revoked")
    expect(f.ports.start).not.toHaveBeenCalled()
    expect(f.ports.events).not.toHaveBeenCalled()
  })

  it("fails explicitly on permission requests and preserves the owner's restrictions", async () => {
    const f = fixture()
    f.ports.events = vi.fn(async () => ({ ok: true as const, value: { events: [{ seq: 1, session: "machine-session", at: 1, event: { kind: "permission" as const, permission_id: "p1" } }], last_seq: 1, head_seq: 1 } }))
    expect(await runMachineAgent(f.ports, "hand_a", "/home/cmux/proj", "claude", "build me X", "scoped-run", 1000)).toEqual({ ok: false, reason: "chief.machine.permission_required" })
    expect(f.ports.stop).toHaveBeenCalledWith("machine-session")
  })

  it("does not discard a long build reply or the URL it contains", async () => {
    const f = fixture()
    const text = "x".repeat(100_000) + "\nhttps://hello.example.test"
    f.ports.events = vi.fn(async () => ({ ok: true as const, value: { events: [{ seq: 1, session: "machine-session", at: 1, event: { kind: "text" as const, text } }, { seq: 2, session: "machine-session", at: 2, event: { kind: "turn_end" as const } }], last_seq: 2, head_seq: 2 } }))
    expect(await runMachineAgent(f.ports, "hand_a", "/home/cmux/proj", "claude", "build me X", "scoped-run", 1000)).toEqual({ ok: true, text })
  })

  it("accepts only provider sign-in pages and rejects credential-bearing or unrelated URLs", () => {
    expect(machineSignInURL("https://claude.ai/oauth/authorize?client_id=abc", "claude")).toBe("https://claude.ai/oauth/authorize?client_id=abc")
    expect(machineSignInURL("https://auth.openai.com/codex/device", "codex")).toBe("https://auth.openai.com/codex/device")
    for (const url of ["https://evil.test/oauth/authorize", "https://claude.ai/settings", "https://user:pass@claude.ai/oauth/authorize", "https://auth.openai.com/codex/device"]) expect(machineSignInURL(url, "claude")).toBeNull()
  })

  it.each([
    "https://claude.com/cai/oauth/authorize?client_id=test-client&state=test-state",
    "https://claude.com/cai/oauth/authorize/?client_id=test-client",
  ])("accepts Claude Code's subscription sign-in page: %s", (url) => {
    expect(machineSignInURL(url, "claude")).toBe(url)
    expect(machineSignInURL(url, "codex")).toBeNull()
  })

  it.each([
    "https://claude.ai/cai/oauth/authorize",
    "https://platform.claude.com/cai/oauth/authorize",
    "https://auth.openai.com/cai/oauth/authorize",
    "https://claude.com.evil.test/cai/oauth/authorize",
    "https://claude.com/cai/oauth/authorize/extra",
    "https://claude.com/cai/oauth/authorize-lookalike",
    "https://claude.com/settings",
    "https://user:pass@claude.com/cai/oauth/authorize",
    "https://claude.com:8443/cai/oauth/authorize",
    "http://claude.com/cai/oauth/authorize",
  ])("rejects unrelated or unsafe subscription sign-in URLs: %s", (url) => {
    expect(machineSignInURL(url, "claude")).toBeNull()
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

  it("gives the machine its configured Chief identity and a verifiable preview workflow", () => {
    const prompt = machinePrompt({ display_name: "Builder", role: "Build useful apps", personality: "Concise", instructions: "Use accessible controls" }, { workspace: "workspace_a", team: "team_a", machine: "machine_a", provider: "freestyle", connection_machine: "vm_abcdefghijklmnopqrst", install: "inst_a" }, "/home/cmux/proj", ["build me a hello page"])
    expect(prompt).toContain('"name":"Builder","role":"Build useful apps","personality":"Concise"')
    expect(prompt).toContain("Use accessible controls")
    expect(prompt).toContain("build me a hello page")
    expect(prompt).toContain("0.0.0.0")
    expect(prompt).toContain("Fetch the returned URL and read the response")
    expect(prompt).toContain("never guess a hostname")
    expect(prompt).not.toContain("spawn(tasks) starts subagents")
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

  it("retries a failed Chief-record read rather than treating it as an archived Chief", async () => {
    await activation("unavailable", async (b, chief) => {
      const object = b as unknown as { env: Env }, original = object.env
      object.env = { ...original, USER_DO: { idFromName: (name: string) => name, get: () => ({ readOp: async () => ({ ok: false, code: "owner.unreachable", message: "temporary owner failure" }) }) } } as unknown as Env
      try { expect(await b.admit(chief.id, chief.owner_user, false)).toEqual({ ok: false, reason: "owner.unreachable" }) } finally { object.env = original }
    })
  })
})

describe("default machine sign-in recovery", () => {
  const recovery = async (suffix: string, check: (b: ChiefBrainDO, f: {
    owner: string; run: string; calls: Array<string>; timeouts: Array<number>; kick: ReturnType<typeof vi.fn>;
    auth: "ready" | "signedOut"; revoked: boolean; enabled: boolean; revokeDuringAuth: boolean;
  }) => Promise<void>) => {
    const testEnv = env as unknown as Env
    const owner = `user_login_${suffix}`, chief = `agent_login_${suffix}`, run = "run_login"
    const binding = { workspace: `chief-default-${owner}`, team: personalTeamIdFor(owner), machine: "machine_default", provider: "freestyle", connection_machine: "vm_abcdefghijklmnopqrst", install: "inst_default" }
    const scope = { ...binding, owner, chief }, hand = defaultHandId(scope), cwd = "/home/cmux/proj"
    const route = { binding, harness: "claude" as const }
    const f = { owner, run, calls: [] as Array<string>, timeouts: [] as Array<number>, kick: vi.fn(), auth: "signedOut" as "ready" | "signedOut", revoked: false, enabled: true, revokeDuringAuth: false }
    const fake = {
      ...testEnv,
      USER_DO: { idFromName: (x: string) => x, get: () => ({ readOp: async (_e: string, _p: unknown, op: string) => ({ ok: true, revision: "user:1", value: op === "chief.list" ? { chiefs: [{ id: chief, owner_user: owner, archived_at: null, brain_place: null, cloud_machine: binding }] } : { installs: [{ id: binding.install, kind: "vm", grant: "grant_default", revoked_at: null, bound_team: binding.team, bound_machine: binding.connection_machine }], grants: [{ id: "grant_default", grantee: binding.install, revoked_at: null, expires_at: null, op_classes: ["vm-self"] }] } }) }) },
      HAND_DO: { idFromName: (x: string) => x, get: () => ({ info: async () => ({ ok: true, value: { revoked_at: f.revoked ? 1 : null, paired_at: 1, level: "full", profile: "sandbox", online: true, hello: { profile: "sandbox", roots: [cwd] } } }) }) },
      CLOUD_DO: { idFromName: (x: string) => x, get: () => ({
        readOp: async () => ({ ok: true, revision: "cloud:1", value: { machine: { creator: owner, status: "running" } } }),
        automationExec: async (_e: string, _owner: string, _machine: string, _command: string, stdin: Uint8Array, timeout: number) => {
          const request = JSON.parse(new TextDecoder().decode(stdin).trim().split("\n")[1]!) as { method: string }
          f.calls.push(request.method)
          f.timeouts.push(timeout)
          if (request.method === "_acpmux/agent_login/finish") {
            f.auth = "ready" // The guest saved credentials, but its successful reply was lost.
            return { ok: false, refusal: "provider_failed" }
          }
          if (f.revokeDuringAuth) f.revoked = true
          return { ok: true, exitCode: 0, stdout: JSON.stringify({ id: 1, result: { _meta: { acpmux: { features: ["sessionAuth", "agent_login"] } } } }) + "\n" + JSON.stringify({ id: 2, result: { state: f.auth, source: "authCheck" } }) + "\n", stderr: "" }
        },
      }) },
    } as unknown as Env
    const stub = testEnv.CHIEF_BRAIN_DO.get(testEnv.CHIEF_BRAIN_DO.idFromName(`${chief}/recovery`))
    const inDO = runInDurableObject as unknown as <T>(stub: unknown, cb: (b: ChiefBrainDO) => Promise<T>) => Promise<T>
    await inDO(stub, async (b) => {
      const object = b as unknown as { doEnv: Env }, original = object.doEnv
      object.doEnv = fake
      const admission = vi.spyOn(b, "admitted").mockImplementation(async () => f.enabled ? { ok: true, config: b.config(), machine: route } : { ok: false, reason: "disabled" })
      const kick = vi.spyOn(b, "kick").mockImplementation(f.kick)
      writeConfig(b.sql, { agent: chief, owner, enabled: "1", machine_route: JSON.stringify(route), [`machine:${run}`]: JSON.stringify({ phase: "waiting_auth", operation: `${owner}/${chief}/recovery/${run}`, hand, cwd, after: 0, text: "" }), [`machine-login:${run}`]: JSON.stringify({ loginId: "consumed-guest-login", url: "https://claude.ai/oauth/authorize", needsCode: true, expiresAtMs: Date.now() + 60_000 }) })
      b.sql.exec(`INSERT INTO cb_turn (id, conversation, trigger_message, trigger_kind, last_seq, effect_authorized, status, model, started, input) VALUES (?, 'recovery', 'original', 'chief', 1, 1, 'running', 'machine:claude', 1, ?)`, run, '["build me the original hello page"]')
      try { await check(b, f) } finally { object.doEnv = original; admission.mockRestore(); kick.mockRestore() }
    })
  }

  it("recovers an explicit finish after its successful guest response was lost and kicks once", async () => {
    await recovery("lost", async (b, f) => {
      await expect(machineLogin(b, f.owner, f.run, "finish", { loginId: "consumed-guest-login", code: "one-use-private-code" })).rejects.toThrow("transport_unavailable")
      expect(readMachineState(b.sql, f.run)?.phase).toBe("waiting_auth")
      expect(await machineLogin(b, f.owner, f.run, "finish", { loginId: "consumed-guest-login" })).toEqual({ signedIn: true, resumed: true })
      expect(await machineLogin(b, f.owner, f.run, "finish", { loginId: "consumed-guest-login" })).toEqual({ signedIn: true, resumed: true })
      expect(f.calls).toEqual(["_acpmux/session/auth", "_acpmux/agent_login/finish", "_acpmux/session/auth"])
      expect(f.timeouts.every((timeout) => timeout <= 300_000)).toBe(true)
      expect(f.kick).toHaveBeenCalledOnce()
      expect(readMachineState(b.sql, f.run)).toMatchObject({ phase: "dispatching", attempt: 1, after: 0, authRetrySafe: true })
      expect(b.sql.exec<{ input: string }>(`SELECT input FROM cb_turn WHERE id = ?`, f.run).one().input).toBe('["build me the original hello page"]')
      expect(JSON.stringify(b.sql.exec(`SELECT * FROM cb_config`).toArray())).not.toContain("one-use-private-code")
    })
  })

  it("durably changes the rejected attempt after login and retries a lost dispatch without replaying it", async () => {
    await recovery("accepted", async (b, f) => {
      const original = readMachineState(b.sql, f.run)!
      writeConfig(b.sql, { [`machine:${f.run}`]: JSON.stringify({ ...original, session: "rejected-session", after: 46, authRetrySafe: true }) })
      f.auth = "ready"
      expect(await machineLogin(b, f.owner, f.run, "finish", { loginId: "consumed-guest-login" })).toEqual({ signedIn: true, resumed: true })
      const resumed = readMachineState(b.sql, f.run)!
      expect(resumed).toMatchObject({ phase: "dispatching", operation: original.operation, attempt: 1, after: 0, text: "" })
      expect(resumed.session).toBeUndefined()
      const run = fixture(resumed)
      const executions = new Set<string>([original.operation]) // The old ledger replays its settled auth failure.
      const start = vi.fn<MachineAgentPorts["start"]>().mockImplementation(async (request) => {
        expect(readMachineState(b.sql, f.run)?.attempt).toBe(1) // Saved before dispatch.
        if (request.operation === original.operation) return { ok: false, error: { code: "cached_auth_failure", message: "old prompt replayed" } }
        if (!executions.has(request.operation)) { executions.add(request.operation); throw new Error("accepted but response lost") }
        return { ok: true, value: { session: "machine-session" } }
      })
      run.ports.start = start
      expect(await runMachineAgent(run.ports, original.hand, original.cwd, "claude", "build me original X", original.operation, 1000)).toEqual({ pending: "provisioning" })
      expect(await runMachineAgent(run.ports, original.hand, original.cwd, "claude", "build me original X", original.operation, 1000)).toMatchObject({ ok: true })
      expect(start.mock.calls[0]).toEqual(start.mock.calls[1])
      expect(executions.size).toBe(2)
      expect(f.kick).toHaveBeenCalledOnce()
      expect(b.sql.exec<{ input: string }>(`SELECT input FROM cb_turn WHERE id = ?`, f.run).one().input).toBe('["build me the original hello page"]')
    })
  })

  it("keeps status read-only even when provider auth is ready", async () => {
    await recovery("get", async (b, f) => {
      f.auth = "ready"
      expect(await machineLogin(b, f.owner, f.run, "status")).toMatchObject({ waiting: true })
      expect(readMachineState(b.sql, f.run)?.phase).toBe("waiting_auth")
      expect(f.calls).toEqual([])
      expect(f.kick).not.toHaveBeenCalled()
    })
  })

  it("does not resume disabled, revoked, terminal or unapproved work", async () => {
    for (const mode of ["disabled", "revoked", "done", "unapproved", "revokeDuringAuth"] as const) await recovery(mode, async (b, f) => {
      f.auth = "ready"
      if (mode === "disabled") f.enabled = false
      if (mode === "revoked") f.revoked = true
      if (mode === "done") b.sql.exec(`UPDATE cb_turn SET status = 'done' WHERE id = ?`, f.run)
      if (mode === "unapproved") b.sql.exec(`UPDATE cb_turn SET effect_authorized = 0 WHERE id = ?`, f.run)
      if (mode === "revokeDuringAuth") f.revokeDuringAuth = true
      await expect(machineLogin(b, f.owner, f.run, "finish", { loginId: "consumed-guest-login" })).rejects.toThrow()
      expect(readMachineState(b.sql, f.run)?.phase).toBe("waiting_auth")
      expect(f.calls).not.toContain("_acpmux/agent_login/finish")
      expect(f.kick).not.toHaveBeenCalled()
    })
  })
})
