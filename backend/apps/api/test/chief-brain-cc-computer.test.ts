import { describe, expect, it, vi } from "vitest"
import { mintAccessToken } from "../src/auth.ts"
import { handleChiefBrain } from "../src/chief-brain/routes.ts"
import { personalTeamIdFor, userIdFor } from "../src/domains/user.ts"
import type { Env } from "../src/env.ts"
import { sandboxesOf } from "../src/chief-brain-cc/sandbox.ts"
import { COMPUTER_ACTIVE_KEY, COMPUTER_HUMAN_KEY, CONTROL_KEY, HANDED_BACK_NOTE, LEASE_IDLE_MS } from "../src/chief-brain-cc/sandbox-computer.ts"
import { fakeCloud, notes, type Started } from "./chief-brain-cc-fake.ts"
import { enabledChief, http, inDO, replies, send, sessionToken, testEnv, useCcSettings } from "./chief-brain-cc-harness.ts"

/**
 * The Chief's computer as a paid Cloud feature with a person who can take it over (DESIGN "Control lease" and
 * "Entitlement"): sandbox create and computer setup need the owner's Cloud plan; the owner's session takes over, drives
 * and hands back the computer over HTTP; the Chief's own input verbs are refused while the person holds it, and it can
 * ask for the person. Freestyle is faked at its HTTP boundary (chief-brain-cc-fake.ts); the turn machine posts notes.
 */
useCcSettings()

const call = async (s: Started, vm: unknown) => {
  const r = await notes(s, { run: s.run, vm })
  return { status: r.status, body: (await r.json().catch(() => null)) as any }
}

