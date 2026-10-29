import { describe, expect, it } from "vitest"
import { ensureUser, frame, installOf, person, reply, SIZE } from "./cloud-bind-support.ts"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * Cloud environments through CloudDO in the Workers runtime (plans/cmux-next/cloud-environments-DESIGN.md):
 * set and list, a build that boots a builder on the fake provider, runs the detached setup through
 * the guest exec, snapshots and deletes the builder, then boots from the snapshot; a stale or unbuilt
 * environment boots cold and starts the setup on the new machine; secrets stay refused.
 */

type Ctl = {
  vms: Array<{ name: string; snapshot: string | null }>
  snapshots: Array<{ slug: string; source: string }>
  execs: Array<{ vm: string; kind: string }>
}
type X = ReturnType<typeof person>
const ctl = async (x: X, cmd: Record<string, unknown> = {}) => (await x.stub.fakeControl(cmd)) as unknown as Ctl
const SPEC = { name: "web", repo: "manaflow-ai/cmux@feat-cmux-next", setup_script: "cd web && bun install", env: [{ name: "NODE_ENV", value: "development" }] }

const setEnv = async (x: X, params: Record<string, unknown>) => reply(await x.stub.submit(x.team, x.p, frame("cloud.environment.set", params)))
const list = async (x: X) => (await x.stub.readOp(x.team, x.p, "cloud.environment.list", {})).value.environments as Array<Record<string, any>>
const built = async (x: X) => {
  const id = (await setEnv(x, SPEC)).value.environment.id as string
  const r = reply(await x.stub.submit(x.team, x.p, frame("cloud.environment.build", { environment: id })))
  expect(r, JSON.stringify(r)).toMatchObject({ t: "result", value: { built: true, environment: { status: "building" } } })
  await fireAlarm(x.stub)
  return id
}

