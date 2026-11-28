import { env } from "cloudflare:workers"
import { beforeAll, describe, expect, it } from "vitest"
import { MOVE_MS } from "../src/auto-sessions/model.ts"
import { advance, as, call, chatStub, copied, fakeClock, fakeCloud, get, indexStub, lapse, LAPTOP, lease, M, M2, open, person, post, runIn, setMachine, starts, takenOver, VM, vmBearer, type Person } from "./auto-sessions-support.ts"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * Moving a chat by hand (src/auto-sessions/move.ts; DESIGN.md "Modes and moving a chat by hand"): the person's
 * wish (`POST move`), the holder's give (`POST give`), a chat made in Cloud mode, and the parked chat that is kept
 * in the Cloud.
 */
const MAC2 = "device:mac2"
const move = (t: string, id: string, body: Record<string, unknown>) => post(t, id, "move", body)
const give = (t: string, id: string, holder: string, epoch: number) => post(t, id, "give", { holder, epoch })
const off = (t: string, id: string) => call("PUT", `/v1/auto-sessions/${id}`, as(t), { auto: false })
const session = async (a: Person, id: string) => (await get(a.installToken, id)).body.session
const event = (t: string, id: string, holder: string, epoch: number, seq: number) => post(t, id, "events", { holder, epoch, events: [{ seq, record: { n: seq } }] })
/** A snapshot with no files that says it was taken after event `lastSeq`. */
const snap = (t: string, id: string, holder: string, epoch: number, lastSeq: number) => post(t, id, "snapshot", { holder, epoch, manifest: { v: 1, at: 1, lastSeq, harness: "claude", cwd: { kind: "folder", tar: [] }, queue: [] } })
const assigned = async (vm: string) => ((await call("GET", "/v1/auto-sessions/assignments?timeoutMs=0", as(vm))).body.assignments as Array<{ kind: string; session: { id: string } }>).map((x) => [x.kind, x.session.id])
const refused = (r: { status: number; body: { error?: { code?: string } } }) => [r.status, r.body.error?.code]