describe("the Chief's computer: plan, take over and hand back", { timeout: 120_000 }, () => {
  it("refuses a sandbox to an owner without a Cloud plan, and says so in the computer status", async () => {
    const seen: Record<string, any> = {}
    const cloud = fakeCloud(
      () => "no plan",
      async (s, n) => {
        if (n !== 1) return
        seen.create = await call(s, { action: "create" })
        seen.list = await call(s, { action: "list" })
      }
    )
    // Not on CLOUD_ALLOWED_TEAMS (test/setup/cloud-teams.ts) and no paid plan: the stub rule gives no plan.
    const { token, chief } = await enabledChief("chief-cc-computer-unpaid", "cc")
    expect((await send(token, chief.main_conversation, "k1", "use your computer")).ok).toBe(true)
    await replies(token, chief.main_conversation, chief.id, 1)
    expect(seen.create.status).toBe(403)
    expect(seen.create.body).toMatchObject({ code: "cloud.plan.required", details: { plan: expect.any(String) } })
    // Reading is not refused; nothing was made at Freestyle beyond the turn machine.
    expect(seen.list.status).toBe(200)
    expect(cloud.made.length).toBe(1)
    expect((await http("GET", `/v1/chiefs/${chief.id}/computer`, token)).json.value).toMatchObject({ used: false, entitled: false, computer: null, control: { holder: "chief" } })
  })

  it("lets the owner take over, drive and hand back the computer, and holds the Chief's input while they do", async () => {
    const seen: Record<string, any> = {}
    const cloud = fakeCloud(
      () => "computer",
      async (s, n) => {
        const id = seen.id as string
        if (n === 1) {
          seen.a = await call(s, { action: "create" })
          seen.id = seen.a.body?.vm?.id
          seen.setup = await call(s, { action: "computer", id: seen.id, op: "setup" })
          seen.click1 = await call(s, { action: "computer", id: seen.id, op: "click", x: 3, y: 4 })
        } else if (n === 2) {
          seen.heldClick = await call(s, { action: "computer", id, op: "click", x: 5, y: 6 })
          seen.heldSetup = await call(s, { action: "computer", id, op: "setup" })
          seen.heldShot = await call(s, { action: "computer", id, op: "screenshot" })
          seen.heldWindows = await call(s, { action: "computer", id, op: "windows" })
          // Nor change or end the VM under the person: exec, fs writes, stop, pause, delete, fork; reading is fine.
          for (const [k, req] of Object.entries({ exec: { action: "exec", command: "echo hi" }, write: { action: "fs", op: "write", path: "/tmp/x", data: btoa("x") }, mkdir: { action: "fs", op: "mkdir", path: "/tmp/d" }, stop: { action: "stop" }, pause: { action: "pause" }, delete: { action: "delete" }, fork: { action: "fork" }, snapshot: { action: "snapshot" }, update: { action: "update", ttl_seconds: 60 }, resize: { action: "resize", size: "md" } })) {
            seen[`held_${k}`] = await call(s, { ...req, id })
          }
          seen.heldLs = await call(s, { action: "fs", op: "ls", path: "/tmp", id })
          seen.heldGet = await call(s, { action: "get", id })
          // A person's take-over is theirs to end, not the Chief's.
          seen.heldHandBack = await call(s, { action: "computer", id, op: "hand_back" })
        } else if (n === 3) {
          seen.back1 = await call(s, { action: "computer", id, op: "key", keys: "ctrl+l Return" })
          seen.back2 = await call(s, { action: "computer", id, op: "move", x: 7, y: 8 })
          seen.askEmpty = await call(s, { action: "computer", id, op: "request_human" })
          seen.ask = await call(s, { action: "computer", id, op: "request_human", reason: "sign in to Gmail" })
          seen.afterAsk = await call(s, { action: "computer", id, op: "type", text: "x" })
          // Nor look while the person does what it asked (a sign-in): the screen is theirs until the hold ends.
          seen.afterAskShot = await call(s, { action: "computer", id, op: "screenshot" })
          seen.afterAskExec = await call(s, { action: "exec", id, command: "echo asked" })
          // A hold the Chief asked for, the Chief may end; then it asks again.
          seen.ownHandBack = await call(s, { action: "computer", id, op: "hand_back" })
          // Nobody handed anything back: the Chief's next verb carries no handed-back note.
          seen.afterOwnHandBack = await call(s, { action: "computer", id, op: "move", x: 3, y: 4 })
          seen.ask2 = await call(s, { action: "computer", id, op: "request_human", reason: "sign in to Gmail" })
        } else if (n === 4) {
          // After the lease ran out: a verb that fails keeps the note for the next one that succeeds.
          seen.expiredBad = await call(s, { action: "computer", id, op: "click", x: 5000, y: 1 })
          seen.expired1 = await call(s, { action: "computer", id, op: "click", x: 9, y: 9, shot: false })
          seen.expired2 = await call(s, { action: "computer", id, op: "click", x: 9, y: 9, shot: false })
        }
      }
    )
    const { token, chief } = await enabledChief("chief-cc-computer-lease", "cc")
    const stranger = await enabledChief("chief-cc-computer-lease-stranger", "cc")
    const status = async () => (await http("GET", `/v1/chiefs/${chief.id}/computer`, token)).json.value
    const control = (action: string, t = token) => http("POST", `/v1/chiefs/${chief.id}/computer/control`, t, { action })
    const input = (body: unknown, t = token) => http("POST", `/v1/chiefs/${chief.id}/computer/input`, t, body)

    // No computer yet: nothing to take over.
    expect((await control("take_over")).status).toBe(404)
    expect((await send(token, chief.main_conversation, "k1", "use your computer")).ok).toBe(true)
    await replies(token, chief.main_conversation, chief.id, 1)
    const id = seen.id as string
    expect(seen.setup, JSON.stringify(seen.setup)).toMatchObject({ status: 200, body: { computer: id, driver: "xdotool" } })
    // Input goes through cua-driver on the whole desktop, with xdotool only when cua-driver ran nothing (127).
    const click = cloud.execs.find((e) => e.vm === id && e.env?.CHIEF_CUA0?.includes('"x":3'))!
    expect(JSON.parse(click.env!.CHIEF_CUA0!)).toEqual({ scope: "desktop", x: 3, y: 4, button: "left" })
    expect(click.command).toContain('cua click "$CHIEF_CUA0"; c=$?; if [ $c -eq 127 ]; then xdotool mousemove --sync 3 4 click --repeat 1')
    expect(await status()).toMatchObject({ used: true, entitled: true, computer: { id, state: "running" }, control: { holder: "chief" } })

    // The person's input needs the computer first; a stranger gets the same 404 as for no Chief.
    expect((await input({ op: "click", x: 1, y: 1 })).json.error.code).toBe("computer.not_human")
    expect((await control("take_over", stranger.token)).status).toBe(404)
    expect((await input({ op: "click", x: 1, y: 1 }, stranger.token)).status).toBe(404)
    expect((await control("grab")).status).toBe(400)
    const took = await control("take_over")
    expect(took.status, took.text).toBe(200)
    expect(took.json.value.control).toMatchObject({ holder: "human", by: "human", since_ms: expect.any(Number) })
    expect(took.json.value.control.expires_ms).toBeGreaterThanOrEqual(took.json.value.control.since_ms + LEASE_IDLE_MS)
    const before = cloud.execs.length
    const typed = await input({ op: "type", text: "hi'; reboot" })
    expect(typed.status, typed.text).toBe(200)
    expect(typed.json.value).toMatchObject({ done: "type", control: { holder: "human" } })
    const ran = cloud.execs.slice(before)
    expect(ran.length).toBe(1)
    expect(ran[0]!.user).toBe("chief")
    expect(ran[0]!.env!.CHIEF_TEXT).toBe("hi'; reboot")
    expect(ran[0]!.command).not.toContain("reboot")
    expect((await input({ op: "open_url", url: "https://example.com/" })).status).toBe(200)
    expect((await input({ op: "key", keys: "ctrl+l; reboot" })).json.error.code).toBe("validation.invalid")
    expect((await input({ op: "screenshot" })).status).toBe(400)
    // A scroll amount out of range is clamped, not refused.
    const scrolled = await input({ op: "scroll", x: 10, y: 10, amount: 500 })
    expect(scrolled.status, scrolled.text).toBe(200)
    expect(JSON.parse(cloud.execs.at(-1)!.env!.CHIEF_CUA0!)).toMatchObject({ direction: "down", amount: 30 })
    expect(cloud.execs.at(-1)!.command).toContain("click --repeat 30 --delay 30 5")
    expect((await input({ op: "scroll", x: 10, y: 10, amount: 0 })).status).toBe(200)
    expect(JSON.parse(cloud.execs.at(-1)!.env!.CHIEF_CUA0!).amount).toBe(1)
    // The person's input is not the Chief acting: with the Chief quiet for a minute, `acting` stays off.
    const sandboxes = sandboxesOf(testEnv as unknown as Env, chief.id)
    const setConfig = (values: Record<string, string>) => inDO(sandboxes, async (instance) => { for (const [k, v] of Object.entries(values)) instance.sql.exec(`INSERT INTO cb_config (name, value) VALUES (?, ?) ON CONFLICT (name) DO UPDATE SET value = excluded.value`, k, v) })
    await setConfig({ [COMPUTER_ACTIVE_KEY]: String(Date.now() - 60_000) })
    expect((await input({ op: "move", x: 3, y: 3 })).status).toBe(200)
    expect((await status()).acting).toBe(false)

    // While the person holds it, the Chief may neither act nor look (what they type there is theirs), nor set up a
    // computer to get around it.
    const shotsBefore = cloud.execs.filter((e) => e.vm === id && e.command.includes("jpg:- | base64 -w0")).length
    expect((await send(token, chief.main_conversation, "k2", "keep going")).ok).toBe(true)
    await replies(token, chief.main_conversation, chief.id, 2)
    expect(seen.heldClick.status).toBe(409)
    expect(seen.heldClick.body).toMatchObject({ code: "computer.human_has_control", control: { holder: "human" } })
    expect(seen.heldSetup.body.code).toBe("computer.human_has_control")
    expect(seen.heldShot).toMatchObject({ status: 409, body: { code: "computer.human_has_control", control: { holder: "human", by: "human" } } })
    expect(seen.heldShot.body.image).toBeUndefined()
    expect(seen.heldWindows).toMatchObject({ status: 409, body: { code: "computer.human_has_control" } })
    expect(cloud.execs.filter((e) => e.vm === id && e.command.includes("jpg:- | base64 -w0")).length).toBe(shotsBefore)
    expect(cloud.execs.some((e) => e.env?.CHIEF_CUA0?.includes('"x":5'))).toBe(false)
    for (const k of ["exec", "write", "mkdir", "stop", "pause", "delete", "fork", "snapshot", "update", "resize"]) {
      expect(seen[`held_${k}`], k).toMatchObject({ status: 409, body: { code: "computer.human_has_control", control: { holder: "human", by: "human" } } })
    }
    expect(cloud.deleted).not.toContain(id)
    expect(cloud.lifecycle).not.toContain(`${id} pause`)
    expect(cloud.execs.some((e) => e.command === "echo hi")).toBe(false)
    expect(seen.heldLs.status).toBe(200)
    expect(seen.heldGet.status).toBe(200)
    expect(seen.heldHandBack).toMatchObject({ status: 409, body: { code: "computer.human_has_control" } })

    // Handed back: the Chief's next verb tells it to look again, once.
    expect((await control("hand_back")).json.value.control).toMatchObject({ holder: "chief" })
    expect((await input({ op: "click", x: 1, y: 1 })).json.error.code).toBe("computer.not_human")
    expect((await send(token, chief.main_conversation, "k3", "continue")).ok).toBe(true)
    await replies(token, chief.main_conversation, chief.id, 3)
    expect(seen.back1.status).toBe(200)
    expect(seen.back1.body.note).toBe(HANDED_BACK_NOTE)
    expect(seen.back2.status).toBe(200)
    expect(seen.back2.body.note).toBeUndefined()
    // The Chief asks for the person: it then holds no input until they hand it back.
    expect(seen.askEmpty.status).toBe(400)
    expect(seen.ask.body.control).toMatchObject({ holder: "human", reason: "sign in to Gmail" })
    expect(seen.ask.body.control).toMatchObject({ by: "chief", expires_ms: expect.any(Number) })
    expect(seen.afterAsk.body.code).toBe("computer.human_has_control")
    expect(seen.afterAskShot).toMatchObject({ status: 409, body: { code: "computer.human_has_control", control: { by: "chief" } } })
    expect(seen.afterAskExec).toMatchObject({ status: 409, body: { code: "computer.human_has_control" } })
    expect(cloud.execs.some((e) => e.command === "echo asked")).toBe(false)
    expect(seen.ownHandBack.body.control).toMatchObject({ holder: "chief" })
    expect(seen.afterOwnHandBack.status).toBe(200)
    expect(seen.afterOwnHandBack.body.note).toBeUndefined()
    expect((await status()).control).toMatchObject({ holder: "human", by: "chief", reason: "sign in to Gmail" })
    expect((await input({ op: "move", x: 2, y: 2 })).status).toBe(200)
    // The person takes over the Chief's request: it is theirs now, reason kept.
    expect((await control("take_over")).json.value.control).toMatchObject({ holder: "human", by: "human", reason: "sign in to Gmail" })

    // Idle past the lease (no take-over or input for LEASE_IDLE_MS): the computer is the Chief's again, read lazily.
    const stale = String(Date.now() - LEASE_IDLE_MS - 1000)
    await setConfig({ [COMPUTER_HUMAN_KEY]: stale, [CONTROL_KEY]: JSON.stringify({ holder: "human", since_ms: Number(stale), by: "human" }) })
    expect((await status()).control).toMatchObject({ holder: "chief" })
    expect((await status()).control.expires_ms).toBeUndefined()
    expect((await input({ op: "click", x: 1, y: 1 })).json.error.code).toBe("computer.not_human")
    expect((await send(token, chief.main_conversation, "k4", "go on")).ok).toBe(true)
    await replies(token, chief.main_conversation, chief.id, 4)
    expect(seen.expiredBad.status).toBe(400)
    expect(seen.expiredBad.body.note).toBeUndefined()
    expect(seen.expired1).toMatchObject({ status: 200, body: { done: "click", note: HANDED_BACK_NOTE } })
    expect(seen.expired2.body.note).toBeUndefined()
    // Asleep needs the person holding it again.
    expect((await control("take_over")).status).toBe(200)

    // Asleep: the person's input never wakes it.
    cloud.states.set(id, "suspended")
    const asleep = await input({ op: "click", x: 1, y: 1 })
    expect(asleep.status).toBe(409)
    expect(asleep.json.error.code).toBe("computer.asleep")
    expect(cloud.lifecycle).not.toContain(`${id} start`)
  })
})

