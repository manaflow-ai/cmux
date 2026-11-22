import { env } from "cloudflare:workers"
import type { Principal } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import type { SubmitResult } from "../src/owner-do.ts"
import { defaultInstallClasses } from "../src/domains/user.ts"
import { createdAndBound, ensureUser, frame, installOf, person, post, reply, signedInWithInstall, SIZE } from "./cloud-bind-support.ts"
import { runInDurableObject } from "cloudflare:test"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * cx-wb5.65 (chief decisions 2026-10-08). The Mac relay calls Cloud with an install token.
 * - pause and start: allowed for a non-agent install whose grant covers mutate-shared, at most
 *   10 starts per install per hour; the actor is in the access audit. Agents stay refused.
 * - create, resize, delete and snapshot create/delete/restore: never grantable to an install; the
 *   request goes through the G8 approval path (approval.pending, the person answers in the feed
 *   with their own session, the op runs once, a same-key retry gets its result).
 */

const MAC = [...defaultInstallClasses("mac")]
type Stub = { submit(entity: string, p: Principal, f: unknown): Promise<SubmitResult> }
const ns = (name: string) => (env as unknown as Record<string, DurableObjectNamespace>)[name]!
const userStub = (user: string) => ns("USER_DO").get(ns("USER_DO").idFromName(user)) as unknown as Stub
const feedStub = (user: string) => ns("FEED_DO").get(ns("FEED_DO").idFromName(user))

/** A registered mac install of `x` (UserDO holds its grant, so an approved run can re-resolve it). */
const macInstall = async (x: ReturnType<typeof person>): Promise<Principal> => {
  await ensureUser(x)
  // The personal team (the Worker's user.ensure does this): the answer-time membership check reads it.
  const team = ns("TEAM_DO").get(ns("TEAM_DO").idFromName(x.team)) as unknown as Stub
  expect(reply(await team.submit(x.team, x.p, { t: "op", op: "team.ensure_personal", params: {}, idempotency_key: `ensure-personal:${x.user}`, origin: "cli" })).t).toBe("result")
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
  const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
  const r = reply(await userStub(x.user).submit(x.user, x.p, { t: "op", op: "install.register", params: { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y }, kind: "mac", name: "mac", device_name: "mac", platform: "macos" }, idempotency_key: crypto.randomUUID(), origin: "user" }))
  if (r.t !== "result") throw new Error(JSON.stringify(r))
  await fireAlarm(userStub(x.user))
  const install = r.value.id as string
  return { identity: install, kind: "install", user: x.user, team: x.team, install, grant: r.value.grant as string, grant_classes: MAC, install_kind: "mac" }
}

