import { beforeAll, describe, expect, it } from "vitest"
import { AUTO_SESSIONS_PATH, handleAutoSessions } from "../src/auto-sessions/routes.ts"
import { advance, as, call, chatStub, fakeClock, fakeCloud, get, indexStub, lapse, LAPTOP, lease, M, M2, open, person, post, putChunk, runIn, setMachine, sha256, starts, takenOver, testEnv, VM, vmBearer } from "./auto-sessions-support.ts"
import { fireAlarm } from "./setup/alarm.ts"

/** Auto mode's store (src/auto-sessions): the lease and who holds a chat, the Auto machine's start, the owner's list. */
describe("auto sessions: the lease", { timeout: 60_000 }, () => {
  beforeAll(fakeClock)

  it("the first PUT makes the chat, held by its laptop at epoch 1; a renewal keeps it and moves no version unless a viewer can see a change", async () => {
    const a = await person("create")
    const made = await open(a.session, "acp:chat-1", { repo: { remote: "https://example.com/acme/web.git", branch: "main" } })
    expect(made.status).toBe(200)
    expect(made.body.session).toMatchObject({ id: "acp:chat-1", title: "Fix the flaky test", harness: "claude", owner: a.user, team: a.team, auto: true, keepInCloud: false, holder: LAPTOP, epoch: 1, state: "local", blocked: null, needsRun: false, standby: [], lastSeq: 0, snapshot: 0, inbox: 0, inboxAcked: 0, repo: { remote: "https://example.com/acme/web.git", branch: "main" }, version: 1 })
    // The same PUT again changes nothing; a new title is a change.
    expect((await open(a.session, "acp:chat-1", { repo: { remote: "https://example.com/acme/web.git", branch: "main" } })).body.session.version).toBe(1)
    expect((await open(a.session, "acp:chat-1", { title: "Renamed" })).body.session).toMatchObject({ title: "Renamed", version: 2, epoch: 1 })
    advance(10_000)
    const renewed = await lease(a.session, "acp:chat-1", LAPTOP, 1)
    expect(renewed.body).toMatchObject({ role: "holder", leaseMs: 45_000, session: { holder: LAPTOP, epoch: 1, version: 2 } })
    expect(renewed.body.session.leaseExpiresAt).toBeGreaterThan(made.body.session.leaseExpiresAt)
    // What the holder says it has to run is something a viewer sees.
    expect((await lease(a.session, "acp:chat-1", LAPTOP, 1, { needsRun: true })).body.session).toMatchObject({ needsRun: true, version: 3 })
    // The install's token is the owner too; a percent-encoded id is the same chat.
    expect((await get(a.installToken, "acp%3Achat-1")).body.session.id).toBe("acp:chat-1")
    expect((await open(a.session, "c", { harness: "Not A Harness" })).status).toBe(400)
    expect((await open(a.session, "c", { device: "" })).status).toBe(400)
    expect((await call("POST", "/v1/auto-sessions/acp:chat-1/lease", as(a.session), { holder: "mac1", epoch: 1, needsRun: false })).status).toBe(400)
    expect((await call("GET", "/v1/auto-sessions/acp:chat-1")).status).toBe(401)
    expect((await call("DELETE", "/v1/auto-sessions/acp:chat-1", as(a.session))).status).toBe(405)
    // An unknown chat is not found, and asking for it writes nothing.
    expect((await get(a.session, "nope")).status).toBe(404)
    expect((await call("PUT", "/v1/auto-sessions/nope", as(a.session), { auto: false })).status).toBe(404)
    const tables = await runIn(chatStub(a.user, "nope"), async (_i, state) => state.storage.sql.exec(`SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE '\\_cf\\_%' ESCAPE '\\'`).toArray())
    expect(tables).toEqual([])
  })

  it("a lease that runs out with a turn running gives the chat to the Auto machine: a takeover held until acked, the machine started once, a failed start backed off", async () => {
    const a = await person("takeover")
    const m = await fakeCloud(a.user)
    await setMachine(a)
    const vm = await vmBearer(a, M)
    await takenOver(a, "run")
    expect((await get(a.session, "run")).body.session).toMatchObject({ holder: VM, epoch: 2, state: "resuming", needsRun: true, team: a.team })
    // The first start is refused: the next try waits 1 s, then 2 s.
    m.failStart = true
    await fireAlarm(indexStub(a.user))
    const now = Date.now()
    const [first] = await starts(a.user)
    expect(first).toMatchObject({ machine: M, team: a.team, owner: a.user, tries: 1 })
    expect(Number(first!.next_at) - now).toBeGreaterThan(0)
    expect(Number(first!.next_at) - now).toBeLessThanOrEqual(1_000)
    const reads = m.reads
    await fireAlarm(indexStub(a.user))
    expect(m.reads).toBe(reads)
    advance(1_000)
    await fireAlarm(indexStub(a.user))
    const [second] = await starts(a.user)
    expect(second!.tries).toBe(2)
    expect(Number(second!.next_at) - Date.now()).toBeGreaterThan(1_000)
    expect(m.starts).toEqual([])
    // It goes through: one start, keyed by the machine's revision, and none more while the machine starts.
    m.failStart = false
    advance(2_000)
    await fireAlarm(indexStub(a.user))
    expect(m.starts).toEqual([`auto-session-start:${a.user}:${M}:rev1`])
    advance(5_000)
    await fireAlarm(indexStub(a.user))
    m.status = "running"
    advance(5_000)
    await fireAlarm(indexStub(a.user))
    expect(m.starts).toHaveLength(1)
    expect(await starts(a.user)).toHaveLength(1)
    // The assignment is still the machine's to pick up, and the chat still shows as resuming.
    const mine = await call("GET", "/v1/auto-sessions/assignments?timeoutMs=0", as(vm))
    expect(mine.body.assignments).toEqual([{ kind: "takeover", session: expect.objectContaining({ id: "run", holder: VM, epoch: 2, state: "resuming" }) }])
    const acked = await post(vm, "run", "assignment/ack", { holder: VM, epoch: 2 })
    expect(acked.body.session).toMatchObject({ holder: VM, epoch: 2, state: "cloud" })
    expect((await call("GET", "/v1/auto-sessions/assignments?timeoutMs=0", as(vm))).body.assignments).toEqual([])
    // Nothing left to pick up: the start ends.
    advance(5_000)
    await fireAlarm(indexStub(a.user))
    expect(await starts(a.user)).toEqual([])
    // The machine's lease never runs out to someone else.
    await lapse(a.user, "run")
    await lapse(a.user, "run")
    expect((await get(a.session, "run")).body.session).toMatchObject({ holder: VM, epoch: 2 })
  })

  it("a lease that runs out while idle parks the chat and starts nothing; its laptop takes it back as it is, another laptop only as a standby", async () => {
    const a = await person("idle")
    const m = await fakeCloud(a.user)
    await setMachine(a)
    await open(a.session, "idle")
    await lapse(a.user, "idle")
    expect((await get(a.session, "idle")).body.session).toMatchObject({ holder: "parked", epoch: 2, state: "parked", blocked: null })
    await fireAlarm(indexStub(a.user))
    expect([m.reads, m.starts, await starts(a.user)]).toEqual([0, [], []])
    // Nobody ran it since: the laptop that held it goes on at the new epoch.
    const back = await lease(a.session, "idle", LAPTOP, 1)
    expect(back.body).toMatchObject({ role: "holder", session: { holder: LAPTOP, epoch: 3, state: "local" } })
    // That renewal again (its answer was lost) is the same renewal; any other old epoch of the holder's is over.
    expect((await lease(a.session, "idle", LAPTOP, 1)).body).toMatchObject({ role: "holder", session: { holder: LAPTOP, epoch: 3 } })
    expect((await lease(a.session, "idle", LAPTOP, 2)).body).toMatchObject({ role: "lost", session: { holder: LAPTOP, epoch: 3 } })
    await lapse(a.user, "idle")
    // A laptop that was not its last holder is told it lost; as a standby it takes the parked chat (and imports the Cloud copy first).
    expect((await lease(a.session, "idle", "device:mac2", 3)).body).toMatchObject({ role: "lost", session: { holder: "parked", epoch: 4 } })
    expect((await lease(a.session, "idle", "device:mac2", 3, { standby: true })).body).toMatchObject({ role: "holder", session: { holder: "device:mac2", epoch: 5 } })
    // The first laptop is now the one that lost it, and stays a standby while another laptop holds it.
    expect((await lease(a.session, "idle", LAPTOP, 3)).body.role).toBe("lost")
    expect((await lease(a.session, "idle", LAPTOP, 3, { standby: true })).body).toMatchObject({ role: "standby", session: { holder: "device:mac2", epoch: 5, standby: [LAPTOP], state: "local" } })
  })

  it("no Auto machine: a chat with work waiting is parked and blocked; setting the machine sends it there", async () => {
    const a = await person("nomachine")
    expect((await call("GET", "/v1/auto-sessions/machine", as(a.session))).body.error.code).toBe("auto.no_machine")
    await open(a.session, "waits")
    await lease(a.session, "waits", LAPTOP, 1, { needsRun: true })
    await lapse(a.user, "waits")
    expect((await get(a.session, "waits")).body.session).toMatchObject({ holder: "parked", epoch: 2, state: "parked", blocked: "no_machine", needsRun: true })
    // A message for it waits too.
    expect((await post(a.session, "waits", "inbox", { id: "m1", text: "still there?" })).body).toMatchObject({ state: "queued", session: { holder: "parked", blocked: "no_machine", inbox: 1 } })
    // Only a team the person can use.
    expect((await call("PUT", "/v1/auto-sessions/machine", as(a.session), { team: `team_${"0".repeat(20)}`, machine: M })).status).toBe(403)
    expect((await call("PUT", "/v1/auto-sessions/machine", as(a.session), { team: a.team, machine: "not a machine" })).status).toBe(400)
    const m = await fakeCloud(a.user)
    expect((await setMachine(a)).body).toEqual({ team: a.team, machine: M })
    expect((await call("GET", "/v1/auto-sessions/machine", as(a.session))).body).toEqual({ team: a.team, machine: M })
    expect((await get(a.session, "waits")).body.session).toMatchObject({ holder: VM, epoch: 3, state: "resuming", blocked: null })
    await fireAlarm(indexStub(a.user))
    expect(m.starts).toHaveLength(1)
  })

  it("a laptop that comes back while the machine runs its chat waits as a standby; the chat goes home when the machine has nothing left to run, or releases", async () => {
    const a = await person("handback")
    await fakeCloud(a.user)
    await setMachine(a)
    const vm = await vmBearer(a, M)
    await takenOver(a, "home")
    // The laptop wakes: its old lease is gone, so it waits.
    expect((await lease(a.session, "home", LAPTOP, 1, { needsRun: true })).body).toMatchObject({ role: "lost", session: { holder: VM, epoch: 2 } })
    expect((await lease(a.session, "home", LAPTOP, 1, { standby: true })).body).toMatchObject({ role: "standby", session: { holder: VM, standby: [LAPTOP], state: "resuming" } })
    expect((await post(vm, "home", "assignment/ack", { holder: VM, epoch: 2 })).body.session.state).toBe("coming_back")
    expect((await lease(vm, "home", VM, 2, { needsRun: true })).body).toMatchObject({ role: "holder", session: { holder: VM, state: "coming_back" } })
    // The machine's turn ended, but its snapshot is older than its events: the laptop would import a stale copy, so not yet.
    expect((await post(vm, "home", "events", { holder: VM, epoch: 2, events: [{ seq: 1, record: { type: "turn_end" } }] })).body).toEqual({ lastSeq: 1 })
    expect((await lease(vm, "home", VM, 2)).body).toMatchObject({ role: "holder", session: { holder: VM } })
    expect((await post(vm, "home", "snapshot", { holder: VM, epoch: 2, manifest: { v: 1, at: 1, lastSeq: 1, harness: "claude", cwd: { kind: "folder", tar: [] }, queue: [] } })).body).toEqual({ snapshot: 1 })
    const home = await lease(vm, "home", VM, 2)
    expect(home.body).toMatchObject({ role: "lost", session: { holder: LAPTOP, epoch: 3, state: "local", standby: [] } })
    // The laptop learns it from its next standby renewal; the machine is fenced from then on, and no longer reads the chat.
    expect((await lease(a.session, "home", LAPTOP, 1, { standby: true })).body).toMatchObject({ role: "holder", session: { holder: LAPTOP, epoch: 3 } })
    const late = await post(vm, "home", "events", { holder: VM, epoch: 2, events: [{ seq: 2, record: {} }] })
    expect([late.status, late.body.error.code, late.body.session.epoch]).toEqual([409, "auto.stale_epoch", 3])
    expect((await lease(vm, "home", VM, 2)).body.role).toBe("lost")
    expect((await get(vm, "home")).status).toBe(404)

    // A release hands the chat back at once.
    await takenOver(a, "released")
    await lease(a.session, "released", LAPTOP, 1, { standby: true })
    expect((await post(vm, "released", "release", { holder: VM, epoch: 2 })).body.session).toMatchObject({ holder: LAPTOP, epoch: 3, state: "local" })

    // A standby that stops renewing no longer counts: the machine keeps the chat, and a release parks it.
    await takenOver(a, "gone")
    await lease(a.session, "gone", LAPTOP, 1, { standby: true })
    await post(vm, "gone", "assignment/ack", { holder: VM, epoch: 2 })
    await lapse(a.user, "gone")
    expect((await get(a.session, "gone")).body.session).toMatchObject({ holder: VM, standby: [], state: "cloud" })
    expect((await post(vm, "gone", "release", { holder: VM, epoch: 2 })).body.session).toMatchObject({ holder: "parked", epoch: 3, state: "parked" })
  })

  it("a chat kept in the Cloud is not handed back, at a release or to a standby, until the owner lets it go", async () => {
    const a = await person("keep")
    await fakeCloud(a.user)
    await setMachine(a)
    const vm = await vmBearer(a, M)
    await takenOver(a, "kept")
    await post(vm, "kept", "assignment/ack", { holder: VM, epoch: 2 })
    expect((await post(a.session, "kept", "keep", { keepInCloud: true })).body.session.keepInCloud).toBe(true)
    expect((await lease(a.session, "kept", LAPTOP, 1, { standby: true })).body).toMatchObject({ role: "standby", session: { state: "cloud", standby: [LAPTOP] } })
    expect((await lease(vm, "kept", VM, 2)).body).toMatchObject({ role: "holder", session: { holder: VM, epoch: 2 } })
    expect((await post(vm, "kept", "release", { holder: VM, epoch: 2 })).body.session).toMatchObject({ holder: "parked", epoch: 3 })
    expect((await lease(a.session, "kept", LAPTOP, 1, { standby: true })).body).toMatchObject({ role: "standby", session: { holder: "parked", epoch: 3 } })
    expect((await post(a.session, "kept", "keep", { keepInCloud: false })).body.session.keepInCloud).toBe(false)
    expect((await lease(a.session, "kept", LAPTOP, 1, { standby: true })).body).toMatchObject({ role: "holder", session: { holder: LAPTOP, epoch: 4 } })
    expect((await post(a.session, "kept", "keep", {})).status).toBe(400)
  })

  it("Auto off closes the chat and drops its Cloud copy, but not while a machine holds it; Auto on again opens it empty at the next epoch", async () => {
    const a = await person("close")
    await fakeCloud(a.user)
    await setMachine(a)
    await open(a.session, "off")
    await post(a.session, "off", "events", { holder: LAPTOP, epoch: 1, events: [{ seq: 1, record: { text: "hi" } }] })
    const closed = await call("PUT", "/v1/auto-sessions/off", as(a.session), { auto: false })
    expect(closed.body.session).toMatchObject({ auto: false, holder: "parked", epoch: 2, state: "parked", lastSeq: 0 })
    expect((await call("PUT", "/v1/auto-sessions/off", as(a.session), { auto: false })).body.session.version).toBe(closed.body.session.version)
    expect((await call("GET", "/v1/auto-sessions/off/events", as(a.session))).body).toEqual({ events: [], lastSeq: 0 })
    for (const refused of [await lease(a.session, "off", LAPTOP, 2), await post(a.session, "off", "events", { holder: LAPTOP, epoch: 2, events: [] }), await post(a.session, "off", "inbox", { id: "m", text: "hello" }), await post(a.session, "off", "keep", { keepInCloud: true })]) {
      expect([refused.status, refused.body.error.code]).toEqual([409, "auto.closed"])
    }
    // A wait on a closed chat answers at once.
    const started = Date.now()
    expect((await call("GET", `/v1/auto-sessions/off/wait?after=${closed.body.session.version}&timeoutMs=20000`, as(a.session))).body.session.auto).toBe(false)
    expect(Date.now() - started).toBeLessThan(5_000)
    expect((await call("GET", "/v1/auto-sessions", as(a.session))).body.sessions).toEqual([])
    expect((await open(a.session, "off", { device: "mac2" })).body.session).toMatchObject({ auto: true, holder: "device:mac2", epoch: 3, state: "local", lastSeq: 0 })
    expect((await post(a.session, "off", "events", { holder: "device:mac2", epoch: 3, events: [{ seq: 1, record: {} }] })).body).toEqual({ lastSeq: 1 })

    await takenOver(a, "busy")
    const held = await call("PUT", "/v1/auto-sessions/busy", as(a.session), { auto: false })
    expect([held.status, held.body.error.code, held.body.session.holder]).toEqual([409, "auto.held_in_cloud", VM])
  })

  it("a wait answers past its version and wakes on the next change a viewer can see, not on a plain renewal", async () => {
    const a = await person("wait")
    await open(a.session, "w")
    expect((await call("GET", "/v1/auto-sessions/w/wait?after=0&timeoutMs=10000", as(a.session))).body.session.version).toBe(1)
    const started = Date.now()
    const waiting = call("GET", "/v1/auto-sessions/w/wait?after=1&timeoutMs=20000", as(a.session))
    await new Promise((r) => setTimeout(r, 100))
    await lease(a.session, "w", LAPTOP, 1)
    await lease(a.session, "w", LAPTOP, 1, { needsRun: true })
    expect((await waiting).body.session).toMatchObject({ needsRun: true, version: 2 })
    expect(Date.now() - started).toBeLessThan(10_000)
    const held = Date.now()
    const quiet = call("GET", "/v1/auto-sessions/w/wait?after=2&timeoutMs=400", as(a.session))
    await lease(a.session, "w", LAPTOP, 1, { needsRun: true })
    expect((await quiet).body.session.version).toBe(2)
    expect(Date.now() - held).toBeGreaterThanOrEqual(350)
  })
})

