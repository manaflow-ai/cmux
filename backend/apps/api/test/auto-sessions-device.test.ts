import { beforeAll, describe, expect, it } from "vitest"
import { mintAccessToken } from "../src/auth.ts"
import { as, call, fakeClock, get, lease, open, person, post, putChunk, runIn, sha256, testEnv, type Person } from "./auto-sessions-support.ts"

/**
 * A `device:` holder belongs to the install that first named it in a chat (security review of cmux#52931, item 1).
 * The request is the one today's laptop client sends (the body still names the holder); the store checks it against
 * the install that calls. An install that never holds a chat (a phone, a browser session) reads, waits, sends
 * messages and keeps a chat in the Cloud, and writes as no laptop.
 */

/** Another install of the person's, of `kind`, with the grant of their own install: a second laptop, or their phone. */
const installBearer = async (a: Person, kind: string): Promise<string> => {
  const id = `inst_${kind}${crypto.randomUUID().replace(/-/g, "").slice(0, 16)}`
  const grant = `grant_${crypto.randomUUID().replace(/-/g, "").slice(0, 20)}`
  await runIn(testEnv.USER_DO.get(testEnv.USER_DO.idFromName(a.user)), async (i) => {
    const s = i.boundEngine.currentState
    const own = s.installs[a.install]
    s.installs[id] = { ...own, id, kind, grant, revoked_at: null }
    s.grants[grant] = { ...s.grants[own.grant], id: grant, grantee: id, revoked_at: null }
  })
  return (await mintAccessToken(testEnv as any, { user: a.user, team: a.team, install: id, grant })).token
}

const MANIFEST = { v: 1, at: 1, lastSeq: 1, harness: "claude", cwd: { kind: "folder", tar: [] }, queue: [] }

describe("auto sessions: a laptop's holder is its install's", { timeout: 60_000 }, () => {
  beforeAll(fakeClock)

  it("today's laptop client, unchanged, does every holder write as its own device", async () => {
    const a = await person("device-current")
    const t = a.installToken
    expect((await open(t, "c1")).body.session).toMatchObject({ holder: "device:mac1", epoch: 1 })
    expect((await lease(t, "c1", "device:mac1", 1, { needsRun: true })).body).toMatchObject({ role: "holder" })
    expect((await post(t, "c1", "events", { holder: "device:mac1", epoch: 1, events: [{ seq: 1, record: { kind: "x" } }] })).body).toEqual({ lastSeq: 1 })
    const bytes = new TextEncoder().encode("chunk")
    expect((await putChunk(t, "c1", await sha256(bytes), bytes, "device:mac1", 1)).status).toBe(204)
    expect((await post(t, "c1", "snapshot", { holder: "device:mac1", epoch: 1, manifest: MANIFEST })).status).toBe(200)
    expect((await post(t, "c1", "inbox/ack", { holder: "device:mac1", epoch: 1, through: 0 })).status).toBe(200)
    expect((await post(t, "c1", "release", { holder: "device:mac1", epoch: 1 })).body.session).toMatchObject({ holder: "parked" })
  })

  it("another install of the same person cannot write as a laptop it is not; as its own device it may stand by", async () => {
    const a = await person("device-other")
    await open(a.installToken, "c2")
    const other = await installBearer(a, "mac")
    const wrong = { status: 403, body: { error: { code: "auto.wrong_device" } } }
    expect(await lease(other, "c2", "device:mac1", 1, { needsRun: false })).toMatchObject(wrong)
    expect(await post(other, "c2", "events", { holder: "device:mac1", epoch: 1, events: [{ seq: 1, record: {} }] })).toMatchObject(wrong)
    expect(await post(other, "c2", "release", { holder: "device:mac1", epoch: 1 })).toMatchObject(wrong)
    expect(await post(other, "c2", "inbox/ack", { holder: "device:mac1", epoch: 1, through: 0 })).toMatchObject(wrong)
    expect(await post(other, "c2", "snapshot", { holder: "device:mac1", epoch: 1, manifest: MANIFEST })).toMatchObject(wrong)
    const bytes = new TextEncoder().encode("x")
    expect(await putChunk(other, "c2", await sha256(bytes), bytes, "device:mac1", 1)).toMatchObject(wrong)
    // A PUT that names the other laptop's device is refused too: it would take back a chat parked from it.
    expect(await open(other, "c2")).toMatchObject(wrong)
    // Nothing moved; the chat is still the first laptop's.
    expect((await get(a.installToken, "c2")).body.session).toMatchObject({ holder: "device:mac1", epoch: 1, lastSeq: 0 })
    // As its own device the second laptop waits as a standby.
    expect((await lease(other, "c2", "device:mac2", 1, { needsRun: false, standby: true })).body).toMatchObject({ role: "standby" })
    // The first laptop goes on.
    expect((await lease(a.installToken, "c2", "device:mac1", 1)).body).toMatchObject({ role: "holder" })
  })

  it("a phone or a browser session holds no chat: its holder writes are refused, its reads and messages are not", async () => {
    const a = await person("device-phone")
    await open(a.installToken, "c3")
    const phone = await installBearer(a, "ios")
    for (const t of [phone, a.session]) {
      const refused = { status: 403, body: { error: { code: "auto.not_a_laptop" } } }
      expect(await open(t, "c3")).toMatchObject(refused)
      expect(await open(t, "c-new")).toMatchObject(refused)
      expect(await lease(t, "c3", "device:mac1", 1)).toMatchObject(refused)
      expect(await lease(t, "c3", "device:phone", 1, { needsRun: false, standby: true })).toMatchObject(refused)
      expect(await post(t, "c3", "release", { holder: "device:mac1", epoch: 1 })).toMatchObject(refused)
      expect(await post(t, "c3", "events", { holder: "device:mac1", epoch: 1, events: [{ seq: 1, record: {} }] })).toMatchObject(refused)
      expect(await post(t, "c3", "snapshot", { holder: "device:mac1", epoch: 1, manifest: MANIFEST })).toMatchObject(refused)
      expect(await post(t, "c3", "inbox/ack", { holder: "device:mac1", epoch: 1, through: 0 })).toMatchObject(refused)
      const bytes = new TextEncoder().encode("p")
      expect(await putChunk(t, "c3", await sha256(bytes), bytes, "device:mac1", 1)).toMatchObject(refused)
      // What the phone does with no laptop: list, read, wait, send a message, keep the chat in the Cloud.
      expect((await call("GET", "/v1/auto-sessions", as(t))).status).toBe(200)
      expect((await get(t, "c3")).body.session).toMatchObject({ holder: "device:mac1", epoch: 1 })
      expect((await call("GET", "/v1/auto-sessions/c3/wait?after=0&timeoutMs=0", as(t))).status).toBe(200)
      expect((await post(t, "c3", "inbox", { id: `m-${t === phone ? "p" : "s"}`, text: "hello" })).status).toBe(200)
      expect((await post(t, "c3", "keep", { keepInCloud: false })).status).toBe(200)
    }
    // Turning Auto off is not a holder write: the person may do it from anywhere.
    expect((await call("PUT", "/v1/auto-sessions/c3", as(phone), { auto: false })).status).not.toBe(403)
  })
})
