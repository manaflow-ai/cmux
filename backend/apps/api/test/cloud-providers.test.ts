import { env } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import type { SqlStore } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { GuardedCloudDriver } from "../src/cloud-driver.ts"
import { FakeCloudDriver } from "../src/cloud-driver-fake.ts"
import type { CloudProvider, EdgeTlsRule } from "../src/providers/contract.ts"
import { FreestyleCloudProvider } from "../src/providers/freestyle/cloud.ts"

/**
 * One contract, every provider: the same scenario runs through GuardedCloudDriver against the test fake
 * and against the Freestyle provider over a mocked transport (an in-memory v5 API). A new provider
 * (GCP next) adds one `describe` here with its own mocked transport.
 */
const PREFIX = "cmuxnp-test-cld-"
const NAME = `${PREFIX}vm-${"a".repeat(20)}`
const SLUG = `${PREFIX}snap-${"c".repeat(20)}`
const TAG = { team: `team_${"t".repeat(20)}`, machine: `vm_${"m".repeat(20)}` }
const RULE: EdgeTlsRule = { action: "allow", domain: "coderouter.cmux.internal", source: {}, destination: { host: "edge.test", port: 443 }, transform: [{ headers: { "x-test": "v" } }] }

/** What each provider's backing store holds, read outside the contract, so a no-op call cannot pass. */
interface Observe {
  file(vmId: string, path: string): { content: string; mode: number } | null
  rule(vmId: string, domain: string): EdgeTlsRule | null
}

/** Counts the provider calls, so a guard refusal can be shown to make none. */
const counted = (p: CloudProvider, override: Partial<CloudProvider> = {}) => {
  const box = { calls: 0 }
  const proxy = new Proxy(p, {
    get(target, key) {
      if (key in override) return (override as Record<PropertyKey, unknown>)[key]
      const v = Reflect.get(target, key) as unknown
      return typeof v === "function" ? (...args: Array<unknown>) => (box.calls++, (v as (...a: Array<unknown>) => unknown).apply(target, args)) : v
    }
  })
  return { provider: proxy, box }
}

const scenario = async (raw: CloudProvider, seen: Observe) => {
  const { provider, box } = counted(raw)
  const d = new GuardedCloudDriver(provider, PREFIX)
  expect(Object.keys(d.capabilities).sort()).toEqual(["clientSession", "edgeTls", "guestExec", "resize", "sizing", "snapshot"])

  // The guard refuses another environment's name before any provider call.
  await expect(d.ensure(`cmuxnp-dev-cld-vm-${"a".repeat(20)}`, TAG, { idleSeconds: 0 })).rejects.toMatchObject({ code: "cloud.provider.refused", final: true })
  expect(box.calls).toBe(0)

  // Create is idempotent by name; another team's tag under our name is a conflict, never adopted.
  const { id } = await d.ensure(NAME, TAG, { idleSeconds: 0, edgeRules: [RULE] })
  expect((await d.ensure(NAME, TAG, { idleSeconds: 0 })).id).toBe(id)
  await expect(d.ensure(NAME, { ...TAG, team: `team_${"o".repeat(20)}` }, { idleSeconds: 0 })).rejects.toMatchObject({ code: "cloud.provider.name_conflict" })
  expect(await d.stateOf(NAME, TAG)).toEqual({ state: "running", gone: false })

  // Power settles from the real state: a second pause or start is success.
  await d.power(NAME, TAG, "pause")
  expect((await d.stateOf(NAME, TAG)).state).toBe("paused")
  await d.power(NAME, TAG, "pause")
  await d.power(NAME, TAG, "start")
  await d.power(NAME, TAG, "start")
  expect((await d.stateOf(NAME, TAG)).state).toBe("running")

  if (d.capabilities.resize) {
    await d.resize(NAME, TAG, { cpu: 4, memory: 8192, storage: 16384 })
    expect(await d.resourcesOf(NAME, TAG)).toMatchObject({ cpu: 4, memory: 8192 })
  }

  await d.writeBindFile(NAME, TAG, JSON.stringify({ team: TAG.team }))
  expect(seen.file(id, "/var/lib/cmux/bind.json")).toEqual({ content: JSON.stringify({ team: TAG.team }), mode: 0o600 })
  expect(seen.rule(id, RULE.domain)?.transform).toEqual(RULE.transform)
  const fresh: EdgeTlsRule = { ...RULE, transform: [{ headers: { "x-test": "rotated" } }] }
  expect(await d.replaceEdgeRule(NAME, TAG, fresh)).toBe(d.capabilities.edgeTls)
  expect(seen.rule(id, RULE.domain)).toEqual({ ...fresh, source: { vmId: id } })
  expect(await d.listOurs(TAG.team)).toEqual([{ name: NAME, id }])

  if (d.capabilities.snapshot) {
    const snap = await d.snapshot(NAME, TAG, SLUG)
    expect((await d.snapshot(NAME, TAG, SLUG)).id).toBe(snap.id)
    expect(await raw.findSnapshot(SLUG)).toMatchObject({ id: snap.id, sourceVmId: id })
    await d.removeSnapshot(SLUG)
    expect(await raw.findSnapshot(SLUG)).toBeNull()
    await d.removeSnapshot(SLUG)
  }

  if (d.capabilities.guestExec) expect((await d.execStdin(NAME, TAG, "true", null, 5_000)).exitCode).toBe(0)
  else await expect(d.execStdin(NAME, TAG, "true", null, 5_000)).rejects.toMatchObject({ code: "cloud.provider.refused" })

  // Delete is idempotent: a name that is not there is success.
  await d.remove(NAME, TAG)
  await d.remove(NAME, TAG)
  expect(await d.stateOf(NAME, TAG)).toEqual({ state: null, gone: true })

  // A provider without `resize` is refused by the guard before any call.
  const noResize = counted(raw, { capabilities: { ...raw.capabilities, resize: false } })
  await expect(new GuardedCloudDriver(noResize.provider, PREFIX).resize(NAME, TAG, { cpu: 8, memory: 8192, storage: 16384 })).rejects.toMatchObject({ code: "cloud.provider.unsupported", final: true })
  expect(noResize.box.calls).toBe(0)
}