describe("auto sessions: who may reach a chat, and the owner's list", { timeout: 60_000 }, () => {
  beforeAll(fakeClock)

  it("a stale holder is fenced on every write route; the current epoch under another holder's name is refused too", async () => {
    const a = await person("fence")
    await fakeCloud(a.user)
    await setMachine(a)
    const vm = await vmBearer(a, M)
    await takenOver(a, "f")
    const manifest = { v: 1, at: 1, lastSeq: 0, cwd: { kind: "folder", tar: [] } }
    const bytes = new TextEncoder().encode("work")
    const sha = await sha256(bytes)
    const chunk = (t: string, holder: string, epoch: number) => putChunk(t, "f", sha, bytes, holder, epoch)
    // The laptop slept through the takeover and still writes at epoch 1; then it names the current epoch as itself.
    for (const [epoch, code] of [[1, "auto.stale_epoch"], [2, "auto.not_holder"]] as const) {
      const writes = [
        await post(a.session, "f", "events", { holder: LAPTOP, epoch, events: [{ seq: 1, record: {} }] }),
        await post(a.session, "f", "snapshot", { holder: LAPTOP, epoch, manifest }),
        await post(a.session, "f", "inbox/ack", { holder: LAPTOP, epoch, through: 0 }),
        await post(a.session, "f", "release", { holder: LAPTOP, epoch }),
        await chunk(a.session, LAPTOP, epoch)
      ]
      for (const w of writes) expect([w.status, w.body.error.code, w.body.session.holder, w.body.session.epoch]).toEqual([409, code, VM, 2])
      expect((await lease(a.session, "f", LAPTOP, epoch, { needsRun: true })).body).toMatchObject({ role: "lost", session: { holder: VM, epoch: 2 } })
    }
    // An owner's credential never writes as a machine, nor a machine as a laptop or as another machine.
    expect((await post(a.session, "f", "events", { holder: VM, epoch: 2, events: [] })).body.error.code).toBe("auto.not_holder")
    expect((await post(vm, "f", "events", { holder: LAPTOP, epoch: 2, events: [] })).body.error.code).toBe("auto.not_holder")
    expect((await post(vm, "f", "release", { holder: `vm:${M2}`, epoch: 2 })).body.error.code).toBe("auto.not_holder")
    expect((await post(vm, "f", "assignment/ack", { holder: VM, epoch: 1 })).body.error.code).toBe("auto.stale_epoch")
    // Nothing above landed; the machine at the current epoch writes.
    expect((await get(a.session, "f")).body.session).toMatchObject({ holder: VM, epoch: 2, lastSeq: 0, snapshot: 0, inboxAcked: 0 })
    expect((await post(vm, "f", "events", { holder: VM, epoch: 2, events: [{ seq: 1, record: {} }] })).body).toEqual({ lastSeq: 1 })
    expect((await chunk(vm, VM, 2)).status).toBe(204)
    expect((await post(vm, "f", "snapshot", { holder: VM, epoch: 2, manifest })).body).toEqual({ snapshot: 1 })
  })

  it("an owner reaches only their own chats, a machine only the chats it holds; each route takes only its caller", async () => {
    const a = await person("mine")
    const b = await person("theirs")
    await fakeCloud(a.user)
    await setMachine(a)
    await open(a.session, "private")
    await post(a.session, "private", "events", { holder: LAPTOP, epoch: 1, events: [{ seq: 1, record: { secret: "plan" } }] })
    // Another person, with the same chat id, finds nothing of it.
    for (const path of ["", "/events", "/snapshot", "/inbox", "/wait?timeoutMs=0"]) expect((await call("GET", `/v1/auto-sessions/private${path}`, as(b.session))).status).toBe(404)
    expect((await post(b.session, "private", "inbox", { id: "m", text: "hi" })).status).toBe(404)
    expect((await lease(b.session, "private", LAPTOP, 1)).status).toBe(404)
    expect((await post(b.session, "private", "keep", { keepInCloud: true })).status).toBe(404)
    expect((await call("GET", "/v1/auto-sessions", as(b.session))).body.sessions).toEqual([])
    // The owner's machines: none holds it while the laptop does, and another person's machine with the same id is not this owner's.
    const vm = await vmBearer(a, M)
    const other = await vmBearer(a, M2)
    const foreign = await vmBearer(b, M)
    for (const t of [vm, other, foreign]) {
      expect((await get(t, "private")).status).toBe(404)
      expect((await call("GET", "/v1/auto-sessions/private/events", as(t))).status).toBe(404)
      expect((await lease(t, "private", t === other ? `vm:${M2}` : VM, 1)).status).toBe(404)
    }
    await lease(a.session, "private", LAPTOP, 1, { needsRun: true })
    await lapse(a.user, "private")
    // Now the Auto machine holds it: it reads it, the owner's other machine still does not.
    expect((await get(vm, "private")).body.session).toMatchObject({ holder: VM, epoch: 2 })
    expect((await call("GET", "/v1/auto-sessions/private/events", as(vm))).body).toEqual({ events: [{ seq: 1, record: { secret: "plan" } }], lastSeq: 1 })
    expect((await get(other, "private")).status).toBe(404)
    expect((await get(foreign, "private")).status).toBe(404)
    expect((await call("GET", "/v1/auto-sessions/assignments?timeoutMs=0", as(other))).body.assignments).toEqual([])
    expect((await call("GET", "/v1/auto-sessions/assignments?timeoutMs=0", as(foreign))).body.assignments).toEqual([])
    // A machine's credential is no owner, and an owner's is no machine.
    expect((await open(vm, "private")).status).toBe(403)
    expect((await post(vm, "private", "inbox", { id: "m", text: "hi" })).status).toBe(403)
    expect((await post(vm, "private", "keep", { keepInCloud: true })).status).toBe(403)
    expect((await call("GET", "/v1/auto-sessions", as(vm))).status).toBe(403)
    expect((await call("PUT", "/v1/auto-sessions/machine", as(vm), { team: a.team, machine: M })).status).toBe(403)
    expect((await call("GET", "/v1/auto-sessions/assignments?timeoutMs=0", as(a.session))).status).toBe(401)
    expect((await post(a.session, "private", "assignment/ack", { holder: VM, epoch: 2 })).status).toBe(401)
    expect((await call("GET", "/v1/auto-sessions/assignments?timeoutMs=0")).status).toBe(401)
  })

  it("the owner's list pages newest first and follows each chat's changes; a lost index write is tried again from the chat's alarm", async () => {
    const a = await person("list")
    const ids: Array<string> = []
    for (let i = 0; i < 3; i++) {
      ids.unshift(`chat-${i}`)
      await open(a.session, `chat-${i}`, { title: `Chat ${i}` })
      advance(5)
    }
    const one = await call("GET", "/v1/auto-sessions?limit=2", as(a.session))
    expect(one.body.sessions.map((s: any) => s.id)).toEqual(ids.slice(0, 2))
    const two = await call("GET", `/v1/auto-sessions?limit=2&cursor=${one.body.nextCursor}`, as(a.session))
    expect(two.body.sessions.map((s: any) => [s.id, s.title, s.holder, s.state])).toEqual([["chat-0", "Chat 0", LAPTOP, "local"]])
    expect(two.body.nextCursor).toBeNull()
    expect((await call("GET", "/v1/auto-sessions?cursor=nonsense", as(a.session))).status).toBe(400)
    // A change whose index write fails is still in the chat, and reaches the list at the retry.
    const stub = chatStub(a.user, "chat-0")
    await runIn(stub, async (instance, state) => {
      const real = instance.env
      instance.env = { ...real, AUTO_SESSION_INDEX_DO: { idFromName: () => "x", get: () => ({ put: async () => Promise.reject(new Error("reset")) }) } }
      await instance.keep(a.user, true)
      instance.env = real
      expect(await state.storage.getAlarm()).not.toBeNull()
    })
    expect((await get(a.session, "chat-0")).body.session.keepInCloud).toBe(true)
    const listed = async () => (await call("GET", "/v1/auto-sessions", as(a.session))).body.sessions.find((s: any) => s.id === "chat-0")
    expect((await listed()).keepInCloud).toBe(false)
    advance(30_000)
    await fireAlarm(stub)
    expect(await listed()).toMatchObject({ keepInCloud: true, version: 2 })
  })

  it("a dev build has its own chats and its own Auto machine: it sees none of another build's", async () => {
    const a = await person("spaces")
    await setMachine(a)
    await open(a.session, "shared-id", { title: "Nightly's" })
    const dev = { ...as(a.session), "x-cmux-build-space": "dev:auto-mode-test" }
    expect((await call("POST", "/v1/ops", dev, { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "user" })).status).toBe(200)
    expect((await call("GET", "/v1/auto-sessions/shared-id", dev)).status).toBe(404)
    expect((await call("GET", "/v1/auto-sessions", dev)).body.sessions).toEqual([])
    expect((await call("GET", "/v1/auto-sessions/machine", dev)).status).toBe(404)
    // The same id there is another chat.
    const theirs = await call("PUT", "/v1/auto-sessions/shared-id", dev, { auto: true, title: "The dev build's", harness: "codex", device: "mac1" })
    expect(theirs.body.session).toMatchObject({ title: "The dev build's", epoch: 1, version: 1 })
    expect((await get(a.session, "shared-id")).body.session).toMatchObject({ title: "Nightly's", harness: "claude" })
    expect((await call("GET", "/v1/auto-sessions", as(a.session))).body.sessions.map((s: any) => s.title)).toEqual(["Nightly's"])
  })

  it("the routes answer 404 where the store is not bound", async () => {
    const unbound = { ...testEnv, AUTO_SESSION_DO: undefined, AUTO_SESSION_INDEX_DO: undefined } as any
    for (const path of ["/v1/auto-sessions", "/v1/auto-sessions/machine", "/v1/auto-sessions/chat/lease"]) {
      const r = await handleAutoSessions(new Request(`https://api.test${path}`), unbound, path.match(AUTO_SESSIONS_PATH)!)
      expect(r.status).toBe(404)
    }
    expect((await call("GET", "/v1/auto-sessions/chat/nothing-here", as((await person("paths")).session))).status).toBe(404)
  })
})
