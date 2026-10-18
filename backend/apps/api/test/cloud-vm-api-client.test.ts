import { describe, expect, it } from "vitest"
import { VmApiCloudDriver } from "../src/cloud-vm-api.ts"
import { GuardedCloudDriver } from "../src/cloud-driver.ts"

const ID = `vm_${"0".repeat(26)}`, SNAPSHOT = `snap_${"1".repeat(26)}`
const team = `team_${"a".repeat(20)}`, machine = `vm_${"b".repeat(20)}`
const name = "cmuxnp-test-cld-vm-bbbbbbbbbbbbbbbbbbbb", slug = "cmuxnp-test-cld-snap-cccccccccccccccccccc"
const settings = { origin: "https://vm.test", key: "test-secret-never-in-errors", image: { id: "cloud-agent", revision: "v1" } }
const labels = (n = name) => ({ role: "cloud", cmux_next_team: team, cmux_next_machine: machine, "cmux/name": n })
const vm = () => ({ id: ID, displayName: name, labels: labels(), state: "running", resources: { vcpus: 2, memoryMib: 4096, diskMib: 16384 }, idleTimeoutSeconds: -1, maxRunSeconds: null, autoDeleteSeconds: null, createdAt: "2026-10-18T00:00:00Z", updatedAt: "2026-10-18T00:00:00Z" })
const snapshot = () => ({ id: SNAPSHOT, displayName: slug, labels: labels(slug), sourceVmId: ID, createdAt: "2026-10-18T00:00:00Z", lastUsedAt: null, ttlSeconds: null, autoDeleteSeconds: null })
const json = (body: unknown, status = 200) => Response.json(body, { status })
const fake = (handler: (request: Request) => Response | Promise<Response>) => {
  const calls: Request[] = []
  const fetchFn: typeof fetch = async (input, init) => {
    const request = new Request(input, init)
    calls.push(request.clone())
    expect(request.headers.get("authorization")).toBe(`Bearer ${settings.key}`)
    expect(request.headers.get("x-cmux-team-id")).toBe("stack-team-123")
    expect(request.redirect).toBe("manual")
    return handler(request)
  }
  const raw = new VmApiCloudDriver(settings, "stack-team-123", team, fetchFn)
  return { raw, calls, guarded: new GuardedCloudDriver(raw, "cmuxnp-test-cld-") }
}

