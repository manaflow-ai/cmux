import { describe, expect, it } from "vitest"
import { FreestyleCloudDriver } from "../src/cloud-driver.ts"

/**
 * Found by the first real development create (2026-10-05): the driver stored the global fetch as a
 * property and called it as a method, which workerd refuses ("Illegal invocation"), so every real
 * provider call answered "no answer UNREACHABLE" and no test saw it (tests pass their own fetch).
 * Here the driver runs with its default fetch in workerd, against a port that refuses connections:
 * the error must carry the network reason, and it must not be an illegal invocation.
 */
describe("Freestyle driver default fetch", () => {
  it("reaches the network layer with the runtime's fetch", async () => {
    const driver = new FreestyleCloudDriver("not-a-key", "http://127.0.0.1:9", "cmuxnp-test-vmimg-1")
    const err = (await driver.find("cmuxnp-test-cld-vm-00000000000000000001").catch((e: unknown) => e)) as Error
    expect(err.message).toMatch(/^read VM: no answer UNREACHABLE \(/)
    expect(err.message).not.toMatch(/Illegal invocation/)
  })

  it("never puts the key or a URL with credentials into the error text (review P2)", async () => {
    const key = "fs_live_SECRETKEYVALUE0123456789abcdef"
    const fetchFn = (async () => {
      throw new TypeError(`Headers.append: "Bearer ${key}\n" is an invalid header value. Fetch API cannot load: https://user:pass@api.example/v5?key=abc`)
    }) as unknown as typeof fetch
    const driver = new FreestyleCloudDriver(`${key}\n`, "https://api.freestyle.sh", "cmuxnp-test-vmimg-1", fetchFn)
    const err = (await driver.find("cmuxnp-test-cld-vm-00000000000000000001").catch((e: unknown) => e)) as Error
    expect(err.message).toMatch(/^read VM: no answer UNREACHABLE \(/)
    for (const leak of [key, "SECRETKEY", "user:pass", "key=abc", "api.example"]) expect(err.message, leak).not.toContain(leak)
  })
})

/** The coderouter edge (plans/cmux-next/vm-coderouter-edge.md) on Freestyle's REST API. */
describe("Freestyle driver TLS rules", () => {
  const RULE = { action: "allow", domain: "coderouter.cmux.internal", source: { vmId: "vm-1" }, destination: { host: "coderouter.example.com", port: 443 }, transform: [{ headers: { "x-chatmux-vm-authorization": "Bearer SECRET.TOKEN.VALUE" } }] } as const
  const recording = (answers: Array<{ status: number; body: unknown }>) => {
    const calls: Array<{ method: string; url: string; body: unknown }> = []
    const fetchFn = (async (url: string, init: RequestInit) => {
      calls.push({ method: init.method ?? "GET", url, body: init.body ? JSON.parse(String(init.body)) : undefined })
      const a = answers.shift() ?? { status: 500, body: {} }
      return new Response(JSON.stringify(a.body), { status: a.status })
    }) as unknown as typeof fetch
    return { calls, driver: new FreestyleCloudDriver("k", "https://api.freestyle.sh", "cmuxnp-test-vmimg-1", fetchFn) }
  }

  it("creates send the rule inline, and only when given one", async () => {
    const { calls, driver } = recording([{ status: 200, body: { id: "vm-1" } }, { status: 200, body: { id: "vm-2" } }])
    const tag = { team: "team_00000000000000000001", machine: "vm_00000000000000000001" }
    await driver.create("cmuxnp-test-cld-vm-00000000000000000001", tag, { idleSeconds: 0, edgeRules: [{ ...RULE, source: {} }] })
    await driver.create("cmuxnp-test-cld-vm-00000000000000000002", tag, { idleSeconds: 0 })
    expect((calls[0]!.body as { tls?: unknown }).tls).toEqual({ rules: [{ ...RULE, source: {} }] })
    expect(calls[1]!.body).not.toHaveProperty("tls")
  })

  it("replaces the VM's rule for the domain in place with the whole rule", async () => {
    const { calls, driver } = recording([{ status: 200, body: { rules: [{ id: "tls_other", domain: "reflection.cmux.internal" }, { id: "tls_1", domain: "coderouter.cmux.internal" }], totalCount: 2 } }, { status: 200, body: { id: "tls_1" } }])
    expect(await driver.replaceTlsRule("vm-1", RULE)).toBe(true)
    expect(calls.map((c) => `${c.method} ${c.url}`)).toEqual(["GET https://api.freestyle.sh/v5/tls?vmId=vm-1&domain=coderouter.cmux.internal", "PUT https://api.freestyle.sh/v5/tls/tls_1"])
    expect(calls[1]!.body).toEqual(RULE)
  })

  it("answers false when the VM has no rule, and fails without the token in the error", async () => {
    expect(await recording([{ status: 200, body: { rules: [], totalCount: 0 } }]).driver.replaceTlsRule("vm-1", RULE)).toBe(false)
    const { driver } = recording([{ status: 200, body: { rules: [{ id: "tls_1", domain: "coderouter.cmux.internal" }] } }, { status: 422, body: { code: "BAD", message: "echo Bearer SECRET.TOKEN.VALUE" } }])
    const err = (await driver.replaceTlsRule("vm-1", RULE).catch((e: unknown) => e)) as Error
    expect(err.message).toMatch(/^replace TLS rule: 422/)
    expect(err.message).not.toContain("SECRET")
  })
})