describe("the owner gives a Chief its computer from the profile", { timeout: 120_000 }, () => {
  it("makes a 4 vCPU / 8 GiB sandbox with the desktop for a paid owner, answers the same one again, and refuses without a plan", async () => {
    const cloud = fakeCloud(() => "ok")
    const { token, chief } = await enabledChief("chief-cc-computer-provision", "cc")
    const provision = (t = token, id = chief.id) => http("POST", `/v1/chiefs/${id}/computer/control`, t, { action: "provision" })
    // Made in the background: the ask answers at once, the status says when it is there.
    const first = await provision()
    expect(first.status, JSON.stringify(first.json)).toBe(202)
    expect(first.json.value).toEqual({ provisioning: true })
    const status = async () => (await http("GET", `/v1/chiefs/${chief.id}/computer`, token)).json.value
    let now = await status()
    for (let i = 0; i < 200 && !now.computer; i++) now = (await new Promise((r) => setTimeout(r, 25)), await status())
    const id = now.computer.id as string
    expect((await provision()).json.value.computer).toEqual({ id, state: "running" })
    // Grown to COMPUTER_SIZE (the small Ubuntu starts at 2 vCPU / 4 GiB); set up as its computer (used, below).
    expect(cloud.sizes.get(id)).toMatchObject({ cpu: 4, memory: 8192 })
    expect(await status()).toMatchObject({ used: true, entitled: true, computer: { id, state: "running" } })
    expect((await status()).provisioning).toBeUndefined()
    // A second ask keeps the computer it has: nothing more is made.
    const made = cloud.made.length
    expect((await provision()).json.value.computer.id).toBe(id)
    expect(cloud.made.length).toBe(made)
    // Without a Cloud plan, and for someone else's Chief, nothing is made.
    const unpaid = await enabledChief("chief-cc-computer-unpaid", "cc")
    const refused = await provision(unpaid.token, unpaid.chief.id)
    expect(refused.status).toBe(403)
    expect(refused.json.error.code).toBe("cloud.plan.required")
    expect((await provision(unpaid.token)).status).toBe(404)
    expect(cloud.made.length).toBe(made)
  })
})

