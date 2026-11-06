import { describe, expect, it } from "vitest"
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

    // While the person holds it, the Chief may look but not act, nor set up a computer to get around it.
    expect((await send(token, chief.main_conversation, "k2", "keep going")).ok).toBe(true)
    await replies(token, chief.main_conversation, chief.id, 2)
    expect(seen.heldClick.status).toBe(409)
    expect(seen.heldClick.body).toMatchObject({ code: "computer.human_has_control", control: { holder: "human" } })
    expect(seen.heldSetup.body.code).toBe("computer.human_has_control")
    expect(seen.heldShot.status).toBe(200)
    expect(seen.heldShot.body.image).toMatch(/^\/9j\//)
    expect(seen.heldWindows.status).toBe(200)
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