describe("generated VM API Cloud transport", () => {
  it("creates with an exact image, explicit network receipt and stable retry key; recovers a lost answer by creator", async () => {
    let exists = false
    const x = fake(async (request) => {
      if (request.method === "GET") {
        const url = new URL(request.url)
        expect(url.searchParams.get("createdBy")).toBe("caller")
        expect(url.searchParams.getAll("label")).toContain(`cmux/name=${name}`)
        return json({ items: exists ? [vm()] : [], nextCursor: null })
      }
      expect(await request.json()).toEqual({ displayName: name, labels: labels(), idleTimeoutSeconds: -1, image: settings.image, initialNetwork: { publicEgress: true, httpsProxies: [] } })
      expect(request.headers.get("idempotency-key")).toBe(`cloud-create:${name}`)
      exists = true
      return json({ ...vm(), bootImage: { ...settings.image, displayName: "Cloud agent" }, initialNetwork: { publicEgress: true, httpsProxyHosts: [] } }, 201)
    })
    expect(await x.guarded.ensure(name, { team, machine }, { idleSeconds: 0 })).toMatchObject({ id: ID })
    expect(await x.guarded.ensure(name, { team, machine }, { idleSeconds: 0 })).toMatchObject({ id: ID })
    expect(x.calls.filter((r) => r.method === "POST")).toHaveLength(1)
  })

  it("never adopts an ambiguous, mismatched or incorrectly filtered discovery answer", async () => {
    for (const items of [[vm(), vm()], [{ ...vm(), labels: { ...labels(), cmux_next_team: "other" } }], [{ ...vm(), labels: { ...labels(), "cmux/name": "other" } }]]) {
      const x = fake(() => json({ items, nextCursor: null }))
      await expect(x.guarded.remove(name, { team, machine })).rejects.toThrow("VM API:")
      expect(x.calls.every((r) => r.method === "GET")).toBe(true)
    }
  })

  it("follows creator-constrained keyset pages and rejects repeated cursors", async () => {
    const x = fake((request) => {
      const u = new URL(request.url)
      expect(u.searchParams.get("createdBy")).toBe("caller")
      return json(u.searchParams.has("cursor") ? { items: [vm()], nextCursor: null } : { items: [], nextCursor: "next" })
    })
    expect(await x.raw.find(name)).toMatchObject({ id: ID })
    const stuck = fake(() => json({ items: [], nextCursor: "repeated" }))
    await expect(stuck.raw.find(name)).rejects.toThrow("invalid VM cursor")
    expect(stuck.calls).toHaveLength(2)
  })

  it("refuses unconfirmed creation receipts without deleting the possibly created machine", async () => {
    for (const response of [vm(), { ...vm(), initialNetwork: { publicEgress: false, httpsProxyHosts: [] } }, { ...vm(), initialNetwork: { publicEgress: true, httpsProxyHosts: [] }, bootImage: { ...settings.image, revision: "other" } }]) {
      const x = fake(() => json(response, 201))
      await expect(x.raw.create(name, { team, machine }, { idleSeconds: 0 })).rejects.toThrow("unconfirmed create")
      expect(x.calls).toHaveLength(1)
    }
  })

  it("maps power, state, resources and confirmed growth to public VM operations", async () => {
    const x = fake(async (r) => {
      if (r.url.endsWith("/resize")) {
        expect(await r.json()).toEqual({ resources: { vcpus: 4, memoryMib: 8192, diskMib: 32768 } })
        expect(r.headers.get("idempotency-key")).toMatch(/^cloud-resize:[a-f0-9]{64}$/)
        return json({ ...vm(), resources: { vcpus: 4, memoryMib: 8192, diskMib: 32768 } })
      }
      return json(vm())
    })
    await x.raw.pause(ID); await x.raw.start(ID)
    expect(await x.raw.state(ID)).toBe("running")
    expect(await x.raw.resources(ID)).toEqual({ cpu: 2, memory: 4096, storage: 16384 })
    await x.raw.resize(ID, { cpu: 4, memory: 8192, storage: 32768 })
    expect(x.calls.map((r) => new URL(r.url).pathname)).toContain(`/v1/vms/${ID}/start`)
    const short = fake(() => json(vm()))
    await expect(short.raw.resize(ID, { cpu: 4, memory: 8192, storage: 32768 })).rejects.toThrow("unconfirmed growth")
  })

  it("finds, creates, restores and deletes only public snapshots in the caller's discovery namespace", async () => {
    const x = fake(async (r) => {
      const url = new URL(r.url)
      if (r.method === "DELETE") return new Response(null, { status: 204 })
      if (url.pathname === "/v1/snapshots") {
        expect(url.searchParams.get("createdBy")).toBe("caller")
        expect(url.searchParams.get("labels")).toContain(`cmux/name=${slug}`)
        return json({ items: [snapshot()], nextCursor: null })
      }
      if (url.pathname.endsWith("/snapshots")) {
        expect(await r.json()).toEqual({ displayName: slug, labels: labels(slug) })
        return json(snapshot(), 201)
      }
      if (r.method === "POST") {
        expect(await r.json()).toMatchObject({ snapshotId: SNAPSHOT })
        return json({ ...vm(), initialNetwork: { publicEgress: true, httpsProxyHosts: [] } }, 201)
      }
      return json(vm())
    })
    expect(await x.raw.findSnapshot(slug)).toEqual({ id: SNAPSHOT, sourceVmId: ID })
    expect(await x.raw.createSnapshot(ID, slug)).toEqual({ id: SNAPSHOT })
    expect(await x.raw.create(name, { team, machine }, { idleSeconds: 0, snapshot: slug })).toMatchObject({ id: ID })
    await x.raw.deleteSnapshot(SNAPSHOT); await x.raw.delete(ID)
  })

  it("writes UTF-8 bytes and root exec stdin without putting content in query strings", async () => {
    const x = fake(async (r) => {
      if (r.method === "PUT") {
        expect(new URL(r.url).searchParams.get("mode")).toBe("384")
        expect(r.headers.get("content-type")).toBe("application/octet-stream")
        expect(r.headers.get("content-length")).toBe("9")
        expect(await r.text()).toBe("test 🔑")
        return new Response(null, { status: 204 })
      }
      expect(await r.json()).toEqual({ command: "test command", linuxUser: "root", timeoutMs: 1234, stdinBase64: "dGVzdA==" })
      return json({ exitCode: null, stdout: "", stderr: "timeout" })
    })
    await x.raw.writeFile(ID, "/etc/cmux/test.json", "test 🔑", 0o600)
    expect(await x.raw.execStdin(ID, "test command", new TextEncoder().encode("test"), 1234)).toEqual({ exitCode: 124, stdout: "", stderr: "timeout" })
    expect(x.calls.every((r) => !r.url.includes("command") && !r.url.includes("🔑"))).toBe(true)
  })

  it("replaces a proxy only after validating the receipt and keeps credentials in request bodies", async () => {
    const rule = { action: "allow" as const, domain: "coderouter.cmux.internal", source: {}, destination: { host: "edge.test", port: 443 }, transform: [{ headers: { authorization: "test-edge-secret" } }] }
    const x = fake(async (r) => {
      expect(await r.json()).toEqual({ destination: "https://edge.test", headers: { authorization: "test-edge-secret" } })
      expect(r.url).not.toContain("secret")
      return json({ id: ID, hostname: rule.domain })
    })
    expect(await x.raw.replaceTlsRule(ID, rule)).toBe(true)
    const missing = fake(() => new Response(null, { status: 404 }))
    expect(await missing.raw.replaceTlsRule(ID, rule)).toBe(false)
  })

  it("never follows redirects or includes upstream bodies and credentials in errors", async () => {
    for (const status of [302, 403, 429, 503]) {
      const x = fake(() => json({ message: settings.key, stdin: "test-person-key" }, status))
      const error = await x.raw.find(name).catch((e: unknown) => e)
      expect(String(error)).toContain(`HTTP ${status}`)
      expect(String(error)).not.toContain(settings.key)
      expect(String(error)).not.toContain("test-person-key")
      expect(x.calls).toHaveLength(1)
    }
    const bad = fake(() => new Response("secret malformed JSON", { status: 200, headers: { "content-type": "application/json" } }))
    await expect(bad.raw.find(name)).rejects.toThrow("no readable answer")
  })
})
