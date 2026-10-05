import { runInDurableObject } from "cloudflare:test"
import { describe, expect, it } from "vitest"
import { createdAndBound, ensureUser, frame, installOf, person, post, reply, SIZE, signedInWithInstall, bindFile, cloudStub, DAEMON, vmKey, WG_KEY, worker } from "./cloud-bind-support.ts"

/**
 * Snapshots (state-placement.md 7 item 4; money ops: a signed-in person, ledger first, the
 * environment's name prefix on the snapshot slug, the per-team limit, max_saved): create
 * (Freestyle POST /v5/vms/{id}/snapshot), list, delete (DELETE /v5/snapshots/{id}, only our recorded
 * slug), restore (a new machine booted from the snapshot). Events cloud.snapshot.upsert / .removed.
 */

type Ctl = { snapshots: Array<{ slug: string; source: string }>; vms: Array<{ name: string; snapshot: string | null }> }
const ctl = async (x: { stub: { fakeControl(c: unknown): Promise<unknown> } }) => (await x.stub.fakeControl({})) as unknown as Ctl

describe("snapshots", { timeout: 60_000 }, () => {
  it("create answers creating, lands ready with one provider snapshot under our prefix, counts as saved, and replays", async () => {
    const x = person()
    await ensureUser(x)
    const { machine } = await createdAndBound(x)
    const key = crypto.randomUUID()
    const r = reply(await x.stub.submit(x.team, x.p, frame("cloud.snapshot.create", { machine, name: "checkpoint" }, key)))
    expect(r, JSON.stringify(r)).toMatchObject({ t: "result", value: { snapshot: { machine, name: "checkpoint", status: "creating" } } })
    const id = r.value.snapshot.id as string
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.snapshot.create", { machine, name: "checkpoint" }, key)))).toMatchObject({ t: "result", replayed: true })
    const list = await x.stub.readOp(x.team, x.p, "cloud.snapshot.list", { machine })
    expect(list.value.snapshots).toEqual([expect.objectContaining({ id, status: "ready" })])
    const c = await ctl(x)
    expect(c.snapshots.map((s) => s.slug)).toEqual([`cmuxnp-test-cld-${id.replace(/_/g, "-")}`])
    expect((await x.stub.readOp(x.team, x.p, "cloud.plan.get", {})).value.usage.saved).toBe(1)
  })

  it("delete removes the provider snapshot by its recorded slug and frees the saved slot", async () => {
    const x = person()
    await ensureUser(x)
    const { machine } = await createdAndBound(x)
    const id = reply(await x.stub.submit(x.team, x.p, frame("cloud.snapshot.create", { machine }))).value.snapshot.id as string
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.snapshot.delete", { snapshot: id })))).toMatchObject({ t: "result", value: { deleted: true } })
    expect((await x.stub.readOp(x.team, x.p, "cloud.snapshot.list", {})).value.snapshots).toEqual([])
    expect((await ctl(x)).snapshots).toEqual([])
    expect((await x.stub.readOp(x.team, x.p, "cloud.plan.get", {})).value.usage.saved).toBe(0)
  })

  it("restore creates a new machine booted from the snapshot, with a fresh bind file", async () => {
    const x = person()
    await ensureUser(x)
    const { machine } = await createdAndBound(x)
    const id = reply(await x.stub.submit(x.team, x.p, frame("cloud.snapshot.create", { machine }))).value.snapshot.id as string
    const r = reply(await x.stub.submit(x.team, x.p, frame("cloud.snapshot.restore", { snapshot: id, name: "restored" })))
    expect(r, JSON.stringify(r)).toMatchObject({ t: "result", value: { machine: { name: "restored", status: "provisioning" } } })
    const restored = r.value.machine.id as string
    expect(restored).not.toBe(machine)
    const vm = (await ctl(x)).vms.find((v) => v.name.endsWith(restored.replace(/_/g, "-")))
    expect(vm?.snapshot).toBe(`cmuxnp-test-cld-${id.replace(/_/g, "-")}`)
    expect((await bindFile(x.stub, restored)).json.bind_token).toMatch(/^[A-Za-z0-9_-]{43}$/)
  })

  it("refuses an install, a machine that is not running or paused, an unknown snapshot, and a full saved quota", async () => {
    const x = person()
    await ensureUser(x)
    const { machine } = await createdAndBound(x)
    expect(reply(await x.stub.submit(x.team, installOf(x.p), frame("cloud.snapshot.create", { machine })))).toMatchObject({ t: "reject", code: "auth.forbidden" })
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.snapshot.restore", { snapshot: "snap_00000000000000000009" })))).toMatchObject({ t: "reject", code: "cloud.snapshot.not_found" })
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.snapshot.delete", { snapshot: "snap_00000000000000000009" })))).toMatchObject({ t: "reject", code: "cloud.snapshot.not_found" })
    for (let i = 0; i < 10; i++) expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.snapshot.create", { machine }))).t).toBe("result")
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.snapshot.create", { machine })))).toMatchObject({ t: "reject", code: "cloud.quota.exceeded", details: { resource: "saved", limit: 10, used: 10 } })
    const fresh = reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.create", { size: SIZE }))).value.machine.id as string
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.snapshot.create", { machine: fresh })))).toMatchObject({ t: "reject", code: "cloud.machine.not_running" })
  })

  it("subscribers get cloud.snapshot.upsert and cloud.snapshot.removed", async () => {
    const a = await signedInWithInstall("cloud-route-4", "mac")
    const machine = (await post("/v1/ops", a.session, { op: "cloud.machine.create", params: { size: SIZE }, idempotency_key: crypto.randomUUID(), origin: "user" })).body.value.machine.id as string
    const { json } = await bindFile(cloudStub(a.team), machine)
    await post("/v1/cloud/bind", undefined, { team: a.team, machine, bind_token: json.bind_token, wg_public_key: WG_KEY, daemon: DAEMON, install_public_jwk: (await vmKey()).jwk })
    const res = await worker.fetch("https://api.test/v1/wire/cloud", { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": `cmux.wire.v1, bearer.${a.session}` } })
    const ws = res.webSocket!
    const frames: Array<any> = []
    ws.addEventListener("message", (e) => frames.push(JSON.parse(e.data as string)))
    ws.accept()
    ws.send(JSON.stringify({ t: "subscribe" }))
    const wait = async (pred: (f: any) => boolean) => {
      for (let i = 0; i < 300 && !frames.some(pred); i++) await new Promise((r) => setTimeout(r, 10))
      return frames.find(pred)
    }
    await wait((f) => f.t === "snapshot")
    const created = await post("/v1/ops", a.session, { op: "cloud.snapshot.create", params: { machine }, idempotency_key: crypto.randomUUID(), origin: "user" })
    expect(created.body.ok, JSON.stringify(created.body)).toBe(true)
    const id = created.body.value.snapshot.id as string
    expect(await wait((f) => f.event === "cloud.snapshot.upsert" && f.data?.snapshot?.id === id && f.data?.snapshot?.status === "ready")).toBeDefined()
    await post("/v1/ops", a.session, { op: "cloud.snapshot.delete", params: { snapshot: id }, idempotency_key: crypto.randomUUID(), origin: "user" })
    expect(await wait((f) => f.event === "cloud.snapshot.removed" && f.data?.snapshot === id)).toBeDefined()
    ws.close()
  })

  it("a failed delete keeps the status from before; snapshot rows record their creator (review P3)", async () => {
    const x = person()
    await ensureUser(x)
    const { machine } = await createdAndBound(x)
    const id = reply(await x.stub.submit(x.team, x.p, frame("cloud.snapshot.create", { machine }))).value.snapshot.id as string
    await x.stub.fakeControl({ snapshot_delete_refuse: 1 } as never)
    reply(await x.stub.submit(x.team, x.p, frame("cloud.snapshot.delete", { snapshot: id })))
    const s1 = (await x.stub.readOp(x.team, x.p, "cloud.snapshot.list", {})).value.snapshots[0]
    expect(s1).toMatchObject({ id, status: "ready" })
    const creator = await (runInDurableObject as unknown as (s: unknown, f: (i: any) => Promise<unknown>) => Promise<any>)(x.stub, async (i: any) => i.boundEngine.rows.get("snapshot", id).row.creator)
    expect(creator).toBe(x.user)
  })

  it("a restore records its snapshot on the machine, so the provider call never guesses from the image id (review P3)", async () => {
    const x = person()
    await ensureUser(x)
    const { machine } = await createdAndBound(x)
    const id = reply(await x.stub.submit(x.team, x.p, frame("cloud.snapshot.create", { machine }))).value.snapshot.id as string
    const restored = reply(await x.stub.submit(x.team, x.p, frame("cloud.snapshot.restore", { snapshot: id }))).value.machine.id as string
    const rows = await (runInDurableObject as unknown as (s: unknown, f: (i: any) => Promise<unknown>) => Promise<any>)(x.stub, async (i: any) => [i.boundEngine.rows.get("machine", restored).row.from_snapshot, i.boundEngine.rows.get("machine", machine).row.from_snapshot])
    expect(rows).toEqual([`cmuxnp-test-cld-${id.replace(/_/g, "-")}`, undefined])
  })
})