const feedItems = async (x: ReturnType<typeof person>) => {
  const r = await (feedStub(x.user) as unknown as { readOp(e: string, p: Principal, op: string, params: unknown): Promise<any> }).readOp(x.user, x.p, "feed.list", {})
  return ((r.value?.items ?? []) as Array<any>).filter((i) => i.kind === "approve")
}
type CloudRpc = { systemDeliver(e: string, source: string, items: unknown): Promise<{ done: Array<number> }> }
const runIn = runInDurableObject as unknown as <T>(stub: unknown, fn: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>
/** Redelivers the person's allow for `request` (the FeedDO outbox delivers at least once). */
const redeliver = async (x: ReturnType<typeof person>, request: string, id: number) => {
  const digest = (await x.stub.readOp(x.team, x.p, "integration.approval.get", { request })).value.digest as string
  return (x.stub as unknown as CloudRpc).systemDeliver(x.team, `feed:${x.user}`, [{ id, op: "integration.approval.answered", key: `approval:${request}:${id}`, params: { request, decision: "allow", digest } }])
}
const answer = async (x: ReturnType<typeof person>, item: string, decision: "allow" | "deny") => {
  const r = reply(await (feedStub(x.user) as unknown as Stub).submit(x.user, x.p, { t: "op", op: "feed.answer", params: { item, answer: decision === "allow" ? { decision, scope: "once" } : { decision } }, idempotency_key: crypto.randomUUID(), origin: "user" }))
  expect(r.t, JSON.stringify(r)).toBe("result")
  await fireAlarm(feedStub(x.user))
}

describe("Cloud ops from the Mac relay's install token (cx-wb5.65)", { timeout: 120_000 }, () => {
  it("a non-agent install with mutate-shared pauses and starts; agents and installs without mutate-shared are refused; the audit names the install", async () => {
    const x = person()
    await ensureUser(x)
    const { machine } = await createdAndBound(x)
    const mac = installOf(x.p, MAC, "mac")
    expect(reply(await x.stub.submit(x.team, { ...mac, agent: "agent_00000000000000000001" }, frame("cloud.machine.pause", { machine })))).toMatchObject({ t: "reject", code: "auth.forbidden" })
    expect(reply(await x.stub.submit(x.team, installOf(x.p, ["read", "mutate-own", "cloud-link"], "ios"), frame("cloud.machine.pause", { machine })))).toMatchObject({ t: "reject", code: "auth.forbidden" })
    expect(reply(await x.stub.submit(x.team, mac, frame("cloud.machine.pause", { machine })))).toMatchObject({ t: "result", value: { machine: { status: "pausing" } } })
    expect(reply(await x.stub.submit(x.team, mac, frame("cloud.machine.start", { machine })))).toMatchObject({ t: "result", value: { machine: { status: "starting" } } })
    const audit = (await x.stub.fakeControl({})).audit
    expect(audit.filter((a) => a.install === mac.install).map((a) => a.op)).toEqual(expect.arrayContaining(["cloud.machine.pause", "cloud.machine.start"]))
  })

  it("an install starts at most 10 times an hour; a replay and a person's start do not count", async () => {
    const x = person()
    await ensureUser(x)
    const { machine } = await createdAndBound(x)
    const mac = installOf(x.p, MAC, "mac")
    const pause = async () => expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.pause", { machine }))).t).toBe("result")
    // A replay and a person's start come first: if they counted, the tenth install start below would be refused.
    await pause()
    const first = crypto.randomUUID()
    expect(reply(await x.stub.submit(x.team, mac, frame("cloud.machine.start", { machine }, first))).t).toBe("result")
    expect(reply(await x.stub.submit(x.team, mac, frame("cloud.machine.start", { machine }, first)))).toMatchObject({ t: "result", replayed: true })
    await pause()
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.start", { machine }))).t).toBe("result")
    for (let i = 1; i < 10; i++) {
      await pause()
      expect(reply(await x.stub.submit(x.team, mac, frame("cloud.machine.start", { machine }))).t, `start ${i + 1}`).toBe("result")
    }
    await pause()
    expect(reply(await x.stub.submit(x.team, mac, frame("cloud.machine.start", { machine })))).toMatchObject({ t: "reject", code: "cloud.rate_limited", retryable: true })
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.start", { machine }))).t).toBe("result")
  })

  it("an install's create waits for the person's approval, runs once after it, and a same-key retry gets the machine", async () => {
    const x = person()
    const mac = await macInstall(x)
    const key = crypto.randomUUID()
    const pending = reply(await x.stub.submit(x.team, mac, frame("cloud.machine.create", { size: SIZE }, key))) as any
    expect(pending, JSON.stringify(pending)).toMatchObject({ t: "reject", code: "approval.pending", retryable: true })
    const request = pending.details.request as string
    expect(request).toMatch(/^apr_[a-f0-9]{32}$/)
    expect((await x.stub.readOp(x.team, x.p, "cloud.machine.list", {})).value.machines).toEqual([])
    // A retry with the same key stays pending and asks only once.
    expect(reply(await x.stub.submit(x.team, mac, frame("cloud.machine.create", { size: SIZE }, key)))).toMatchObject({ t: "reject", code: "approval.pending" })
    const items = await feedItems(x)
    expect(items).toHaveLength(1)
    expect(items[0].poster).toMatchObject({ kind: "integration", scope: `system:cloud:${x.team}` })
    expect(items[0].prompt.action).toMatchObject({ tool: "cloud.machine.create", risk: "money", input: { approval: { team: x.team, request } } })
    // The person reads the exact request; the install cannot.
    expect(await x.stub.readOp(x.team, x.p, "integration.approval.get", { request })).toMatchObject({ ok: true, value: { request, op: "cloud.machine.create", state: "pending", params: { size: SIZE } } })
    expect(await x.stub.readOp(x.team, mac, "integration.approval.get", { request })).toMatchObject({ ok: false })
    await answer(x, items[0].id, "allow")
    const machines = (await x.stub.readOp(x.team, x.p, "cloud.machine.list", {})).value.machines as Array<{ id: string }>
    expect(machines).toHaveLength(1)
    const done = reply(await x.stub.submit(x.team, mac, frame("cloud.machine.create", { size: SIZE }, key)))
    expect(done).toMatchObject({ t: "result", replayed: true, value: { machine: { id: machines[0]!.id } } })
    expect(((await x.stub.fakeControl({})) as unknown as { creates: number }).creates).toBe(1)
    expect(await x.stub.readOp(x.team, x.p, "integration.approval.get", { request })).toMatchObject({ ok: true, value: { state: "done", params: {} } })
    expect((await x.stub.fakeControl({})).audit.some((a) => a.op === "approval.run" && a.install === mac.install && a.request === request)).toBe(true)
  })

  it("a denied delete never runs; the retry answers approval.denied; agents get no approval request at all", async () => {
    const x = person()
    const mac = await macInstall(x)
    const { machine } = await createdAndBound(x)
    const key = crypto.randomUUID()
    expect(reply(await x.stub.submit(x.team, mac, frame("cloud.machine.delete", { machine }, key)))).toMatchObject({ t: "reject", code: "approval.pending" })
    const [item] = await feedItems(x)
    expect(item.prompt.action).toMatchObject({ tool: "cloud.machine.delete", risk: "destructive" })
    await answer(x, item.id, "deny")
    expect(reply(await x.stub.submit(x.team, mac, frame("cloud.machine.delete", { machine }, key)))).toMatchObject({ t: "reject", code: "approval.denied" })
    expect(await x.stub.readOp(x.team, x.p, "cloud.machine.get", { machine })).toMatchObject({ ok: true, value: { status: "running" } })
    for (const op of ["cloud.machine.create", "cloud.machine.delete", "cloud.machine.resize", "cloud.snapshot.create"]) {
      const params = op === "cloud.machine.create" ? { size: SIZE } : op === "cloud.machine.resize" ? { machine, size: { cpu: 4 } } : { machine }
      expect(reply(await x.stub.submit(x.team, { ...mac, agent: "agent_00000000000000000001" }, frame(op, params)))).toMatchObject({ t: "reject", code: "auth.forbidden" })
    }
    expect(await feedItems(x)).toHaveLength(1)
  })

  it("resize and snapshot create from an install go through the approval path too", async () => {
    const x = person()
    const mac = await macInstall(x)
    const { machine } = await createdAndBound(x)
    expect(reply(await x.stub.submit(x.team, mac, frame("cloud.machine.resize", { machine, size: { cpu: 4 } })))).toMatchObject({ t: "reject", code: "approval.pending" })
    expect(reply(await x.stub.submit(x.team, mac, frame("cloud.snapshot.create", { machine })))).toMatchObject({ t: "reject", code: "approval.pending" })
    expect((await feedItems(x)).map((i) => i.prompt.action.tool).sort()).toEqual(["cloud.machine.resize", "cloud.snapshot.create"])
  })

  it("least privilege: a read-only or iPhone-default install cannot ask (no prompt); an RPC principal that names an approval still waits; approval: keys are reserved", async () => {
    const x = person()
    const mac = await macInstall(x)
    for (const classes of [["read"], [...defaultInstallClasses("ios")]]) {
      expect(reply(await x.stub.submit(x.team, { ...mac, grant_classes: classes, install_kind: "ios" }, frame("cloud.machine.create", { size: SIZE })))).toMatchObject({ t: "reject", code: "auth.forbidden" })
    }
    expect(await feedItems(x)).toHaveLength(0)
    expect(reply(await x.stub.submit(x.team, { ...mac, approval: "apr_00000000000000000000000000000000" }, frame("cloud.machine.create", { size: SIZE })))).toMatchObject({ t: "reject", code: "approval.pending" })
    expect(reply(await x.stub.submit(x.team, mac, frame("cloud.machine.pause", { machine: "vm_00000000000000000000" }, "approval:apr_00000000000000000000000000000000")))).toMatchObject({ t: "reject", code: "validation.invalid" })
    expect(((await x.stub.fakeControl({})) as unknown as { creates: number }).creates).toBe(0)
  })

  it("an install revoked before the answer runs nothing; a redelivered answer runs a request once", async () => {
    const x = person()
    const mac = await macInstall(x)
    const revoked = reply(await x.stub.submit(x.team, mac, frame("cloud.machine.create", { size: SIZE }))) as any
    const [item] = await feedItems(x)
    expect(reply(await userStub(x.user).submit(x.user, x.p, { t: "op", op: "install.revoke", params: { install: mac.install }, idempotency_key: crypto.randomUUID(), origin: "user" })).t).toBe("result")
    await answer(x, item.id, "allow")
    expect(await x.stub.readOp(x.team, x.p, "integration.approval.get", { request: revoked.details.request })).toMatchObject({ value: { state: "denied" } })
    expect(((await x.stub.fakeControl({})) as unknown as { creates: number }).creates).toBe(0)
    const again = await macInstall(x)
    const pending = reply(await x.stub.submit(x.team, again, frame("cloud.machine.create", { size: SIZE }))) as any
    const second = (await feedItems(x)).find((i) => i.prompt.action.input.approval.request === pending.details.request)
    await answer(x, second.id, "allow")
    await redeliver(x, pending.details.request, 990_001)
    expect(((await x.stub.fakeControl({})) as unknown as { creates: number }).creates).toBe(1)
  })

  it("a run cut off by a restart settles by running the same key again, on redelivery and from the alarm, without breaking the alarm", async () => {
    const x = person()
    const mac = await macInstall(x)
    const requests: Array<string> = []
    for (let i = 0; i < 2; i++) requests.push((reply(await x.stub.submit(x.team, mac, frame("cloud.machine.create", { size: SIZE }))) as any).details.request)
    // Both runs were started and then cut off (the object restarted before the op committed): running, not in flight.
    await runIn(x.stub, async (_i, state) => state.storage.sql.exec(`UPDATE integration_approvals SET state = 'running'`))
    await redeliver(x, requests[0]!, 990_002)
    expect(await x.stub.readOp(x.team, x.p, "integration.approval.get", { request: requests[0] })).toMatchObject({ value: { state: "done" } })
    await runIn(x.stub, async (_i, state) => state.storage.sql.exec(`UPDATE integration_approvals SET expires_at = 1 WHERE request = ?`, requests[1]))
    expect(await fireAlarm(x.stub)).toBe(true)
    expect(await x.stub.readOp(x.team, x.p, "integration.approval.get", { request: requests[1] })).toMatchObject({ value: { state: "done" } })
    // A run cut off AFTER its op committed (before the row ended): the same key replays the committed intent, no second create.
    await runIn(x.stub, async (_i, state) => state.storage.sql.exec(`UPDATE integration_approvals SET state = 'running', ended_at = NULL WHERE request = ?`, requests[0]))
    await redeliver(x, requests[0]!, 990_003)
    expect(await x.stub.readOp(x.team, x.p, "integration.approval.get", { request: requests[0] })).toMatchObject({ value: { state: "done" } })
    expect(((await x.stub.fakeControl({})) as unknown as { creates: number }).creates).toBe(2)
  })

  it("Worker: a mac install token's create answers approval.pending, and the person reads it through integration.approval.get", async () => {
    const m = await signedInWithInstall("cloud-relay-approvals-1", "mac")
    const r = await post("/v1/ops", m.installToken, { op: "cloud.machine.create", params: { size: SIZE }, idempotency_key: crypto.randomUUID(), origin: "cli" })
    expect(r.body, JSON.stringify(r.body)).toMatchObject({ ok: false, error: { code: "approval.pending", retryable: true } })
    const request = r.body.error.details.request as string
    const view = await post("/v1/read", m.session, { op: "integration.approval.get", params: { request } })
    expect(view.body, JSON.stringify(view.body)).toMatchObject({ value: { request, op: "cloud.machine.create", state: "pending" } })
    expect((await post("/v1/read", m.installToken, { op: "integration.approval.get", params: { request } })).status).toBe(403)
  })
})