/** A small in-memory Freestyle v5 API: only what the Cloud provider calls. */
const mockFreestyle = () => {
  type Vm = { id: string; slug: string; metadata: Record<string, unknown>; state: string; resources: { cpu: number; memory: number; storage: number }; rules: Array<{ id: string; domain: string; rule: EdgeTlsRule }> }
  const vms = new Map<string, Vm>()
  const snaps = new Map<string, { id: string; sourceVmId: string }>()
  const files = new Map<string, { content: string; mode: number }>()
  let n = 0
  const vmBy = (x: string) => vms.get(x) ?? [...vms.values()].find((v) => v.slug === x)
  const fetchFn: typeof fetch = async (input, init) => {
    const req = new Request(input, init)
    expect(req.headers.get("authorization")).toBe("Bearer test-only-key")
    const url = new URL(req.url)
    const parts = url.pathname.split("/").slice(2).map(decodeURIComponent)
    const raw = req.method === "POST" || req.method === "PUT" ? await req.text() : ""
    const body = (() => {
      try {
        return JSON.parse(raw) as Record<string, unknown>
      } catch {
        return {}
      }
    })()
    const json = (b: unknown, status = 200) => Response.json(b, { status })
    if (parts[0] === "vms" && parts.length === 1 && req.method === "POST") {
      if (vmBy(String(body.slug))) return json({ code: "CONFLICT" }, 409)
      const id = `fsvm-${++n}`
      const rules = ((body.tls as { rules?: Array<EdgeTlsRule> } | undefined)?.rules ?? []).map((r) => ({ id: `tls-${++n}`, domain: r.domain, rule: r }))
      vms.set(id, { id, slug: String(body.slug), metadata: body.metadata as Record<string, unknown>, state: "running", resources: { cpu: 2, memory: 4096, storage: 16384 }, rules })
      return json({ id })
    }
    if (parts[0] === "vms" && parts.length === 1 && req.method === "GET") {
      const [k, v] = (url.searchParams.get("metadata") ?? ":").split(":")
      const all = [...vms.values()].filter((x) => x.metadata[k!] === v)
      return json({ vms: all.map((x) => ({ id: x.id, slug: x.slug, metadata: x.metadata })), totalCount: all.length })
    }
    if (parts[0] === "vms") {
      const vm = vmBy(parts[1]!)
      if (!vm) return json({ code: "NOT_FOUND" }, 404)
      const verb = parts[2]
      if (!verb && req.method === "GET") return json({ id: vm.id, slug: vm.slug, metadata: vm.metadata, state: vm.state, resources: vm.resources })
      if (!verb && req.method === "DELETE") return vms.delete(vm.id), json({})
      if (verb === "pause" || verb === "start") {
        const target = verb === "pause" ? "paused" : "running"
        if (vm.state === target) return json({ code: "ALREADY" }, 409)
        return (vm.state = target), json({})
      }
      if (verb === "resize") return (vm.resources = body as Vm["resources"]), json({})
      if (verb === "fs" && parts[3] === "write" && req.method === "PUT") {
        // Like the provider: the write lands only when the sha256 matches the bytes.
        const digest = [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(raw)))].map((b) => b.toString(16).padStart(2, "0")).join("")
        if (digest !== url.searchParams.get("sha256")) return json({ code: "SHA_MISMATCH" }, 400)
        files.set(`${vm.id}:${url.searchParams.get("path")}`, { content: raw, mode: Number(url.searchParams.get("mode")) })
        return json({})
      }
      if (verb === "exec-await") return json({ statusCode: 0, stdout: "", stderr: "" })
      if (verb === "snapshot") {
        const id = `fssnap-${++n}`
        snaps.set(String(body.slug), { id, sourceVmId: vm.id })
        return json({ snapshotId: id })
      }
    }
    if (parts[0] === "snapshots") {
      const byId = [...snaps.entries()].find(([, s]) => s.id === parts[1])
      if (req.method === "DELETE") return byId ? (snaps.delete(byId[0]), json({})) : json({}, 404)
      const s = snaps.get(parts[1]!)
      return s ? json(s) : json({ code: "NOT_FOUND" }, 404)
    }
    if (parts[0] === "tls" && req.method === "GET") {
      const vm = vms.get(url.searchParams.get("vmId") ?? "")
      return json({ rules: (vm?.rules ?? []).filter((r) => r.domain === url.searchParams.get("domain")) })
    }
    if (parts[0] === "tls" && req.method === "PUT") {
      const held = [...vms.values()].flatMap((v) => v.rules).find((r) => r.id === parts[1])
      if (!held) return json({ code: "NOT_FOUND" }, 404)
      held.rule = body as unknown as EdgeTlsRule
      return json({})
    }
    return json({ code: "UNMOCKED" }, 500)
  }
  const seen: Observe = {
    file: (vmId, path) => files.get(`${vmId}:${path}`) ?? null,
    rule: (vmId, domain) => vms.get(vmId)?.rules.find((r) => r.domain === domain)?.rule ?? null
  }
  return { fetchFn, seen }
}

