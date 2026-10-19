import { afterEach, expect, it, vi } from "vitest"
import { call, inDO, testEnv } from "./pairing-harness.ts"
import { deliver } from "./team-stack-support.ts"
import { MESH, OTHER_MESH, NATIVE, SERVICE_KEY, mesh, targetFixture } from "./cloud-vm-api-network-target-support.ts"

afterEach(() => vi.restoreAllMocks())

it("discovers the sole tenant mesh without VM image configuration or owner writes", async () => {
  const f = await targetFixture(), before = await f.owner.debug(f.team.team)
  const reply = await f.read()
  expect(reply.status).toBe(200)
  expect(reply.json.value).toEqual(f.expected)
  expect(f.requests.map((r) => r.url)).toEqual([`${NATIVE}/v1/meshes`])
  const after = await f.owner.debug(f.team.team)
  expect(after.seq).toBe(before.seq)
  expect(after.ledger).toEqual(before.ledger)
})

it("resolves an explicit mesh through the authenticated tenant instead of guessing", async () => {
  const f = await targetFixture()
  f.respond(mesh())
  const reply = await f.read({ mesh: MESH })
  expect(reply.status).toBe(200)
  expect(reply.json.value).toEqual(f.expected)
  expect(f.requests.map((r) => r.url)).toEqual([`${NATIVE}/v1/meshes/${MESH}`])
})

it("reports an absent mesh without silently creating a network", async () => {
  const f = await targetFixture()
  f.respond({ items: [] })
  const reply = await f.read()
  expect(reply.json.error?.code ?? reply.json.code).toBe("selector.not_found")
  expect(f.requests).toHaveLength(1)
})

const code = (reply: { json: any }) => reply.json.error?.code ?? reply.json.code

it("requires explicit selection when a tenant has multiple meshes", async () => {
  const f = await targetFixture()
  f.respond({ items: [mesh(), mesh(OTHER_MESH)] })
  expect(code(await f.read())).toBe("validation.invalid")
  expect(f.requests).toHaveLength(1)
})

it("uses only configured routing and projects only the public target metadata", async () => {
  const f = await targetFixture()
  f.respond({ items: [{ ...mesh(), privateKey: "must-not-escape", providerId: "private-provider", credential: SERVICE_KEY }] })
  const reply = await f.read({ origin: "https://attacker.test", tenant: "other-team" })
  expect(reply.json.value).toEqual(f.expected)
  for (const secret of [SERVICE_KEY, "must-not-escape", "private-provider"]) expect(JSON.stringify(reply.json)).not.toContain(secret)
  expect(f.requests[0].url).toBe(`${NATIVE}/v1/meshes`)
})

it.each([302, 403, 503])("refuses Native status %s without returning its error or following redirects", async (status) => {
  const f = await targetFixture()
  f.rawResponse(() => new Response(SERVICE_KEY, { status, headers: { location: "https://attacker.test" } }))
  const reply = await f.read()
  expect(code(reply)).toBe("owner.unreachable")
  expect(JSON.stringify(reply.json)).not.toContain(SERVICE_KEY)
  expect(f.requests).toHaveLength(1)
})

it("treats an explicit mesh outside the tenant as not found", async () => {
  const f = await targetFixture()
  f.respond({ error: SERVICE_KEY }, 404)
  const reply = await f.read({ mesh: OTHER_MESH })
  expect(code(reply)).toBe("selector.not_found")
  expect(JSON.stringify(reply.json)).not.toContain(SERVICE_KEY)
})

it.each([
  { items: [{ ...mesh(), id: "not-a-mesh" }] },
  { items: [{ ...mesh(), ipv4Cidr: "0.0.0.0/0" }] },
  { items: [{ ...mesh(), ipv4Cidr: "10.0128.0.0/20" }] },
  { items: [{ ...mesh(), ipv4Cidr: "10.128.1.0/20" }] },
  { items: [{ ...mesh(), ipv4Cidr: "10.127.0.0/20" }] },
  { items: null }
])("rejects malformed or unsafe network metadata %#", async (body) => {
  const f = await targetFixture()
  f.respond(body)
  expect(code(await f.read())).toBe("owner.unreachable")
})

it("refuses an explicit lookup that returns a different mesh", async () => {
  const f = await targetFixture()
  f.respond(mesh(OTHER_MESH))
  expect(code(await f.read({ mesh: MESH }))).toBe("owner.unreachable")
})