describe("cloud environments", { timeout: 60_000 }, () => {
  it("set creates and edits; list shows the inputs; invalid input, other principals and unknown ids are refused", async () => {
    const x = person()
    await ensureUser(x)
    const created = await setEnv(x, SPEC)
    expect(created, JSON.stringify(created)).toMatchObject({ t: "result", value: { environment: { name: "web", repo: "manaflow-ai/cmux@feat-cmux-next", status: "unbuilt", snapshot: null, last_build: null } } })
    const id = created.value.environment.id as string
    expect(id).toMatch(/^env_[a-z0-9]{20}$/)
    expect((await setEnv(x, { environment: id, name: "web app" })).value.environment).toMatchObject({ name: "web app", setup_script: "cd web && bun install" })
    expect(await list(x)).toEqual([expect.objectContaining({ id, name: "web app", env: [{ name: "NODE_ENV", value: "development" }] })])
    expect(await setEnv(x, { name: "x", repo: "https://user:pw@github.com/a/b" })).toMatchObject({ t: "reject", code: "cloud.environment.invalid", details: { field: "repo" } })
    expect(await setEnv(x, { name: "x", env: [{ name: "PATH", value: "/x" }] })).toMatchObject({ t: "reject", code: "cloud.environment.invalid", details: { field: "env" } })
    expect(await setEnv(x, { setup_script: "true" })).toMatchObject({ t: "reject", code: "cloud.environment.invalid", details: { field: "name" } })
    expect(await setEnv(x, { environment: "env_00000000000000000009", name: "x" })).toMatchObject({ t: "reject", code: "cloud.environment.not_found" })
    expect(reply(await x.stub.submit(x.team, installOf(x.p), frame("cloud.environment.build", { environment: id })))).toMatchObject({ t: "reject", code: "approval.pending" })
  })

  it("build boots a builder, runs the setup, snapshots, deletes every builder VM, and a rebuild of the same inputs changes nothing", async () => {
    const x = person()
    await ensureUser(x)
    const id = await built(x)
    const [env] = await list(x)
    expect(env, JSON.stringify(env)).toMatchObject({ id, status: "ready", last_build: { state: "ready", error: null } })
    const snapshot = env!.snapshot as string
    expect(snapshot).toMatch(/^snap_/)
    const c = await ctl(x)
    expect(c.vms).toEqual([])
    expect(c.snapshots.map((s) => s.slug)).toEqual([`cmuxnp-test-cld-${snapshot.replace(/_/g, "-")}`])
    expect(c.execs.map((e) => e.kind)).toEqual(expect.arrayContaining(["probe", "start", "poll"]))
    expect((await x.stub.readOp(x.team, x.p, "cloud.snapshot.list", {})).value.snapshots).toEqual([expect.objectContaining({ id: snapshot, status: "ready" })])
    expect((await x.stub.readOp(x.team, x.p, "cloud.plan.get", {})).value.usage.saved).toBe(1)
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.environment.build", { environment: id })))).toMatchObject({ t: "result", value: { built: false, environment: { status: "ready" } } })
  })

  it("boot uses the ready snapshot and runs nothing; after an edit the environment is stale and boots cold with the setup started on the new machine", async () => {
    const x = person()
    await ensureUser(x)
    const id = await built(x)
    const snapshot = (await list(x))[0]!.snapshot as string
    const execsBefore = (await ctl(x)).execs.length
    const warm = reply(await x.stub.submit(x.team, x.p, frame("cloud.environment.boot", { environment: id, size: SIZE })))
    expect(warm, JSON.stringify(warm)).toMatchObject({ t: "result", value: { boot: "snapshot", machine: { status: "provisioning" } } })
    let c = await ctl(x)
    expect(c.vms).toEqual([expect.objectContaining({ snapshot: `cmuxnp-test-cld-${snapshot.replace(/_/g, "-")}` })])
    expect(c.execs.length).toBe(execsBefore)

    expect((await setEnv(x, { environment: id, setup_script: "cd web && bun install --frozen-lockfile" })).value.environment.status).toBe("stale")
    const cold = reply(await x.stub.submit(x.team, x.p, frame("cloud.environment.boot", { environment: id, size: SIZE })))
    expect(cold, JSON.stringify(cold)).toMatchObject({ t: "result", value: { boot: "cold" } })
    c = await ctl(x)
    const coldVm = `cmuxnp-test-cld-${(cold.value.machine.id as string).replace(/_/g, "-")}`
    expect(c.vms).toEqual(expect.arrayContaining([expect.objectContaining({ name: coldVm, snapshot: null })]))
    expect(c.execs).toEqual(expect.arrayContaining([{ vm: coldVm, kind: "start" }]))
  })

  it("a failed setup records the log tail, frees the saved slot, and keeps the previous snapshot", async () => {
    const x = person()
    await ensureUser(x)
    const id = await built(x)
    const first = (await list(x))[0]!.snapshot as string
    await setEnv(x, { environment: id, setup_script: "exit 3" })
    await ctl(x, { exec_build_exit: 3, exec_log: "lockfile mismatch" })
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.environment.build", { environment: id }))).t).toBe("result")
    await fireAlarm(x.stub)
    const [env] = await list(x)
    expect(env, JSON.stringify(env)).toMatchObject({ status: "stale", snapshot: first, last_build: { state: "failed", log_tail: expect.stringContaining("lockfile mismatch"), error: { code: "cloud.environment.build_failed" } } })
    expect((await x.stub.readOp(x.team, x.p, "cloud.plan.get", {})).value.usage.saved).toBe(1)
    expect((await ctl(x)).vms).toEqual([])
  })

  it("secret variables are stored as names but a build or a boot is refused until the vault exists", async () => {
    const x = person()
    await ensureUser(x)
    const id = (await setEnv(x, { ...SPEC, env: [{ name: "OPENAI_API_KEY", secret: "openai" }] })).value.environment.id as string
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.environment.build", { environment: id })))).toMatchObject({ t: "reject", code: "cloud.environment.secrets_unavailable" })
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.environment.boot", { environment: id, size: SIZE })))).toMatchObject({ t: "reject", code: "cloud.environment.secrets_unavailable" })
    expect((await ctl(x)).vms).toEqual([])
  })

  it("delete removes the environment and its snapshot", async () => {
    const x = person()
    await ensureUser(x)
    const id = await built(x)
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.environment.delete", { environment: id })))).toMatchObject({ t: "result", value: { deleted: true } })
    expect(await list(x)).toEqual([])
    await fireAlarm(x.stub)
    expect((await ctl(x)).snapshots).toEqual([])
    expect((await x.stub.readOp(x.team, x.p, "cloud.plan.get", {})).value.usage.saved).toBe(0)
  })
})
