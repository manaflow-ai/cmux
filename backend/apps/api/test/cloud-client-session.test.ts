import { env } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import type { Principal } from "@cmux/ownership"
import { afterEach, describe, expect, it, vi } from "vitest"
import { GuardedCloudDriver } from "../src/cloud-driver.ts"
import { CLIENT_SESSION_LINUX_USER, ClientIdentityStore, clientSessionTtl, mintClientSessionOn, sweepClientIdentities, type ClientSessionHost } from "../src/cloud-client-session.ts"
import { ClientIdentityLeft, DriverError } from "../src/providers/contract.ts"
import { TEAM_MEMBER_LEFT_SOCKETS } from "../src/domains/team-members.ts"
import { FreestyleCloudProvider } from "../src/providers/freestyle/cloud.ts"
import { bindBody, bindFile, cloudStub, createdAndBound, installOf, person, post, sessionToken, worker } from "./cloud-bind-support.ts"

/** Client sessions (cloud-client-session.ts): one machine, its creator, the work user, a short TTL, no token in logs. */

type Reply = { ok: boolean; value?: any; refusal?: string }
type Stub = { mintClientSession(e: string, p: Principal, machine: string, ttl: number): Promise<Reply>; fakeControl(cmd: Record<string, unknown>): Promise<any> }
const stubOf = (team: string) => cloudStub(team) as unknown as Stub
const inDO = runInDurableObject as unknown as <T>(stub: unknown, cb: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>
const identities = (team: string) =>
  inDO(cloudStub(team), async (_i, state) => state.storage.sql.exec(`SELECT id, vm, user, tokens FROM cloud_fake_identity ORDER BY id`).toArray() as Array<{ id: string; vm: string; user: string; tokens: number }>)

/** Every console line written while `work` runs. */
const consoleDuring = async <T>(work: () => Promise<T>): Promise<{ result: T; lines: string }> => {
  const lines: Array<string> = []
  for (const m of ["log", "info", "warn", "error", "debug"] as const) vi.spyOn(console, m).mockImplementation((...a: Array<unknown>) => void lines.push(a.map(String).join(" ")))
  const result = await work()
  return { result, lines: lines.join("\n") }
}
afterEach(() => vi.restoreAllMocks())

describe("the Freestyle provider's client session", () => {
  const PREFIX = "cmuxnp-test-cld-"
  const NAME = `${PREFIX}vm-${"a".repeat(20)}`
  const TAG = { team: `team_${"t".repeat(20)}`, machine: `vm_${"m".repeat(20)}` }
  const SECRET = "fs-token-secret-value-0123456789"
  const mock = (opts: { grantStatus?: number; tokenStatus?: number; deleteStatus?: number; expiry?: (asked: string) => unknown } = {}) => {
    const calls: Array<{ method: string; path: string; body: any }> = []
    const identities = new Set<string>()
    let n = 0
    const fetchFn: typeof fetch = async (input, init) => {
      const req = new Request(input, init)
      expect(req.headers.get("authorization")).toBe("Bearer test-only-key")
      const path = new URL(req.url).pathname
      const body = (req.method === "POST" ? await req.json().catch(() => null) : null) as any
      calls.push({ method: req.method, path, body })
      const json = (b: unknown, status = 200) => Response.json(b, { status })
      if (path === `/v5/vms/${NAME}` && req.method === "GET") return json({ id: "fsvm-1", metadata: { cmux_next_team: TAG.team, cmux_next_machine: TAG.machine }, state: "running" })
      if (path === "/v5/identities" && req.method === "POST") return identities.add(`fsid-${++n}`), json({ id: `fsid-${n}`, managed: false })
      const m = path.match(/^\/v5\/identities\/([^/]+)(?:\/(permissions\/vm|tokens))?$/)
      if (m && !identities.has(m[1]!)) return json({ code: "NOT_FOUND", message: "no identity" }, 404)
      if (m && req.method === "DELETE" && opts.deleteStatus) return json({ code: "UNAVAILABLE" }, opts.deleteStatus)
      if (m && req.method === "DELETE") return identities.delete(m[1]!), new Response(null, { status: 204 })
      if (m?.[2] === "permissions/vm") return json({ id: "perm-1", identityId: m[1], vmId: body.vmId, allowedLinuxUsers: body.allowedLinuxUsers }, opts.grantStatus ?? 200)
      // A refused mint still echoes a token-shaped value: no error may carry it.
      if (m?.[2] === "tokens") return json({ id: "tok-1", token: SECRET, expiresAt: opts.expiry ? opts.expiry(body.expiresAt) : body.expiresAt, code: opts.tokenStatus ? SECRET : undefined }, opts.tokenStatus ?? 200)
      return json({ code: "UNMOCKED" }, 500)
    }
    return { calls, identities, driver: new GuardedCloudDriver(new FreestyleCloudProvider("test-only-key", "https://freestyle.test/", "cmuxnp-test-vmimg-x", fetchFn), PREFIX) }
  }

  it("grants only this VM as the work user, with the asked expiry, and reuses the identity", async () => {
    const { calls, driver } = mock()
    const at = Date.UTC(2026, 9, 28, 12, 0, 0)
    const first = await driver.clientSession(NAME, TAG, "cmux", at, null)
    expect(first.grant).toEqual({ identity: "fsid-1", token: SECRET, expiresAt: at, vmId: "fsvm-1", linuxUser: "cmux", apiBaseUrl: "https://freestyle.test", ssh: { host: "beta-ssh.freestyle.sh", user: "fsvm-1+cmux" } })
    expect(first.stale).toBeNull()
    expect(calls.find((c) => c.path.endsWith("/permissions/vm"))?.body).toEqual({ vmId: "fsvm-1", allowedLinuxUsers: ["cmux"] })
    expect(calls.find((c) => c.path.endsWith("/tokens"))?.body).toEqual({ expiresAt: new Date(at).toISOString() })

    calls.length = 0
    const again = await driver.clientSession(NAME, TAG, "cmux", at, { identity: "fsid-1", vmId: "fsvm-1" })
    expect(again.grant.identity).toBe("fsid-1")
    expect(calls.map((c) => `${c.method} ${c.path}`)).toEqual([`GET /v5/vms/${NAME}`, "POST /v5/identities/fsid-1/tokens"])
  })

  it("never reuses an identity granted another VM, and replaces one the provider lost", async () => {
    const { driver, identities } = mock()
    const moved = await driver.clientSession(NAME, TAG, "cmux", Date.now() + 60_000, { identity: "fsid-old", vmId: "fsvm-gone" })
    expect(moved.grant.identity).toBe("fsid-1")
    expect(moved.stale).toBe("fsid-old")
    identities.delete("fsid-1")
    const lost = await driver.clientSession(NAME, TAG, "cmux", Date.now() + 60_000, { identity: "fsid-1", vmId: "fsvm-1" })
    expect(lost.grant.identity).toBe("fsid-2")
  })

  it("deletes a half-made identity, and no error carries the answer's token", async () => {
    const refusedGrant = mock({ grantStatus: 403 })
    await expect(refusedGrant.driver.clientSession(NAME, TAG, "cmux", Date.now() + 60_000, null)).rejects.toMatchObject({ code: "cloud.provider.refused" })
    expect(refusedGrant.identities.size).toBe(0)
    const refusedToken = mock({ tokenStatus: 500 })
    const e = await refusedToken.driver.clientSession(NAME, TAG, "cmux", Date.now() + 60_000, null).catch((x: Error) => x)
    expect(e).toBeInstanceOf(Error)
    expect(String((e as Error).message)).not.toContain(SECRET)
    expect(refusedToken.identities.size).toBe(0)
    // A half-made identity whose delete fails goes back to the caller to retire.
    const stuck = mock({ tokenStatus: 500, deleteStatus: 503 })
    const left = await stuck.driver.clientSession(NAME, TAG, "cmux", Date.now() + 60_000, null).catch((x: Error) => x)
    expect(left).toBeInstanceOf(ClientIdentityLeft)
    expect(left).toMatchObject({ identity: "fsid-1", code: "cloud.provider.unavailable" })
    expect(String((left as Error).message)).not.toContain(SECRET)
  })

  it("refuses a token whose expiry is not the one asked for, and never drops an identity it cannot delete", async () => {
    for (const expiry of [() => null, () => undefined, (a: string) => new Date(Date.parse(a) + 3_600_000).toISOString(), () => "soon"]) {
      const fresh = mock({ expiry })
      await expect(fresh.driver.clientSession(NAME, TAG, "cmux", Date.now() + 60_000, null)).rejects.toMatchObject({ code: "cloud.provider.unavailable" })
      expect(fresh.identities.size).toBe(0)
    }
    // A reused identity that got a bad token goes back to the caller to retire.
    const ok = mock()
    const first = await ok.driver.clientSession(NAME, TAG, "cmux", Date.now() + 60_000, null)
    const bad = mock({ expiry: () => null })
    bad.identities.add(first.grant.identity)
    const left = await bad.driver.clientSession(NAME, TAG, "cmux", Date.now() + 60_000, { identity: first.grant.identity, vmId: "fsvm-1" }).catch((x: Error) => x)
    expect(left).toBeInstanceOf(ClientIdentityLeft)
    expect(left).toMatchObject({ identity: first.grant.identity })
    const noDelete = new GuardedCloudDriver({ capabilities: { clientSession: true } } as never, PREFIX)
    await expect(noDelete.dropClientIdentity("fsid-x")).rejects.toMatchObject({ code: "cloud.provider.unsupported" })
  })

  it("refuses another environment's name or another team's VM before any identity call", async () => {
    const { calls, driver } = mock()
    await expect(driver.clientSession(`cmuxnp-dev-cld-vm-${"a".repeat(20)}`, TAG, "cmux", Date.now(), null)).rejects.toMatchObject({ code: "cloud.provider.refused" })
    await expect(driver.clientSession(NAME, { ...TAG, team: `team_${"o".repeat(20)}` }, "cmux", Date.now(), null)).rejects.toMatchObject({ code: "cloud.provider.name_conflict" })
    expect(calls.some((c) => c.path.startsWith("/v5/identities"))).toBe(false)
  })
})

describe("retired identities", () => {
  it("a replaced or gone machine's identity is retired and stays until the provider confirms its delete", async () => {
    const ns = (env as unknown as { CLOUD_DO: DurableObjectNamespace }).CLOUD_DO
    await inDO(ns.get(ns.idFromName(`client-identity-${crypto.randomUUID()}`)), async (_i, state) => {
      const store = new ClientIdentityStore({ exec: <T>(q: string, ...p: Array<unknown>) => state.storage.sql.exec(q, ...p).toArray() as Array<T>, transaction: <T>(fn: () => T) => state.storage.transactionSync(fn) })
      store.put("vm_live", "cmux", "fsid-a", "fsvm-1", 1)
      store.put("vm_live", "cmux", "fsid-b", "fsvm-2", 2)
      store.put("vm_gone", "cmux", "fsid-c", "fsvm-3", 3)
      expect(store.get("vm_live", "cmux")).toEqual({ identity: "fsid-b", vmId: "fsvm-2" })
      let fail = true
      const dropped: Array<string> = []
      const driver = { dropClientIdentity: async (id: string) => (fail ? Promise.reject(new Error("503")) : void dropped.push(id)) } as unknown as GuardedCloudDriver
      const machine = (id: string) => (id === "vm_live" ? ({ status: "running" } as never) : undefined)
      expect(await sweepClientIdentities(store, machine, driver, 4)).toBe(true)
      expect(store.retired(10).sort()).toEqual(["fsid-a", "fsid-c"])
      expect(store.get("vm_gone", "cmux")).toBeNull()
      fail = false
      expect(await sweepClientIdentities(store, machine, driver, 5)).toBe(false)
      expect(dropped.sort()).toEqual(["fsid-a", "fsid-c"])
      expect(store.retired(10)).toEqual([])
      expect(store.get("vm_live", "cmux")).toEqual({ identity: "fsid-b", vmId: "fsvm-2" })

      // A departed member's identities go now, even behind a full queue of older retired ones.
      // That includes an older identity of theirs still waiting in the queue, behind the limit.
      for (let i = 0; i < 12; i++) store.retire(`fsid-old-${i}`, 10 + i, null)
      store.retire("fsid-gone-old", 25, "user_gone")
      store.put("vm_live", "user_gone", "fsid-gone", "fsvm-2", 30)
      dropped.length = 0
      const theirs = store.forgetUser("user_gone", 31)
      expect(theirs.sort()).toEqual(["fsid-gone", "fsid-gone-old"])
      expect(await sweepClientIdentities(store, machine, driver, 32, 10, theirs)).toBe(true)
      expect(dropped).toEqual(expect.arrayContaining(["fsid-gone", "fsid-gone-old"]))
      expect(store.retired(20)).not.toContain("fsid-gone")
      expect(store.retired(20)).not.toContain("fsid-gone-old")
    })
  })

  it("a mint keeps an identity the provider could not delete, and a member who left during the mint gets nothing", async () => {
    const ns = (env as unknown as { CLOUD_DO: DurableObjectNamespace }).CLOUD_DO
    await inDO(ns.get(ns.idFromName(`client-identity-${crypto.randomUUID()}`)), async (_i, state) => {
      const store = new ClientIdentityStore({ exec: <T>(q: string, ...p: Array<unknown>) => state.storage.sql.exec(q, ...p).toArray() as Array<T>, transaction: <T>(fn: () => T) => state.storage.transactionSync(fn) })
      const team = `team_${"t".repeat(20)}`
      const machine = `vm_${"m".repeat(20)}`
      const p = { identity: "session:user_a", kind: "session", user: "user_a", team } as Principal
      const row = { id: machine, creator: "user_a", status: "running", provider_name: "cmuxnp-test-cld-vm-x" }
      let mint: () => Promise<unknown> = async () => Promise.reject(new ClientIdentityLeft("fsid-left", new DriverError("cloud.provider.unavailable", "mint client token: 503", false)))
      const dropped: Array<string> = []
      let dropFails = true
      const driver = {
        capabilities: { clientSession: true },
        clientSession: () => mint(),
        dropClientIdentity: async (id: string) => (dropFails ? Promise.reject(new Error("503")) : void dropped.push(id))
      } as unknown as GuardedCloudDriver
      let members = [true, true]
      const sinces: Array<number> = []
      let retries = 0
      const host: ClientSessionHost = {
        team,
        machine: (id) => (id === machine ? (row as never) : undefined),
        member: async (_user, since) => (sinces.push(since), members.shift() ?? false),
        plan: async () => true,
        limit: async () => true,
        driver: async () => driver,
        identities: store,
        audit: () => undefined,
        now: () => 1000,
        retryLater: () => void retries++,
        inflight: new Map()
      }
      expect(await mintClientSessionOn(host, p, machine, 600)).toEqual({ ok: false, refusal: "provider_failed" })
      expect(store.retired(10)).toEqual(["fsid-left"])
      expect(retries).toBe(1)
      // Once the provider can delete again, the next failed mint deletes it right away, not at the alarm.
      dropFails = false
      expect(await mintClientSessionOn(host, p, machine, 600)).toEqual({ ok: false, refusal: "provider_failed" })
      expect(store.retired(10)).toEqual([])
      expect(dropped).toEqual(["fsid-left"])
      dropped.length = 0

      // The member check passes before the provider call and fails after it: no token, and the new identity goes.
      members = [true, false]
      mint = async () => ({ grant: { identity: "fsid-new", token: "tok-secret", expiresAt: 601_000, vmId: "fsvm-1", linuxUser: "cmux", apiBaseUrl: "https://freestyle.test", ssh: null }, stale: null })
      expect(await mintClientSessionOn(host, p, machine, 600)).toEqual({ ok: false, refusal: "forbidden" })
      expect(store.get(machine, "user_a")).toBeNull()
      expect(dropped).toEqual(["fsid-new"])
      expect(store.retired(10)).toEqual([])
      // Behind a full queue of older retired identities, a departed member's identities still go now.
      for (let i = 0; i < 12; i++) store.retire(`fsid-queued-${i}`, i, null)
      dropped.length = 0
      members = [true, false]
      mint = async () => ({ grant: { identity: "fsid-new2", token: "tok-secret2", expiresAt: 601_000, vmId: "fsvm-1", linuxUser: "cmux", apiBaseUrl: "https://freestyle.test", ssh: null }, stale: null })
      expect(await mintClientSessionOn(host, p, machine, 600)).toEqual({ ok: false, refusal: "forbidden" })
      expect(dropped).toContain("fsid-new2")
      expect(store.retired(20)).not.toContain("fsid-new2")
      for (let i = 0; i < 12; i++) store.dropped(`fsid-queued-${i}`)
      dropped.length = 0

      // Both checks ask about departures since the same instant, taken before the provider call.
      expect(sinces.slice(-2)).toEqual([sinces.at(-2), sinces.at(-2)])

      // A grant that would expire within seconds of the answer is refused.
      members = [true, true]
      mint = async () => ({ grant: { identity: "fsid-late", token: "tok-late", expiresAt: 11_000, vmId: "fsvm-1", linuxUser: "cmux", apiBaseUrl: "https://freestyle.test", ssh: null }, stale: null })
      expect(await mintClientSessionOn(host, p, machine, 600)).toEqual({ ok: false, refusal: "provider_failed" })
    })
  })
})

describe("ttl", () => {
  it("defaults to 10 minutes and accepts only whole seconds from 60 to 900", () => {
    expect(clientSessionTtl(null)).toBe(600)
    expect(clientSessionTtl({})).toBe(600)
    expect(clientSessionTtl({ ttl_seconds: 60 })).toBe(60)
    expect(clientSessionTtl({ ttl_seconds: 900 })).toBe(900)
    for (const bad of [{ ttl_seconds: 59 }, { ttl_seconds: 901 }, { ttl_seconds: 120.5 }, { ttl_seconds: "600" }, { ttl: 600 }, [600], "600"]) expect(clientSessionTtl(bad), JSON.stringify(bad)).toBeNull()
  })
})

describe("CloudDO client sessions", { timeout: 60_000 }, () => {
  it("mints for the machine's creator only, scoped to its VM and the work user, and logs no token", async () => {
    const alice = person()
    const { machine } = await createdAndBound(alice)
    const stub = stubOf(alice.team)
    const before = Date.now()
    const { result: r, lines } = await consoleDuring(() => stub.mintClientSession(alice.team, alice.p, machine, 600))
    expect(r.ok, JSON.stringify(r)).toBe(true)
    const v = r.value
    const vm = (await stub.fakeControl({})).vms.find((x: { id: string }) => x.id === v.vm_id)
    expect(vm).toBeDefined()
    expect(v).toMatchObject({ machine, linux_user: CLIENT_SESSION_LINUX_USER, ssh: { user: `${v.vm_id}+cmux` } })
    expect(v.expires_at).toBeGreaterThanOrEqual(before + 600_000)
    expect(v.expires_at).toBeLessThanOrEqual(Date.now() + 600_000)
    expect(await identities(alice.team)).toEqual([expect.objectContaining({ vm: v.vm_id, user: "cmux", tokens: 1 })])

    // A second session reuses the identity; the token is fresh.
    const again = await stub.mintClientSession(alice.team, alice.p, machine, 60)
    expect(again.value.token).not.toBe(v.token)
    expect(again.value.expires_at).toBeLessThanOrEqual(Date.now() + 60_000)
    expect(await identities(alice.team)).toEqual([expect.objectContaining({ vm: v.vm_id, tokens: 2 })])

    // No token in the audit or any log line.
    const audit = JSON.stringify((await stub.fakeControl({})).audit)
    expect(audit).toContain("client_session")
    for (const t of [v.token, again.value.token]) {
      expect(audit).not.toContain(t)
      expect(lines).not.toContain(t)
    }

    // Deleting the machine deletes its client session identity at the provider.
    const del = await alice.stub.submit(alice.team, alice.p, { t: "op", op: "cloud.machine.delete", params: { machine }, idempotency_key: crypto.randomUUID(), origin: "user" })
    expect(del.frames.some((f) => f.t === "result"), JSON.stringify(del.frames)).toBe(true)
    expect(await identities(alice.team)).toEqual([])
  })

  it("refuses another person, another team, agents and machine installs, a bad ttl, and a team without a plan", async () => {
    const alice = person()
    const { machine } = await createdAndBound(alice)
    const stub = stubOf(alice.team)
    const bob = person()
    // Bob in Alice's team object (not the creator), and Bob asking his own team for Alice's machine.
    expect(await stub.mintClientSession(alice.team, { ...bob.p, team: alice.team }, machine, 600)).toEqual({ ok: false, refusal: "not_creator" })
    expect(await stubOf(bob.team).mintClientSession(bob.team, bob.p, machine, 600)).toEqual({ ok: false, refusal: "not_found" })
    expect(await stub.mintClientSession(alice.team, bob.p, machine, 600)).toEqual({ ok: false, refusal: "forbidden" })
    expect(await stub.mintClientSession(alice.team, { ...alice.p, agent: "agent_chief01" }, machine, 600)).toEqual({ ok: false, refusal: "forbidden" })
    expect(await stub.mintClientSession(alice.team, installOf(alice.p, ["read", "execute"], "vm"), machine, 600)).toEqual({ ok: false, refusal: "forbidden" })
    expect(await stub.mintClientSession(alice.team, installOf(alice.p, ["read"], "cli"), machine, 600)).toEqual({ ok: false, refusal: "forbidden" })
    expect((await stub.mintClientSession(alice.team, installOf(alice.p, ["read", "execute"], "cli"), machine, 600)).ok).toBe(true)
    for (const ttl of [59, 901]) expect(await stub.mintClientSession(alice.team, alice.p, machine, ttl)).toEqual({ ok: false, refusal: "bad_request" })
    expect(await stub.mintClientSession(alice.team, alice.p, `vm_${"z".repeat(20)}`, 600)).toEqual({ ok: false, refusal: "not_found" })
    await stub.fakeControl({ unset: ["CLOUD_ALLOWED_TEAMS"] })
    expect(await stub.mintClientSession(alice.team, alice.p, machine, 600)).toEqual({ ok: false, refusal: "plan_required" })
    expect(await identities(alice.team)).toHaveLength(1)
  })

  it("a member leaving the team deletes their client session identities at the provider", async () => {
    const alice = person()
    const { machine } = await createdAndBound(alice)
    const stub = stubOf(alice.team) as Stub & { systemDeliver(e: string, source: string, items: unknown): Promise<{ done: Array<number> }> }
    expect((await stub.mintClientSession(alice.team, alice.p, machine, 600)).ok).toBe(true)
    expect(await identities(alice.team)).toHaveLength(1)
    // Only the team's own TeamDO may say so.
    await stub.systemDeliver(alice.team, "team:team_other0000000000000", [{ id: 1, op: TEAM_MEMBER_LEFT_SOCKETS, key: "k1", params: { user: alice.user } }])
    expect(await identities(alice.team)).toHaveLength(1)
    const done = await stub.systemDeliver(alice.team, `team:${alice.team}`, [{ id: 2, op: TEAM_MEMBER_LEFT_SOCKETS, key: "k2", params: { user: alice.user } }])
    expect(done.done).toEqual([2])
    expect(await identities(alice.team)).toEqual([])
  })

  it("refuses a machine that is not running yet", async () => {
    const alice = person()
    const created = await alice.stub.submit(alice.team, alice.p, { t: "op", op: "cloud.machine.create", params: { size: { cpu: 2, memory_mb: 4096, disk_mb: 16384 } }, idempotency_key: crypto.randomUUID(), origin: "user" })
    const machine = (created.frames.find((f) => f.t === "result") as { value: { machine: { id: string } } }).value.machine.id
    expect(await stubOf(alice.team).mintClientSession(alice.team, alice.p, machine, 600)).toEqual({ ok: false, refusal: "not_running" })
  })
})

describe("POST /v1/cloud/machines/{machine}/client-session", { timeout: 60_000 }, () => {
  it("answers the creator's session with a no-store token, and refuses no auth, a query and a bad ttl", async () => {
    const t = await sessionToken("cloud-client-1")
    const ensured = await post("/v1/ops", t, { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "user" })
    const team = ensured.body.value.personal_team as string
    const user = ensured.body.value.id as string
    const created = await post("/v1/ops", t, { op: "cloud.machine.create", params: { size: { cpu: 2, memory_mb: 4096, disk_mb: 16384 } }, idempotency_key: crypto.randomUUID(), origin: "user" })
    const machine = created.body.value.machine.id as string
    const file = await bindFile(cloudStub(team), machine)
    const { body } = await bindBody({ user, team }, machine, file.json.bind_token)
    expect((await cloudStub(team).bindMachine(team, body)).ok).toBe(true)

    const path = `/v1/cloud/machines/${machine}/client-session`
    const res = await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { authorization: `Bearer ${t}`, "content-type": "application/json" }, body: JSON.stringify({ ttl_seconds: 120 }) })
    expect(res.status).toBe(200)
    expect(res.headers.get("cache-control")).toBe("no-store")
    const ok = (await res.json()) as { ok: boolean; value: { machine: string; token: string; linux_user: string; expires_at: number } }
    expect(ok.value).toMatchObject({ machine, linux_user: "cmux" })
    expect(ok.value.token.length).toBeGreaterThan(0)
    expect(ok.value.expires_at).toBeLessThanOrEqual(Date.now() + 120_000)

    expect((await post(path, undefined, {})).status).toBe(401)
    expect((await post(`${path}?ttl_seconds=60`, t, {})).status).toBe(400)
    expect((await post(path, t, { ttl_seconds: 5 })).body.error.code).toBe("validation.invalid")
    // An empty body takes the default ttl.
    const empty = await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { authorization: `Bearer ${t}` } })
    expect(empty.status).toBe(200)
    expect((await post(`/v1/cloud/machines/vm_${"q".repeat(20)}/client-session`, t, {})).body.error.code).toBe("cloud.machine.not_found")
    // A chunked body with no content-length is read only up to its cap.
    const chunks = new ReadableStream<Uint8Array>({
      start(c) {
        for (let i = 0; i < 8; i++) c.enqueue(new TextEncoder().encode(" ".repeat(100)))
        c.close()
      }
    })
    const chunked = await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { authorization: `Bearer ${t}` }, body: chunks })
    expect(chunked.status).toBe(400)
  })
})