/** The desktop setup fails on the fake (the fetch fake of fakeCloud wrapped); the returned function undoes it. */
const failSetup = (): (() => void) => {
  const spy = vi.mocked(globalThis.fetch)
  const inner = spy.getMockImplementation()!
  spy.mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const req = new Request(input, init)
    if (req.method === "POST" && /\/exec-await$/.test(new URL(req.url).pathname)) {
      const body = (await req.clone().json().catch(() => null)) as { command?: string } | null
      if (body?.command?.includes("| base64 -d | bash")) return Response.json({ statusCode: 1, stdout: "", stderr: "apt failed" })
    }
    return inner(req)
  })
  return () => void spy.mockImplementation(inner)
}

/** While sandbox `vm`'s desktop setup runs on the fake, `during` runs first (the fetch fake of fakeCloud wrapped); the returned function undoes it. */
const duringSetup = (vm: () => string | undefined, during: () => Promise<unknown>): (() => void) => {
  const spy = vi.mocked(globalThis.fetch)
  const inner = spy.getMockImplementation()!
  spy.mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const req = new Request(input, init)
    const exec = /\/v5\/vms\/([^/]+)\/exec-await$/.exec(new URL(req.url).pathname)
    if (req.method === "POST" && exec && exec[1] === vm()) {
      const body = (await req.clone().json().catch(() => null)) as { command?: string } | null
      if (body?.command?.includes("| base64 -d | bash")) await during()
    }
    return inner(req)
  })
  return () => void spy.mockImplementation(inner)
}

