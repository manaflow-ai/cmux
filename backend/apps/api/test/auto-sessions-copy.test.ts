import { beforeAll, describe, expect, it } from "vitest"
import { planAppend } from "../src/auto-sessions/events.ts"
import { MAX_CHAT_BYTES, MAX_CHUNK_BYTES } from "../src/auto-sessions/model.ts"
import { chunkNames } from "../src/auto-sessions/snapshots.ts"
import { advance, as, call, chatStub, copied, fakeClock, fakeCloud, get, getChunk, indexStub, lapse, LAPTOP, open, person, post, putChunk, runIn, setMachine, sha256, VM, vmBearer } from "./auto-sessions-support.ts"
import { fireAlarm } from "./setup/alarm.ts"

/** Auto mode's Cloud copy of a chat (src/auto-sessions): its events, chunks and snapshot, its inbox, and a chat started with no laptop. */
const text = (s: string) => new TextEncoder().encode(s)

describe("auto sessions: the chat's Cloud copy", { timeout: 60_000 }, () => {
  beforeAll(fakeClock)

  it("events go on from the last one stored: a repeat is accepted and changes nothing, a hole is refused with the last seq", async () => {
    const a = await person("events")
    await open(a.installToken, "log")
    const send = (events: Array<unknown>) => post(a.installToken, "log", "events", { holder: LAPTOP, epoch: 1, events })
    expect((await send([{ seq: 1, record: { type: "user", text: "hi" } }, { seq: 2, record: "plain" }])).body).toEqual({ lastSeq: 2 })
    const before = (await get(a.installToken, "log")).body.session.version
    // A retry of the same request, and one that overlaps what is stored.
    expect((await send([{ seq: 1, record: { type: "user", text: "changed" } }, { seq: 2, record: "plain" }])).body).toEqual({ lastSeq: 2 })
    expect((await get(a.installToken, "log")).body.session.version).toBe(before)
    expect((await send([{ seq: 2, record: "plain" }, { seq: 3, record: null }])).body).toEqual({ lastSeq: 3 })
    const gap = await send([{ seq: 5, record: {} }])
    expect([gap.status, gap.body.error.code, gap.body.lastSeq, gap.body.session.lastSeq]).toEqual([409, "auto.seq_gap", 3, 3])
    // A hole inside one request stores none of it.
    expect((await send([{ seq: 4, record: {} }, { seq: 6, record: {} }])).body.error.code).toBe("auto.seq_gap")
    const all = await call("GET", "/v1/auto-sessions/log/events", as(a.installToken))
    expect(all.body).toEqual({ events: [{ seq: 1, record: { type: "user", text: "hi" } }, { seq: 2, record: "plain" }, { seq: 3, record: null }], lastSeq: 3 })
    expect((await call("GET", "/v1/auto-sessions/log/events?after=1&limit=1", as(a.installToken))).body).toEqual({ events: [{ seq: 2, record: "plain" }], lastSeq: 3 })
    expect((await send(Array.from({ length: 257 }, (_, i) => ({ seq: i + 4, record: {} })))).status).toBe(400)
    expect((await send([{ seq: 0, record: {} }])).status).toBe(400)
    expect((await send([{ seq: 4 }])).status).toBe(400)
    expect(planAppend(3, [{ seq: 2 }, { seq: 3 }])).toEqual({ fresh: [] })
    expect(planAppend(3, [{ seq: 3 }, { seq: 4 }, { seq: 5 }])).toEqual({ fresh: [{ seq: 4 }, { seq: 5 }] })
    expect(planAppend(3, [{ seq: 4 }, { seq: 6 }])).toEqual({ gap: 6 })
  })

  it("a chunk is kept only under the SHA-256 of its bytes and within the chat's limit; a snapshot only when every chunk it names is stored, and the newest replaces the one before", async () => {
    const a = await person("chunks")
    await open(a.installToken, "copy")
    const [one, two] = [text("first chunk"), text("second chunk")]
    const [shaOne, shaTwo] = [await sha256(one), await sha256(two)]
    const wrong = await putChunk(a.installToken, "copy", "0".repeat(64), one, LAPTOP, 1)
    expect([wrong.status, wrong.body.error.code]).toEqual([400, "auto.chunk_mismatch"])
    expect((await putChunk(a.installToken, "copy", shaOne, one, LAPTOP, 1)).status).toBe(204)
    expect((await putChunk(a.installToken, "copy", shaOne, one, LAPTOP, 1)).status).toBe(204)
    const read = await getChunk(a.installToken, "copy", shaOne)
    expect([read.status, new TextDecoder().decode(read.bytes)]).toEqual([200, "first chunk"])
    expect((await getChunk(a.installToken, "copy", shaTwo)).status).toBe(404)
    // One chunk is at most 1 MiB; the chunks waiting for one snapshot are at most 512 MiB.
    const big = await putChunk(a.installToken, "copy", "1".repeat(64), new Uint8Array(new ArrayBuffer(MAX_CHUNK_BYTES + 1)), LAPTOP, 1)
    expect([big.status, big.body.error.code]).toEqual([413, "auto.too_large"])
    const stub = chatStub(a.user, "copy")
    const filler = "f".repeat(64)
    const fill = (size: number, at: number) => runIn(stub, async (_i, state) => void state.storage.sql.exec(`INSERT OR REPLACE INTO chunks (sha, size, at, bytes) VALUES (?, ?, ?, x'')`, filler, size, at))
    await fill(MAX_CHAT_BYTES - one.byteLength - 5, Date.now())
    const full = await putChunk(a.installToken, "copy", shaTwo, two, LAPTOP, 1)
    expect([full.status, full.body.error.code]).toEqual([413, "auto.too_large"])
    // A snapshot that names more than the limit is refused whole.
    await fill(MAX_CHAT_BYTES, Date.now())
    const heavy = await post(a.installToken, "copy", "snapshot", { holder: LAPTOP, epoch: 1, manifest: { v: 1, lastSeq: 0, cwd: { kind: "folder", tar: [shaOne, filler] } } })
    expect([heavy.status, heavy.body.error.code, (await get(a.installToken, "copy")).body.session.snapshot]).toEqual([413, "auto.too_large", 0])
    // An upload given up a day ago makes room once the chat is at its limit.
    await fill(MAX_CHAT_BYTES, Date.now() - 25 * 3600_000)
    expect((await putChunk(a.installToken, "copy", shaTwo, two, LAPTOP, 1)).status).toBe(204)
    expect((await getChunk(a.installToken, "copy", filler)).status).toBe(404)
    await runIn(stub, async (_i, state) => void state.storage.sql.exec(`DELETE FROM chunks WHERE sha = ?`, shaTwo))
    // A manifest naming a chunk that is not stored is no snapshot.
    const manifest = (bundle: Array<string>, patch: Array<string>) => ({ v: 1, at: 1, lastSeq: 0, harness: "claude", harnessSessionId: "h1", cwd: { kind: "git", remote: "https://example.com/acme/web.git", branch: "main", base: "a".repeat(40), bundle, patch }, queue: [{ id: "q1", text: "next" }], draft: "" })
    const partial = await post(a.installToken, "copy", "snapshot", { holder: LAPTOP, epoch: 1, manifest: manifest([shaOne], [shaTwo]) })
    expect([partial.status, partial.body.error.code, partial.body.missing]).toEqual([409, "auto.snapshot_incomplete", [shaTwo]])
    expect((await call("GET", "/v1/auto-sessions/copy/snapshot", as(a.installToken))).body.error.code).toBe("auto.no_snapshot")
    expect((await get(a.installToken, "copy")).body.session.snapshot).toBe(0)
    expect((await putChunk(a.installToken, "copy", shaTwo, two, LAPTOP, 1)).status).toBe(204)
    expect((await post(a.installToken, "copy", "snapshot", { holder: LAPTOP, epoch: 1, manifest: manifest([shaOne], [shaTwo]) })).body).toEqual({ snapshot: 1 })
    expect((await call("GET", "/v1/auto-sessions/copy/snapshot", as(a.installToken))).body).toEqual({ snapshot: 1, manifest: manifest([shaOne], [shaTwo]) })
    expect((await get(a.installToken, "copy")).body.session.snapshot).toBe(1)
    // The next snapshot names only the second chunk: the first is dropped with the older manifest.
    expect((await post(a.installToken, "copy", "snapshot", { holder: LAPTOP, epoch: 1, manifest: manifest([], [shaTwo]) })).body).toEqual({ snapshot: 2 })
    expect((await call("GET", "/v1/auto-sessions/copy/snapshot", as(a.installToken))).body.snapshot).toBe(2)
    expect([(await getChunk(a.installToken, "copy", shaOne)).status, (await getChunk(a.installToken, "copy", shaTwo)).status]).toEqual([404, 200])
    // A kept snapshot does not count against the next one: a chat at the limit can still replace its snapshot.
    await runIn(stub, async (_i, state) => void state.storage.sql.exec(`UPDATE chunks SET size = ? WHERE sha = ?`, MAX_CHAT_BYTES, shaTwo))
    expect((await putChunk(a.installToken, "copy", shaOne, one, LAPTOP, 1)).status).toBe(204)
    expect((await post(a.installToken, "copy", "snapshot", { holder: LAPTOP, epoch: 1, manifest: { v: 1 } })).status).toBe(400)
    // Which chunks a manifest names: every list of SHA-256 names in it.
    expect(chunkNames(manifest([shaOne], [shaTwo]))).toEqual([shaOne, shaTwo])
    expect(chunkNames({ cwd: { kind: "folder", tar: [shaOne, shaOne] }, queue: [{ id: shaTwo, text: shaTwo }], base: shaTwo })).toEqual([shaOne])
  })

  it("a message is taken once and the holder reads it until it acks; for a parked chat it starts the Auto machine, for a machine it is a deliver assignment", async () => {
    const a = await person("inbox")
    const m = await fakeCloud(a.user)
    await setMachine(a)
    const vm = await vmBearer(a, M_HOLDER)
    await open(a.installToken, "talk")
    // The laptop's first copy is stored: from here a message alone can start a machine for the chat.
    expect((await copied(a.installToken, "talk")).body).toEqual({ snapshot: 1 })
    // A laptop holds it: the message waits for its next renewal.
    const sent = await post(a.installToken, "talk", "inbox", { id: "m1", text: "first" })
    expect(sent.body).toMatchObject({ state: "delivered", session: { holder: LAPTOP, inbox: 1, inboxAcked: 0 } })
    expect((await post(a.installToken, "talk", "inbox", { id: "m1", text: "first" })).body).toMatchObject({ state: "delivered", session: { inbox: 1 } })
    expect((await call("GET", "/v1/auto-sessions/talk/inbox?after=0", as(a.installToken))).body.messages).toEqual([{ n: 1, id: "m1", text: "first", at: expect.any(Number) }])
    expect((await post(a.installToken, "talk", "inbox/ack", { holder: LAPTOP, epoch: 1, through: 99 })).body.session).toMatchObject({ inbox: 1, inboxAcked: 1 })
    expect((await call("GET", "/v1/auto-sessions/talk/inbox", as(a.installToken))).body.messages).toEqual([])
    // A late retry of an acked message is still the same message.
    expect((await post(a.installToken, "talk", "inbox", { id: "m1", text: "first" })).body).toMatchObject({ state: "delivered", session: { inbox: 1 } })
    expect((await post(a.installToken, "talk", "inbox", { id: "bad id!", text: "x" })).status).toBe(400)
    expect((await post(a.installToken, "talk", "inbox", { id: "m0", text: "" })).status).toBe(400)

    // The laptop goes away idle: the chat is parked. The machine's wait is held until a message gives the chat to it.
    await lapse(a.user, "talk")
    const started = Date.now()
    const waiting = call("GET", "/v1/auto-sessions/assignments?timeoutMs=20000", as(vm))
    await new Promise((r) => setTimeout(r, 100))
    const woke = await post(a.installToken, "talk", "inbox", { id: "m2", text: "are you there?" })
    expect(woke.body).toMatchObject({ state: "resuming", session: { holder: VM, epoch: 3, state: "resuming", inbox: 2, inboxAcked: 1 } })
    expect((await waiting).body.assignments).toEqual([{ kind: "takeover", session: expect.objectContaining({ id: "talk", holder: VM, epoch: 3 }) }])
    expect(Date.now() - started).toBeLessThan(10_000)
    await fireAlarm(indexStub(a.user))
    expect(m.starts).toHaveLength(1)
    expect((await post(a.installToken, "talk", "inbox", { id: "m2", text: "are you there?" })).body).toMatchObject({ state: "resuming", session: { inbox: 2 } })
    // The machine picks the chat up and takes the message.
    m.status = "running"
    expect((await call("GET", "/v1/auto-sessions/talk/inbox?after=0", as(vm))).body.messages).toEqual([{ n: 2, id: "m2", text: "are you there?", at: expect.any(Number) }])
    // It picked the chat up, but a message is still unread: it keeps a deliver until it has taken the message too.
    expect((await post(vm, "talk", "assignment/ack", { holder: VM, epoch: 3 })).body.session.state).toBe("resuming")
    expect((await call("GET", "/v1/auto-sessions/assignments?timeoutMs=0", as(vm))).body.assignments.map((x: any) => x.kind)).toEqual(["deliver"])
    expect((await post(vm, "talk", "inbox/ack", { holder: VM, epoch: 3, through: 2 })).body.session).toMatchObject({ state: "resuming", inboxAcked: 2 })
    expect((await post(vm, "talk", "assignment/ack", { holder: VM, epoch: 3 })).body.session.state).toBe("cloud")
    // A message for a machine that is running: it is told through a deliver assignment, and is not started again.
    const live = await post(a.installToken, "talk", "inbox", { id: "m3", text: "one more" })
    expect(live.body).toMatchObject({ state: "delivered", session: { holder: VM, epoch: 3, state: "resuming", inbox: 3 } })
    expect((await call("GET", "/v1/auto-sessions/assignments?timeoutMs=0", as(vm))).body.assignments).toEqual([{ kind: "deliver", session: expect.objectContaining({ id: "talk" }) }])
    await fireAlarm(indexStub(a.user))
    expect(m.starts).toHaveLength(1)
    await post(vm, "talk", "inbox/ack", { holder: VM, epoch: 3, through: 3 })
    expect((await post(vm, "talk", "assignment/ack", { holder: VM, epoch: 3 })).body.session.state).toBe("cloud")
    advance(5_000)
    await fireAlarm(indexStub(a.user))
    // The machine went quiet (paused): the next message starts it again.
    advance(46_000)
    m.status = "paused"
    m.revision = "rev2"
    expect((await post(a.installToken, "talk", "inbox", { id: "m4", text: "wake up" })).body).toMatchObject({ state: "resuming", session: { holder: VM, epoch: 3, state: "resuming" } })
    await fireAlarm(indexStub(a.user))
    expect(m.starts.map((k) => k.split(":").at(-1))).toEqual(["rev1", "rev2"])
    // The machine lets the chat go while that message is unread: it keeps the chat, at the same epoch, with the message to pick up.
    expect((await post(vm, "talk", "release", { holder: VM, epoch: 3 })).body.session).toMatchObject({ holder: VM, epoch: 3, state: "resuming", inbox: 4, inboxAcked: 3 })
    await post(vm, "talk", "inbox/ack", { holder: VM, epoch: 3, through: 4 })
    expect((await post(vm, "talk", "release", { holder: VM, epoch: 3 })).body.session).toMatchObject({ holder: "parked", epoch: 4, state: "parked" })
  })

  it("POST /v1/auto-sessions starts a chat with no laptop: the Auto machine holds it from epoch 1, has a create to pick up and its first message to read", async () => {
    const a = await person("phone")
    const body = { harness: "codex", repo: { remote: "https://example.com/acme/web.git", branch: "main" }, firstMessage: { id: "first-1", text: "Fix the build" } }
    const none = await call("POST", "/v1/auto-sessions", as(a.installToken), body)
    expect([none.status, none.body.error.code]).toEqual([409, "auto.no_machine"])
    expect((await call("GET", "/v1/auto-sessions", as(a.installToken))).body.sessions).toEqual([])
    const m = await fakeCloud(a.user)
    await setMachine(a)
    const vm = await vmBearer(a, M_HOLDER)
    const made = await call("POST", "/v1/auto-sessions", as(a.installToken), body)
    expect(made.status).toBe(201)
    expect(made.body.session).toMatchObject({ title: "", harness: "codex", owner: a.user, team: a.team, holder: VM, epoch: 1, state: "resuming", needsRun: true, inbox: 1, inboxAcked: 0, repo: body.repo, version: 1 })
    const id = made.body.session.id as string
    expect(id).toMatch(/^as_[0-9a-f]{20}$/)
    await fireAlarm(indexStub(a.user))
    expect(m.starts).toHaveLength(1)
    // A retry after a lost answer reaches the same chat; another first message is another chat.
    const again = await call("POST", "/v1/auto-sessions", as(a.installToken), body)
    expect([again.status, again.body.session.id, again.body.session.version]).toEqual([201, id, 1])
    const other = await call("POST", "/v1/auto-sessions", as(a.installToken), { ...body, title: "Second", firstMessage: { id: "first-2", text: "And the docs" } })
    expect([other.status, other.body.session.id === id, other.body.session.title]).toEqual([201, false, "Second"])
    await fireAlarm(indexStub(a.user))
    expect(m.starts).toHaveLength(1)
    // The machine finds both, reads the first message, and acks.
    const mine = (await call("GET", "/v1/auto-sessions/assignments?timeoutMs=0", as(vm))).body.assignments
    expect(mine.map((x: any) => [x.kind, x.session.id])).toEqual([["create", id], ["create", other.body.session.id]])
    expect((await get(vm, id)).body.session).toMatchObject({ id, harness: "codex", repo: body.repo })
    expect((await call("GET", `/v1/auto-sessions/${id}/inbox`, as(vm))).body.messages).toEqual([{ n: 1, id: "first-1", text: "Fix the build", at: expect.any(Number) }])
    expect((await post(vm, id, "inbox/ack", { holder: VM, epoch: 1, through: 1 })).body.session.inboxAcked).toBe(1)
    expect((await post(vm, id, "assignment/ack", { holder: VM, epoch: 1 })).body.session.state).toBe("cloud")
    expect((await call("GET", "/v1/auto-sessions", as(a.installToken))).body.sessions.map((s: any) => [s.id, s.state])).toEqual([[other.body.session.id, "resuming"], [id, "cloud"]])
    expect((await call("POST", "/v1/auto-sessions", as(a.installToken), { ...body, repo: undefined })).status).toBe(400)
    expect((await call("POST", "/v1/auto-sessions", as(a.installToken), { ...body, firstMessage: { id: "x" } })).status).toBe(400)
  })
})

const M_HOLDER = VM.slice("vm:".length)