describe("auto sessions: moving a chat by hand", { timeout: 60_000 }, () => {
  beforeAll(fakeClock)

  it("a move is refused for a chat that is not Auto, with no machine to go to, and with no laptop standing by", async () => {
    const a = await person("move-refused")
    await fakeCloud(a.user)
    await open(a.installToken, "chat")
    // The owner has no Cloud machine: nothing is written, the chat is as it was.
    const none = await move(a.installToken, "chat", { to: "cloud" })
    expect(refused(none)).toEqual([409, "auto.no_machine"])
    expect(none.body.session).toMatchObject({ holder: LAPTOP, epoch: 1, keepInCloud: false, version: 1 })
    expect(none.body.session.move).toBeUndefined()
    // Another laptop is named and does not stand by.
    expect(refused(await move(a.installToken, "chat", { to: "local", device: MAC2 }))).toEqual([409, "auto.no_laptop"])
    // What the request has to say.
    expect((await move(a.installToken, "chat", { to: "moon" })).status).toBe(400)
    expect((await move(a.installToken, "chat", { to: "local", device: "mac2" })).status).toBe(400)
    expect((await move(a.installToken, "chat", { to: "cloud", device: MAC2 })).status).toBe(400)
    expect((await move(a.installToken, "nochat", { to: "cloud" })).status).toBe(404)
    expect((await call("GET", "/v1/auto-sessions/chat/move", as(a.installToken))).status).toBe(405)
    // Auto is off for the chat.
    expect((await off(a.installToken, "chat")).status).toBe(200)
    for (const to of ["cloud", "local"]) expect(refused(await move(a.installToken, "chat", { to }))).toEqual([409, "auto.off"])
    // A machine holds the chat and no laptop stands by.
    await setMachine(a)
    await takenOver(a, "away")
    expect(refused(await move(a.installToken, "away", { to: "local" }))).toEqual([409, "auto.no_laptop"])
    // The machine that holds the chat asks the same, and is refused the same; another machine is not let in.
    expect(refused(await move(await vmBearer(a, M), "away", { to: "local" }))).toEqual([409, "auto.no_laptop"])
    expect((await move(await vmBearer(a, M2), "away", { to: "local" })).status).toBe(404)
  })

  it("the machine that holds a chat moves it and says whether it is kept in the Cloud, for the agent in it; a machine that does not hold it cannot", async () => {
    const a = await person("machine-moves")
    await fakeCloud(a.user)
    await setMachine(a)
    const vm = await vmBearer(a, M)
    const other = await vmBearer(a, M2)
    // Held by the laptop: the machine is only assigned, and is not let in.
    await open(a.installToken, "near")
    expect((await move(vm, "near", { to: "cloud" })).status).toBe(404)
    expect((await post(vm, "near", "keep", { keepInCloud: true })).status).toBe(404)
    expect((await session(a, "near")).keepInCloud).toBe(false)
    // Held by the machine.
    await takenOver(a, "far")
    expect((await post(vm, "far", "assignment/ack", { holder: VM, epoch: 2 })).status).toBe(200)
    expect((await post(vm, "far", "keep", { keepInCloud: true })).body.session).toMatchObject({ holder: VM, keepInCloud: true })
    expect((await post(vm, "far", "keep", { keepInCloud: false })).body.session).toMatchObject({ holder: VM, keepInCloud: false })
    expect((await post(other, "far", "keep", { keepInCloud: true })).status).toBe(404)
    expect((await move(other, "far", { to: "local" })).status).toBe(404)
    expect((await session(a, "far")).keepInCloud).toBe(false)
    // To the laptop that stands by: the wish is written, the chat is not kept in the Cloud, and the machine gives at its renewal.
    expect((await lease(a.installToken, "far", LAPTOP, 1, { standby: true })).body.role).toBe("standby")
    const moved = await move(vm, "far", { to: "local" })
    expect(moved.status).toBe(200)
    expect(moved.body.session).toMatchObject({ holder: VM, epoch: 2, keepInCloud: false, move: { to: "local" } })
    expect((await lease(vm, "far", VM, 2, { needsRun: true })).body).toMatchObject({ role: "holder", move: "local" })
    // Back to the Cloud while it still holds it: kept there, the wish dropped.
    expect((await move(vm, "far", { to: "cloud" })).body.session).toMatchObject({ holder: VM, keepInCloud: true })
  })

  it("a give is refused with no wish, and until the store has a snapshot that covers the last event", async () => {
    const a = await person("give-refused")
    await fakeCloud(a.user)
    await setMachine(a)
    await open(a.installToken, "chat")
    expect(refused(await give(a.installToken, "chat", LAPTOP, 1))).toEqual([409, "auto.no_move"])
    expect((await move(a.installToken, "chat", { to: "cloud" })).status).toBe(200)
    // No snapshot yet.
    const early = await give(a.installToken, "chat", LAPTOP, 1)
    expect(refused(early)).toEqual([409, "auto.not_copied"])
    expect(early.body.session).toMatchObject({ holder: LAPTOP, epoch: 1, move: { to: "cloud" } })
    // A snapshot, then an event after it: the copy is behind again.
    expect((await snap(a.installToken, "chat", LAPTOP, 1, 0)).status).toBe(200)
    expect((await event(a.installToken, "chat", LAPTOP, 1, 1)).status).toBe(200)
    expect(refused(await give(a.installToken, "chat", LAPTOP, 1))).toEqual([409, "auto.not_copied"])
    // Fenced like every holder write.
    expect(refused(await give(a.installToken, "chat", LAPTOP, 0))).toEqual([409, "auto.stale_epoch"])
    expect(refused(await give(a.installToken, "chat", MAC2, 1))).toEqual([409, "auto.not_holder"])
    expect((await post(a.installToken, "chat", "give", { holder: "mac1", epoch: 1 })).status).toBe(400)
    expect((await snap(a.installToken, "chat", LAPTOP, 1, 1)).status).toBe(200)
    expect((await give(a.installToken, "chat", LAPTOP, 1)).body.session).toMatchObject({ holder: VM, epoch: 2 })
    // The wish went with the give.
    expect(refused(await give(await vmBearer(a, M), "chat", VM, 2))).toEqual([409, "auto.no_move"])
  })

  it("a move to the Cloud in the middle of the laptop's lease: the wish and keepInCloud in one write, the laptop told at its renewal, the machine started, then the give", async () => {
    const a = await person("to-cloud")
    await fakeCloud(a.user)
    await setMachine(a)
    const vm = await vmBearer(a, M)
    await open(a.installToken, "mid")
    await copied(a.installToken, "mid")
    const before = (await lease(a.installToken, "mid", LAPTOP, 1, { needsRun: true })).body
    expect(before.move).toBeUndefined()
    expect(await starts(a.user)).toEqual([])
    advance(10_000)
    const moved = await move(a.installToken, "mid", { to: "cloud" })
    expect(moved.status).toBe(200)
    // One write: one version, with both the wish and the mode.
    expect(moved.body.session).toMatchObject({ holder: LAPTOP, epoch: 1, state: "local", keepInCloud: true, needsRun: true, move: { to: "cloud" }, version: before.session.version + 1 })
    expect(moved.body.session.move.device).toBeUndefined()
    expect(moved.body.session.move.at).toBeGreaterThan(before.session.createdAt)
    // The machine is started while the laptop still holds the chat, and has nothing to pick up yet.
    expect(await starts(a.user)).toMatchObject([{ machine: M, team: a.team, owner: a.user }])
    expect(await assigned(vm)).toEqual([])
    // The laptop learns it from its renewal and from the chat's view.
    const told = (await lease(a.installToken, "mid", LAPTOP, 1, { needsRun: true })).body
    expect(told).toMatchObject({ role: "holder", move: "cloud", session: { holder: LAPTOP, epoch: 1 } })
    expect((await session(a, "mid")).move).toMatchObject({ to: "cloud" })
    // It stops its agent, sends its last events and a snapshot that covers them, and gives.
    expect((await event(a.installToken, "mid", LAPTOP, 1, 1)).status).toBe(200)
    expect(refused(await give(a.installToken, "mid", LAPTOP, 1))).toEqual([409, "auto.not_copied"])
    expect((await snap(a.installToken, "mid", LAPTOP, 1, 1)).status).toBe(200)
    const given = await give(a.installToken, "mid", LAPTOP, 1)
    expect(given.body.session).toMatchObject({ holder: VM, epoch: 2, state: "resuming", keepInCloud: true, needsRun: true })
    expect(given.body.session.move).toBeUndefined()
    expect(await assigned(vm)).toEqual([["takeover", "mid"]])
    // The laptop is a standby from here; the chat is kept in the Cloud, so it is not coming back.
    expect((await lease(a.installToken, "mid", LAPTOP, 1, { needsRun: true })).body.role).toBe("lost")
    expect(refused(await give(a.installToken, "mid", LAPTOP, 1))).toEqual([409, "auto.stale_epoch"])
    expect((await post(vm, "mid", "assignment/ack", { holder: VM, epoch: 2 })).status).toBe(200)
    const waits = (await lease(a.installToken, "mid", LAPTOP, 1, { standby: true })).body
    expect(waits).toMatchObject({ role: "standby", session: { holder: VM, epoch: 2, state: "cloud" } })
    expect(waits.move).toBeUndefined()
    // The machine's renewal carries no wish, and idle with a laptop waiting it keeps a chat that is kept in the Cloud.
    const held = (await lease(vm, "mid", VM, 2, { needsRun: false })).body
    expect(held).toMatchObject({ role: "holder", session: { holder: VM, epoch: 2 } })
    expect(held.move).toBeUndefined()
  })

  it("a move to a laptop while a machine holds the chat: the machine told at its renewal, the chat given to the laptop that stands by, which owes an import", async () => {
    const a = await person("to-laptop")
    await fakeCloud(a.user)
    await setMachine(a)
    const vm = await vmBearer(a, M)
    await takenOver(a, "home")
    expect((await post(vm, "home", "assignment/ack", { holder: VM, epoch: 2 })).status).toBe(200)
    expect((await post(a.installToken, "home", "keep", { keepInCloud: true })).status).toBe(200)
    expect((await lease(a.installToken, "home", LAPTOP, 1, { standby: true })).body.role).toBe("standby")
    // A laptop that is named has to be one that stands by.
    expect(refused(await move(a.installToken, "home", { to: "local", device: MAC2 }))).toEqual([409, "auto.no_laptop"])
    const kept = await session(a, "home")
    const moved = await move(a.installToken, "home", { to: "local" })
    expect(moved.body.session).toMatchObject({ holder: VM, epoch: 2, keepInCloud: false, state: "coming_back", move: { to: "local" }, version: kept.version + 1 })
    expect((await starts(a.user)).map((s) => s.machine)).toEqual([M])
    // The laptop's own renewal is a standby's: it is not told to give anything.
    expect((await lease(a.installToken, "home", LAPTOP, 1, { standby: true })).body.move).toBeUndefined()
    // The machine is at work: it is told, and gives once its copy is whole.
    expect((await lease(vm, "home", VM, 2, { needsRun: true })).body).toMatchObject({ role: "holder", move: "local", session: { holder: VM, epoch: 2 } })
    expect(refused(await give(vm, "home", VM, 2))).toEqual([409, "auto.not_copied"])
    expect((await snap(vm, "home", VM, 2, 0)).status).toBe(200)
    const given = await give(vm, "home", VM, 2)
    expect(given.body.session).toMatchObject({ holder: LAPTOP, epoch: 3, state: "local", keepInCloud: false, needsRun: true })
    expect(given.body.session.move).toBeUndefined()
    expect((await lease(vm, "home", VM, 2, { needsRun: true })).body.role).toBe("lost")
    // The laptop learns it at its next standby renewal, and owes an import: Auto off waits for its own snapshot.
    expect((await lease(a.installToken, "home", LAPTOP, 1, { standby: true })).body).toMatchObject({ role: "holder", session: { holder: LAPTOP, epoch: 3 } })
    expect(refused(await off(a.installToken, "home"))).toEqual([409, "auto.held_in_cloud"])
    expect((await snap(a.installToken, "home", LAPTOP, 3, 0)).status).toBe(200)
    expect((await off(a.installToken, "home")).body.session).toMatchObject({ auto: false })
  })

  it("the holder's lease answer says when the person asked, so a move asked again after a refused give is a new one", async () => {
    const a = await person("asked-again")
    await fakeCloud(a.user)
    await setMachine(a)
    const vm = await vmBearer(a, M)
    await takenOver(a, "home")
    expect((await post(vm, "home", "assignment/ack", { holder: VM, epoch: 2 })).status).toBe(200)
    const standBy = async () => (await lease(a.installToken, "home", LAPTOP, 1, { standby: true })).body
    const renewed = async () => (await lease(vm, "home", VM, 2, { needsRun: true })).body
    // With no wish the answer names no time.
    const quiet = await renewed()
    expect(quiet.move).toBeUndefined()
    expect(quiet.moveAt).toBeUndefined()
    expect((await standBy()).role).toBe("standby")
    const first = (await move(a.installToken, "home", { to: "local" })).body.session.move.at as number
    expect(await renewed()).toMatchObject({ role: "holder", move: "local", moveAt: first })
    // Only the holder is told: a standby's answer names neither the wish nor its time.
    const waits = await standBy()
    expect(waits.move).toBeUndefined()
    expect(waits.moveAt).toBeUndefined()
    // The laptop stops standing by, so the give is refused. The wish still waits, with the time it was asked.
    await lapse(a.user, "home")
    expect((await snap(vm, "home", VM, 2, 0)).status).toBe(200)
    expect(refused(await give(vm, "home", VM, 2))).toEqual([409, "auto.no_laptop"])
    expect(await renewed()).toMatchObject({ role: "holder", move: "local", moveAt: first })
    // The laptop is open again and the person asks again: the same wish, with a new time.
    expect((await standBy()).role).toBe("standby")
    const second = (await move(a.installToken, "home", { to: "local" })).body.session.move.at as number
    expect(second).toBeGreaterThan(first)
    expect(await renewed()).toMatchObject({ role: "holder", move: "local", moveAt: second })
    expect((await give(vm, "home", VM, 2)).body.session).toMatchObject({ holder: LAPTOP, epoch: 3 })
    // The chat is another holder's: neither answer names a wish.
    const lost = await renewed()
    expect(lost.role).toBe("lost")
    expect(lost.moveAt).toBeUndefined()
    expect((await standBy()).moveAt).toBeUndefined()
  })

  it("a parked chat has no holder to give it: to the Cloud it is a takeover at once, and needs a snapshot; to a laptop it goes to the one that stands by", async () => {
    const a = await person("parked")
    await fakeCloud(a.user)
    await setMachine(a)
    const vm = await vmBearer(a, M)
    // To the Cloud.
    await open(a.installToken, "up")
    await copied(a.installToken, "up")
    await lapse(a.user, "up")
    const parked = await session(a, "up")
    expect(parked).toMatchObject({ holder: "parked", epoch: 2, keepInCloud: false })
    const up = await move(a.installToken, "up", { to: "cloud" })
    expect(up.body.session).toMatchObject({ holder: VM, epoch: 3, state: "resuming", keepInCloud: true, version: parked.version + 1 })
    expect(up.body.session.move).toBeUndefined()
    expect(await assigned(vm)).toEqual([["takeover", "up"]])
    // With no snapshot the laptop has the only chat there is: nothing moves.
    await open(a.installToken, "bare")
    await lapse(a.user, "bare")
    const bare = await move(a.installToken, "bare", { to: "cloud" })
    expect(refused(bare)).toEqual([409, "auto.not_copied"])
    expect(bare.body.session).toMatchObject({ holder: "parked", epoch: 2, keepInCloud: false })
    expect(refused(await move(a.installToken, "bare", { to: "local" }))).toEqual([409, "auto.no_laptop"])
    // To a laptop: a chat kept in the Cloud stays parked while a laptop stands by, until the person moves it.
    await open(a.installToken, "down")
    await copied(a.installToken, "down")
    expect((await post(a.installToken, "down", "keep", { keepInCloud: true })).status).toBe(200)
    await lapse(a.user, "down")
    expect((await lease(a.installToken, "down", MAC2, 0, { standby: true })).body).toMatchObject({ role: "standby", session: { holder: "parked", epoch: 2 } })
    const down = await move(a.installToken, "down", { to: "local", device: MAC2 })
    expect(down.body.session).toMatchObject({ holder: MAC2, epoch: 3, state: "local", keepInCloud: false })
    expect(down.body.session.move).toBeUndefined()
    // That laptop did not hold the chat last: it owes an import.
    expect((await lease(a.installToken, "down", MAC2, 0, { standby: true })).body).toMatchObject({ role: "holder", session: { holder: MAC2, epoch: 3 } })
    expect(refused(await off(a.installToken, "down"))).toEqual([409, "auto.held_in_cloud"])
  })

  it("a chat kept in the Cloud that has a snapshot is not taken back by its laptop: it stays parked until work arrives, which starts the machine", async () => {
    const a = await person("kept-parked")
    await fakeCloud(a.user)
    await setMachine(a)
    await open(a.installToken, "kept", { keepInCloud: true })
    await copied(a.installToken, "kept")
    await lapse(a.user, "kept")
    expect(await session(a, "kept")).toMatchObject({ holder: "parked", epoch: 2, keepInCloud: true, snapshot: 1 })
    // Neither its renewal at the epoch it held nor its PUT takes it back.
    expect((await lease(a.installToken, "kept", LAPTOP, 1)).body).toMatchObject({ role: "lost", session: { holder: "parked", epoch: 2 } })
    expect((await open(a.installToken, "kept")).body.session).toMatchObject({ holder: "parked", epoch: 2, keepInCloud: true })
    expect((await lease(a.installToken, "kept", LAPTOP, 1, { standby: true })).body).toMatchObject({ role: "standby", session: { holder: "parked", epoch: 2 } })
    // A message is work: the machine gets the chat.
    expect((await post(a.installToken, "kept", "inbox", { id: "m1", text: "go on" })).body).toMatchObject({ state: "resuming", session: { holder: VM, epoch: 3, state: "resuming" } })
    expect((await starts(a.user)).map((s) => s.machine)).toEqual([M])
    // With no snapshot the laptop has the only chat there is, so it takes it back whatever the chat is kept as.
    await open(a.installToken, "early", { keepInCloud: true })
    await lapse(a.user, "early")
    expect((await lease(a.installToken, "early", LAPTOP, 1)).body).toMatchObject({ role: "holder", session: { holder: LAPTOP, epoch: 3 } })
    // A PUT that stops keeping the chat in the Cloud takes it back in the same write.
    await open(a.installToken, "freed", { keepInCloud: true })
    await copied(a.installToken, "freed")
    await lapse(a.user, "freed")
    expect((await open(a.installToken, "freed", { keepInCloud: false })).body.session).toMatchObject({ holder: LAPTOP, epoch: 3, keepInCloud: false })
  })

  it("a wish does not outlive its holder, is dropped once the chat is where it was asked to go, and ends after MOVE_MS", async () => {
    const a = await person("wish-ends")
    await fakeCloud(a.user)
    await setMachine(a)
    // Another change of holder: the laptop's lease runs out with nothing to run. The chat is parked, with no wish.
    await open(a.installToken, "gone")
    await copied(a.installToken, "gone")
    expect((await move(a.installToken, "gone", { to: "cloud" })).body.session).toMatchObject({ move: { to: "cloud" }, keepInCloud: true })
    await lapse(a.user, "gone")
    const gone = await session(a, "gone")
    expect(gone).toMatchObject({ holder: "parked", epoch: 2, keepInCloud: true })
    expect(gone.move).toBeUndefined()
    // Asked back to where it is: the wish goes, the mode follows, and the holder and epoch stay.
    await open(a.installToken, "back")
    expect((await move(a.installToken, "back", { to: "cloud" })).body.session.move).toMatchObject({ to: "cloud" })
    const back = (await move(a.installToken, "back", { to: "local" })).body.session
    expect(back).toMatchObject({ holder: LAPTOP, epoch: 1, keepInCloud: false })
    expect(back.move).toBeUndefined()
    expect((await move(a.installToken, "back", { to: "local", device: LAPTOP })).body.session.version).toBe(back.version)
    // A holder that does not act: the wish stays while it renews, and the alarm drops it after MOVE_MS.
    await open(a.installToken, "slow")
    expect((await move(a.installToken, "slow", { to: "cloud" })).status).toBe(200)
    for (let waited = 30_000; waited < MOVE_MS; waited += 30_000) {
      advance(30_000)
      await fireAlarm(chatStub(a.user, "slow"))
      expect((await lease(a.installToken, "slow", LAPTOP, 1)).body, `after ${waited} ms`).toMatchObject({ role: "holder", move: "cloud" })
    }
    advance(30_000)
    await fireAlarm(chatStub(a.user, "slow"))
    const slow = await session(a, "slow")
    expect(slow).toMatchObject({ holder: LAPTOP, epoch: 1, keepInCloud: true })
    expect(slow.move).toBeUndefined()
    expect((await lease(a.installToken, "slow", LAPTOP, 1)).body.move).toBeUndefined()
    expect(refused(await give(a.installToken, "slow", LAPTOP, 1))).toEqual([409, "auto.no_move"])
    // Nothing waits on the machine any more: its start ends at its next look.
    await fireAlarm(indexStub(a.user))
    expect(await starts(a.user)).toEqual([])
  })

  it("a chat started with no laptop can be made in Cloud mode", async () => {
    const a = await person("create-kept")
    await fakeCloud(a.user)
    await setMachine(a)
    const start = (more: Record<string, unknown>) => call("POST", "/v1/auto-sessions", as(a.installToken), { harness: "claude", repo: { remote: "https://example.com/acme/web.git", branch: "main" }, ...more })
    const kept = await start({ firstMessage: { id: "m-kept", text: "start here" }, keepInCloud: true })
    expect(kept.status).toBe(201)
    expect(kept.body.session).toMatchObject({ holder: VM, epoch: 1, keepInCloud: true, state: "resuming" })
    expect((await start({ firstMessage: { id: "m-plain", text: "start here" } })).body.session).toMatchObject({ holder: VM, keepInCloud: false })
    expect((await start({ firstMessage: { id: "m-bad", text: "start here" }, keepInCloud: "yes" })).status).toBe(400)
  })

  it("a store written before a chat could be moved opens as it is, and its chats can be moved", async () => {
    const a = await person("move-old-store")
    await fakeCloud(a.user)
    await setMachine(a)
    await open(a.installToken, "old")
    await copied(a.installToken, "old")
    await runIn(chatStub(a.user, "old"), async (chat, state) => {
      state.storage.sql.exec(`ALTER TABLE session DROP COLUMN move_wish`)
      void new chat.constructor(state, env)
    })
    await runIn(indexStub(a.user), async (index, state) => {
      state.storage.sql.exec(`DROP INDEX sessions_woken`)
      state.storage.sql.exec(`ALTER TABLE sessions DROP COLUMN wake_machine`)
      void new index.constructor(state, env)
    })
    const old = await session(a, "old")
    expect(old).toMatchObject({ holder: LAPTOP, epoch: 1, snapshot: 1 })
    expect(old.move).toBeUndefined()
    expect((await lease(a.installToken, "old", LAPTOP, 1)).body.role).toBe("holder")
    expect((await move(a.installToken, "old", { to: "cloud" })).body.session).toMatchObject({ move: { to: "cloud" }, keepInCloud: true })
    expect((await starts(a.user)).map((s) => s.machine)).toEqual([M])
    expect((await give(a.installToken, "old", LAPTOP, 1)).body.session).toMatchObject({ holder: VM, epoch: 2 })
  })
})