describe("the person takes over while a desktop setup runs", { timeout: 120_000 }, () => {
  it("keeps the person's lease and the computer they hold, for another sandbox and for the same one", async () => {
    const seen: Record<string, any> = {}
    let setupOn: string | undefined
    let token = ""
    let agent = ""
    const cloud = fakeCloud(
      () => "computer",
      async (s, n) => {
        if (n !== 1) return
        seen.a = (await call(s, { action: "create" })).body?.vm?.id
        seen.setupA = await call(s, { action: "computer", id: seen.a, op: "setup" })
        seen.b = (await call(s, { action: "create" })).body?.vm?.id
        const undo = duringSetup(() => setupOn, async () => {
          seen.took = await http("POST", `/v1/chiefs/${agent}/computer/control`, token, { action: "take_over" })
        })
        setupOn = seen.b
        seen.switched = await call(s, { action: "computer", id: seen.b, op: "setup" })
        seen.afterSwitch = (await http("GET", `/v1/chiefs/${agent}/computer`, token)).json.value
        await http("POST", `/v1/chiefs/${agent}/computer/control`, token, { action: "hand_back" })
        setupOn = seen.a
        seen.again = await call(s, { action: "computer", id: seen.a, op: "setup" })
        seen.afterAgain = (await http("GET", `/v1/chiefs/${agent}/computer`, token)).json.value
        undo()
      }
    )
    const made = await enabledChief("chief-cc-computer-setup-race", "cc")
    token = made.token
    agent = made.chief.id
    expect((await send(token, made.chief.main_conversation, "k1", "use your computer")).ok).toBe(true)
    await replies(token, made.chief.main_conversation, agent, 1)
    expect(seen.setupA.status, JSON.stringify(seen.setupA)).toBe(200)
    expect(seen.took.status, seen.took.text).toBe(200)
    expect(seen.switched).toMatchObject({ status: 409, body: { code: "computer.human_has_control", control: { holder: "human", by: "human" } } })
    expect(seen.afterSwitch).toMatchObject({ computer: { id: seen.a }, control: { holder: "human", by: "human" } })
    expect(seen.again).toMatchObject({ status: 409, body: { code: "computer.human_has_control" } })
    expect(seen.afterAgain).toMatchObject({ computer: { id: seen.a }, control: { holder: "human", by: "human" } })
    expect(cloud.deleted).not.toContain(seen.a)
  })
})

