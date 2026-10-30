import { describe, expect, it } from "vitest"
import { createdAndBound, ensureUser, frame, installOf, person, reply, SIZE } from "./cloud-bind-support.ts"
import { inDO } from "./team-ssh-support.ts"
import { teamStub } from "./team-stack-support.ts"
import { SHARED_TEAM } from "./setup/cloud-teams.ts"

// Exercise CloudDO's persisted reads, admission, reducer and provider boundary, not policy helpers.
describe("explicit team machine enrollment through CloudDO", { timeout: 60_000 }, () => {
  it("keeps creates legacy until the creator enrolls, then enforces private and shared access", async () => {
    const x = person(SHARED_TEAM), mate = person(SHARED_TEAM), outsider = person()
    // The DO trusts TeamDO's roster, not the principal's assertion of membership.
    await inDO(teamStub(x.team), async (owner) => { owner.memberRole = async (_team: string, user: string) => [x.user, mate.user].includes(user) ? "member" : null })
    await ensureUser(x)
    await ensureUser(mate)
    const { machine } = await createdAndBound(x)
    const call = (p: typeof x.p, op: string, params: unknown, key?: string) =>
      x.stub.submit(x.team, p, frame(op, params, key)).then(reply)
    const get = () => x.stub.readOp(x.team, x.p, "cloud.machine.get", { machine })
    const legacy = (await get()).value
    expect(legacy.visibility).toBeUndefined()
    expect(await x.stub.readOp(x.team, mate.p, "cloud.machine.get", { machine })).toMatchObject({ ok: true })
    expect(await call(mate.p, "cloud.machine.rename", { machine, name: "not mine" })).toMatchObject({ code: "auth.forbidden" })
    const enroll = { machine, visibility: "private", expected_revision: legacy.revision }
    expect(await call(mate.p, "cloud.machine.set_visibility", enroll)).toMatchObject({ code: "auth.forbidden" })
    expect(await call(outsider.p, "cloud.machine.set_visibility", enroll)).toMatchObject({ code: "auth.forbidden" })
    expect(await call(installOf(x.p), "cloud.machine.set_visibility", enroll)).toMatchObject({ code: "auth.forbidden" })
    const key = crypto.randomUUID()
    expect(await call(x.p, "cloud.machine.set_visibility", enroll, key)).toMatchObject({ t: "result", value: { machine: { visibility: "private" } } })
    expect(await call(x.p, "cloud.machine.set_visibility", enroll, key)).toMatchObject({ t: "result", replayed: true })
    expect(await call(x.p, "cloud.machine.set_visibility", { ...enroll, visibility: "team" })).toMatchObject({ code: "revision.conflict" })
    expect(await x.stub.readOp(x.team, mate.p, "cloud.machine.get", { machine })).toMatchObject({ code: "cloud.machine.not_found" })
    expect(JSON.stringify(await x.stub.readOp(x.team, mate.p, "cloud.machine.list", {}))).not.toContain(machine)
    expect(await x.stub.readOp(x.team, mate.p, "cloud.machine.connect_info", { machine })).toMatchObject({ ok: false })
    const snap = await call(x.p, "cloud.snapshot.create", { machine })
    expect(snap).toMatchObject({ t: "result", value: { snapshot: { visibility: "private" } } })
    const snapshot = snap.value.snapshot.id
    expect(JSON.stringify(await x.stub.readOp(x.team, mate.p, "cloud.snapshot.list", {}))).not.toContain(snapshot)
    expect(await call(mate.p, "cloud.snapshot.restore", { snapshot })).toMatchObject({ code: "cloud.snapshot.not_found" })
    expect(await call(mate.p, "cloud.machine.create", { size: SIZE, from_snapshot: snapshot })).toMatchObject({ code: "cloud.snapshot.not_found" })
    const revision = (await get()).value.revision
    expect(await call(x.p, "cloud.machine.set_visibility", { machine, visibility: "team", expected_revision: revision })).toMatchObject({ t: "result" })
    expect(await call(mate.p, "cloud.machine.rename", { machine, name: "team box" })).toMatchObject({ t: "result" })
    expect(await x.stub.readOp(x.team, mate.p, "cloud.machine.connect_info", { machine })).toMatchObject({ ok: true })
    expect(await call(mate.p, "cloud.machine.pause", { machine })).toMatchObject({ t: "result" })
    expect(await call(mate.p, "cloud.machine.start", { machine })).toMatchObject({ t: "result" })
    const shared = await call(mate.p, "cloud.snapshot.create", { machine })
    expect(shared).toMatchObject({ t: "result", value: { snapshot: { visibility: "team" } } })
    expect(await call(x.p, "cloud.snapshot.restore", { snapshot: shared.value.snapshot.id })).toMatchObject({ t: "result" })
    // Sharing a machine does not enroll its pre-existing private snapshots.
    expect(await call(mate.p, "cloud.snapshot.restore", { snapshot })).toMatchObject({ code: "cloud.snapshot.not_found" })
    expect(await call(mate.p, "cloud.machine.delete", { machine })).toMatchObject({ code: "auth.forbidden" })
  })

  it("does not share personal creates or let a visibility change move one into a team", async () => {
    const x = person()
    const result = reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.create", { size: SIZE })))
    expect(result).toMatchObject({ t: "result" })
    expect(result.value.machine.visibility).toBeUndefined()
    const machine = result.value.machine.id
    const current = (await x.stub.readOp(x.team, x.p, "cloud.machine.get", { machine })).value
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.set_visibility", { machine, visibility: "team", expected_revision: current.revision })))).toMatchObject({ code: "auth.forbidden" })
  })
})

