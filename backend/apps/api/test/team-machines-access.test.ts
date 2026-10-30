import { describe, expect, it } from "vitest"
import { createdAndBound, ensureUser, frame, installOf, person, reply, SIZE } from "./cloud-bind-support.ts"
import { SHARED_TEAM } from "./setup/cloud-teams.ts"

// Exercise CloudDO's persisted reads, admission, reducer and provider boundary, not policy helpers.
describe("explicit team machine enrollment through CloudDO", { timeout: 60_000 }, () => {
  it("keeps creates legacy until the creator enrolls, then enforces private and shared access", async () => {
    const x = person(SHARED_TEAM), mate = person(SHARED_TEAM), outsider = person()
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