describe("a computer whose setup fails, and two asks at once", { timeout: 120_000 }, () => {
  it("deletes the sandbox a failed setup made, so a retry does not stack VMs, and makes one computer for two concurrent asks", async () => {
    const cloud = fakeCloud(() => "ok")
    const { token, chief } = await enabledChief("chief-cc-computer-provision-fail", "cc")
    const provision = () => http("POST", `/v1/chiefs/${chief.id}/computer/control`, token, { action: "provision" })
    const status = async () => (await http("GET", `/v1/chiefs/${chief.id}/computer`, token)).json.value
    const settled = async (until: (v: any) => boolean) => {
      let now = await status()
      for (let i = 0; i < 200 && !until(now); i++) now = (await new Promise((r) => setTimeout(r, 25)), await status())
      return now
    }
    const undo = failSetup()
    for (const attempt of [1, 2]) {
      expect((await provision()).status).toBe(202)
      await settled(() => cloud.deleted.length >= attempt)
      const failed = await settled((v) => v.provision_error !== undefined)
      expect(failed).toMatchObject({ computer: null, provision_error: expect.stringContaining("desktop did not install") })
      // Each attempt made one VM and deleted it: none is left behind for the next.
      expect(cloud.made.length).toBe(attempt)
      expect(cloud.deleted).toEqual(cloud.made.map((m) => m.id))
    }
    undo()
    // Two asks at once: one computer (the second answers 202 while the first is made, or 200 with it once it is there).
    const both = await Promise.all([provision(), provision()])
    expect(both[0]!.status).toBe(202)
    expect([200, 202]).toContain(both[1]!.status)
    const done = await settled((v) => v.computer !== null)
    expect(done.computer).toMatchObject({ id: cloud.made.at(-1)!.id, state: "running" })
    expect(cloud.made.length).toBe(3)
    expect(cloud.deleted).not.toContain(done.computer.id)
  })

  it("refuses provision where the Claude Code route is not configured, and makes nothing", async () => {
    const cloud = fakeCloud(() => "ok")
    const { token, chief } = await enabledChief("chief-cc-computer-provision-off", "cc")
    const was = testEnv.CHIEF_CC_ENABLED
    testEnv.CHIEF_CC_ENABLED = "0"
    try {
      const r = await http("POST", `/v1/chiefs/${chief.id}/computer/control`, token, { action: "provision" })
      expect(r.status, r.text).toBe(409)
      expect(r.json.error.code).toBe("computer.unavailable")
    } finally {
      testEnv.CHIEF_CC_ENABLED = was
    }
    expect(cloud.made.length).toBe(0)
  })
})