it("filters private live events, snapshots, and replay even after a newer public change", async () => {
  const x = person(SHARED_TEAM), mate = person(SHARED_TEAM)
  await inDO(teamStub(x.team), async (owner) => { owner.memberRole = async () => "member" })
  const made = reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.create", { size: SIZE })))
  expect(made).toMatchObject({ t: "result" })
  const machine = made.value.machine.id
  const current = await x.stub.readOp(x.team, x.p, "cloud.machine.get", { machine })
  const open = async (p: typeof x.p) => {
    const stub = x.stub as unknown as { fetch(r: Request): Promise<Response> }
    const response = await stub.fetch(new Request("https://cloud.test/", { headers: {
      Upgrade: "websocket", "x-cmux-entity": x.team, "x-cmux-principal": JSON.stringify(p)
    } }))
    expect(response.status).toBe(101)
    const ws = response.webSocket!
    const seen: any[] = [], listeners = new Set<(f: any) => void>()
    ws.addEventListener("message", (e) => { const f = JSON.parse(String(e.data)); seen.push(f); for (const on of listeners) on(f) })
    ws.accept()
    const wait = (pred: (f: any) => boolean) => new Promise<any>((resolve, reject) => {
      const on = (f: any) => { if (pred(f)) { clearTimeout(timer); listeners.delete(on); resolve(f) } }
      const timer = setTimeout(() => { listeners.delete(on); reject(new Error("missing CloudDO frame")) }, 5000)
      listeners.add(on)
    })
    return { ws, seen, wait }
  }
  const a = await open(x.p), b = await open(mate.p)
  try {
    const first = b.wait((f) => f.t === "snapshot")
    b.ws.send(JSON.stringify({ t: "subscribe" }))
    const initial = await first
    const ownerFirst = a.wait((f) => f.t === "snapshot")
    a.ws.send(JSON.stringify({ t: "subscribe" }))
    await ownerFirst
    a.seen.length = 0; b.seen.length = 0
    const hidden = b.wait((f) => f.t === "snapshot" && f.seq > initial.seq)
    const visible = a.wait((f) => f.event === "cloud.machine.upsert" && f.data.machine.visibility === "private")
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.set_visibility", { machine, visibility: "private", expected_revision: current.value.revision })))).toMatchObject({ t: "result" })
    await Promise.all([hidden, visible])
    expect(JSON.stringify(b.seen)).not.toContain(machine)
    const publicCreate = reply(await x.stub.submit(x.team, mate.p, frame("cloud.machine.create", { size: SIZE })))
    expect(publicCreate).toMatchObject({ t: "result" })
    const replay = await open(mate.p)
    try {
      const replayed = replay.wait((f) => f.t === "snapshot")
      replay.ws.send(JSON.stringify({ t: "subscribe", after_seq: initial.seq }))
      await replayed
      expect(JSON.stringify(replay.seen)).not.toContain(machine)
    } finally { replay.ws.close() }
  } finally { a.ws.close(); b.ws.close() }
}, 60_000)
