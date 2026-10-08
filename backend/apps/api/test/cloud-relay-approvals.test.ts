import { env } from "cloudflare:workers"
import type { Principal } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import type { SubmitResult } from "../src/owner-do.ts"
import { defaultInstallClasses } from "../src/domains/user.ts"
import { createdAndBound, ensureUser, frame, installOf, person, post, reply, signedInWithInstall, SIZE } from "./cloud-bind-support.ts"
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
  return (r.value.items as Array<any>).filter((i) => i.kind === "approve")
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
    let last = ""
    for (let i = 0; i < 10; i++) {
      expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.pause", { machine }))).t).toBe("result")
      last = crypto.randomUUID()
      expect(reply(await x.stub.submit(x.team, mac, frame("cloud.machine.start", { machine }, last))).t).toBe("result")
    }
    expect(reply(await x.stub.submit(x.team, mac, frame("cloud.machine.start", { machine }, last)))).toMatchObject({ t: "result", replayed: true })
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.pause", { machine }))).t).toBe("result")
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