describe("the computer's control routes take only the owner's signed-in session", () => {
  const AGENT = "agent_01ARZ3NDEKTSV4RRFFQ69G5FAV"
  it("refuses an install grant and a Chief's own grant with mutate-own as computer.user_origin_required", async () => {
    const base = testEnv as unknown as Env
    const owner = userIdFor(base.STACK_PROJECT_ID, "computer-origin")
    const reached: Array<string> = []
    const fake = {
      ...base,
      CHIEF_BRAIN_ENABLED: "1",
      USER_DO: { idFromName: (name: string) => name, get: () => ({ installGrant: async () => ({ ok: true, op_classes: ["read", "mutate-own"], kind: "daemon", email: null, email_verified: false }) }) },
      MUX_DO: { idFromName: (name: string) => name, get: () => ({ readOp: async (entity: string) => (reached.push(`owner ${entity}`), { ok: true, value: { agent: entity, owner_user: owner } }) }) },
      CHIEF_BRAIN_DO: { idFromName: (name: string) => (reached.push(`brain ${name}`), name), get: () => ({}) }
    } as unknown as Env
    const post = async (path: "computer/control" | "computer/input", bearer: string, body: unknown) => {
      const res = await handleChiefBrain(new Request(`https://api.test/v1/chiefs/${AGENT}/${path}`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${bearer}` }, body: JSON.stringify(body) }), fake, AGENT, path, undefined)
      return { status: res.status, json: (await res.json()) as any }
    }
    for (const claims of [{}, { agent: AGENT }]) {
      const signed = await mintAccessToken(base, { user: owner, team: personalTeamIdFor(owner), install: "inst_computer_test", grant: "grant_computer_test", ...claims })
      for (const [path, body] of [["computer/control", { action: "take_over" }], ["computer/input", { op: "click", x: 1, y: 1 }]] as const) {
        const r = await post(path, signed.token, body)
        expect(r.status, `${path} ${JSON.stringify(claims)}`).toBe(403)
        expect(r.json.error.code).toBe("computer.user_origin_required")
      }
    }
    // Refused before the owner is asked (handleChiefBrain names the brain stub up front; nothing calls it).
    expect(reached.filter((r) => r.startsWith("owner"))).toEqual([])
    // The owner's own session passes to the owner check and the body (an unknown action is a 400).
    expect((await post("computer/control", await sessionToken("computer-origin"), { action: "grab" })).status).toBe(400)
  })
})

/** While sandbox `vm` runs a command `match` accepts on the fake, `then` runs first; the returned function undoes it. */
const whileRunning = (vm: () => string | undefined, match: (command: string) => boolean, then: () => Promise<unknown>): (() => void) => {
  const spy = vi.mocked(globalThis.fetch)
  const inner = spy.getMockImplementation()!
  spy.mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const req = new Request(input, init)
    const exec = /\/v5\/vms\/([^/]+)\/exec-await$/.exec(new URL(req.url).pathname)
    if (req.method === "POST" && exec && exec[1] === vm()) {
      const body = (await req.clone().json().catch(() => null)) as { command?: string } | null
      if (body?.command && match(body.command)) await then()
    }
    return inner(req)
  })
  return () => void spy.mockImplementation(inner)
}

describe("the person takes over while the Chief looks", { timeout: 120_000 }, () => {
  it("never hands the Chief a frame or a window list captured across the take-over", async () => {
    const seen: Record<string, any> = {}
    let token = ""
    let agent = ""
    fakeCloud(
      () => "computer",
      async (s, n) => {
        if (n !== 1) return
        const id = (await call(s, { action: "create" })).body?.vm?.id
        seen.setup = await call(s, { action: "computer", id, op: "setup" })
        const once = async (match: (c: string) => boolean, vm: unknown) => {
          let took = false
          const undo = whileRunning(() => id, match, async () => {
            if (!took) await http("POST", `/v1/chiefs/${agent}/computer/control`, token, { action: "take_over" })
            took = true
          })
          const out = await call(s, vm)
          undo()
          await http("POST", `/v1/chiefs/${agent}/computer/control`, token, { action: "hand_back" })
          return out
        }
        const isShot = (c: string) => c.includes("import -silent -window root")
        seen.look = await once(isShot, { action: "computer", id, op: "screenshot" })
        seen.windows = await once((c) => c.includes("list_windows"), { action: "computer", id, op: "windows" })
        seen.click = await once(isShot, { action: "computer", id, op: "click", x: 1, y: 1 })
      }
    )
    const made = await enabledChief("chief-cc-computer-look-race", "cc")
    token = made.token
    agent = made.chief.id
    expect((await send(token, made.chief.main_conversation, "k1", "use your computer")).ok).toBe(true)
    await replies(token, made.chief.main_conversation, agent, 1)
    expect(seen.setup.status, JSON.stringify(seen.setup)).toBe(200)
    expect(seen.look).toMatchObject({ status: 409, body: { code: "computer.human_has_control" } })
    expect(seen.windows).toMatchObject({ status: 409, body: { code: "computer.human_has_control" } })
    // The click ran before the take-over: it says so, with no frame of the person's screen.
    expect(seen.click.status, JSON.stringify(seen.click)).toBe(200)
    expect(seen.click.body.done).toBe("click")
    expect(seen.click.body.image).toBeUndefined()
  })
})