it("bounds streamed bodies and cancels an oversized response", async () => {
  const f = await targetFixture()
  let cancelled = false
  f.rawResponse(() => new Response(new ReadableStream({
    start(controller) { controller.enqueue(new Uint8Array(1_048_577)) },
    cancel() { cancelled = true }
  })))
  expect(code(await f.read())).toBe("owner.unreachable")
  expect(cancelled).toBe(true)
})

it.each(["session", "agent", "daemon", "grant", "read-grant"])("refuses a %s principal before Native I/O", async (kind) => {
  const f = await targetFixture()
  if (kind === "session") expect(code(await f.read({}, f.team.creator.token))).toBe("auth.forbidden")
  else {
    const p = { ...f.principal,
      ...(kind === "agent" ? { agent: "agent_unapproved" } : {}),
      ...(kind === "daemon" ? { install_kind: "daemon" } : {}),
      ...(kind === "grant" ? { grant: "grant_wrong" } : {}),
      ...(kind === "read-grant" ? { grant_classes: ["mutate-own"] } : {}) }
    expect((await f.owner.readOp(f.team.team, p, "host.network.target", {})).code).toBe("auth.forbidden")
  }
  expect(f.requests).toHaveLength(0)
})

it("refuses team header retargeting and malformed mesh selectors before Native I/O", async () => {
  const f = await targetFixture()
  expect(code(await f.read({}, f.token, "team_" + "b".repeat(20)))).toBe("auth.forbidden")
  expect(code(await f.read({ mesh: "../other" }))).toBe("validation.invalid")
  expect(f.requests).toHaveLength(0)
})

it.each(["membership", "install", "team", "config"])("rechecks %s changes after Native I/O", async (kind) => {
  const f = await targetFixture()
  f.onRead(async () => {
    if (kind === "membership") {
      f.team.w.perms.set(`${f.team.stackTeam}:${f.team.creator.stackUser}`, ["cmux:guest"])
      expect((await deliver("team_permission.created", { id: "cmux:guest", team_id: f.team.stackTeam, user_id: f.team.creator.stackUser })).status).toBe(200)
    } else if (kind === "install") {
      const removed = await call("/v1/ops", f.team.creator.token, { op: "install.revoke", params: { install: f.install }, idempotency_key: crypto.randomUUID(), origin: "cli" })
      expect(removed.json.ok).toBe(true)
    } else if (kind === "team") {
      f.team.w.teams.delete(f.team.stackTeam)
      expect((await deliver("team.deleted", { id: f.team.stackTeam })).status).toBe(200)
    } else await inDO(f.owner, async (instance) => { instance.env.CLOUD_VM_API_ORIGIN = "https://changed.test" })
  })
  expect(code(await f.read())).toBe("auth.forbidden")
})

it.each(["http://vm.test", "https://vm.test/path", "https://user@vm.test", "https://vm.test?query"])("refuses unsafe configured origin %s", async (origin) => {
  const f = await targetFixture()
  await inDO(f.owner, async (instance) => { instance.env.CLOUD_VM_API_ORIGIN = origin })
  expect(code(await f.read())).toBe("owner.unreachable")
  expect(f.requests).toHaveLength(0)
})

it("reads an existing personal tenant but does not provision one during discovery", async () => {
  const f = await targetFixture(), personal = await f.personalToken()
  const owner = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(personal.team)) as any
  let creates = 0
  let found: Array<{ id: string; marker: unknown }> = []
  await inDO(owner, async (instance) => {
    instance.env = { ...instance.env, CLOUD_VM_API_ORIGIN: NATIVE, CLOUD_VM_API_SERVICE_KEY: SERVICE_KEY }
    instance.personalStack = {
      find: async () => found,
      members: async () => [f.team.creator.stackUser],
      create: async (marker: unknown) => { creates++; const value = { id: f.team.stackTeam, marker }; found = [value]; return value }
    }
  })
  expect(code(await f.read({}, personal.token, personal.team))).toBe("auth.forbidden")
  expect(creates).toBe(0)
  expect(f.requests).toHaveLength(0)
  // Establish the existing routing intent through its provisioning owner, outside the read under test.
  expect(await owner.ensureVmApiTenant(personal.team)).toMatchObject({ status: "ready" })
  f.nativeTenant(f.team.stackTeam)
  const before = await owner.debug(personal.team)
  const reply = await f.read({}, personal.token, personal.team)
  expect(reply.json.value).toEqual({ ...f.expected, team: personal.team })
  expect(creates).toBe(1)
  const after = await owner.debug(personal.team)
  expect(after.seq).toBe(before.seq)
  expect(after.ledger).toEqual(before.ledger)
})