describe("CloudProvider contract", () => {
  it("the test fake keeps the contract", async () => {
    const ns = (env as unknown as { CLOUD_DO: DurableObjectNamespace }).CLOUD_DO
    const stub = ns.get(ns.idFromName(`provider-contract-${crypto.randomUUID()}`))
    await (runInDurableObject as unknown as <T>(s: unknown, fn: (i: unknown, st: DurableObjectState) => Promise<T>) => Promise<T>)(stub, async (_i, state) => {
      const sql: SqlStore = { exec: <T>(q: string, ...p: Array<unknown>) => state.storage.sql.exec(q, ...p).toArray() as Array<T>, transaction: <T>(fn: () => T) => state.storage.transactionSync(fn) }
      const seen: Observe = {
        file: (vm, path) => sql.exec<{ content: string; mode: number }>(`SELECT content, mode FROM cloud_fake_file WHERE vm = ? AND path = ?`, vm, path).map((f) => ({ content: f.content, mode: Number(f.mode) }))[0] ?? null,
        rule: (vm, domain) => sql.exec<{ rule: string }>(`SELECT rule FROM cloud_fake_tls WHERE vm = ? AND domain = ?`, vm, domain).map((t) => JSON.parse(t.rule) as EdgeTlsRule)[0] ?? null
      }
      await scenario(new FakeCloudDriver(sql), seen)
    })
  })

  it("the Freestyle provider keeps the contract over a mocked transport", async () => {
    const { fetchFn, seen } = mockFreestyle()
    await scenario(new FreestyleCloudProvider("test-only-key", "https://freestyle.test", "cmuxnp-test-vmimg-contract", fetchFn), seen)
  })
})
