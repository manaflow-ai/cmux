import { describe, expect, it } from "bun:test"
import { createCloudClient, CloudHttpError } from "../src/index.ts"

const fakeFetch = (status: number, body: unknown, seen: Array<{ url: string; init: RequestInit }>) =>
  (async (url: string, init: RequestInit) => {
    seen.push({ url, init })
    return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } })
  }) as unknown as typeof fetch

describe("cloud client transport", () => {
  it("sends a mutation with a bearer token and an idempotency key, and returns the settle", async () => {
    const seen: Array<{ url: string; init: RequestInit }> = []
    const client = createCloudClient({
      baseUrl: "https://api.test/",
      token: () => "tok",
      fetch: fakeFetch(200, { ok: true, op: "install.rename", value: { id: "inst_x" }, revision: "4", transaction: "tx1", replayed: false, idempotency_key: "k1", stream: "user:u", sequence: 4 }, seen)
    })
    const r = await client.mutate("install.rename", { install: "inst_00000000000000000000", name: "n" }, { idempotencyKey: "k1" })
    expect(r.ok).toBe(true)
    expect(r.sequence).toBe(4)
    expect(seen[0]!.url).toBe("https://api.test/v1/ops")
    expect((seen[0]!.init.headers as Record<string, string>).authorization).toBe("Bearer tok")
    expect(JSON.parse(String(seen[0]!.init.body))).toMatchObject({ op: "install.rename", idempotency_key: "k1", origin: "user" })
  })

  it("returns an owner reject as a value, not an exception", async () => {
    const client = createCloudClient({
      baseUrl: "https://api.test",
      token: () => "tok",
      fetch: fakeFetch(200, { ok: false, op: "install.rename", error: { code: "auth.forbidden", message: "no", retryable: false }, transaction: "tx", replayed: false, idempotency_key: "k", stream: "user:u", sequence: 0 }, [])
    })
    const r = await client.mutate("install.rename", { install: "inst_00000000000000000000", name: "n" })
    expect(r.ok).toBe(false)
    if (!r.ok) expect(r.error.code).toBe("auth.forbidden")
  })

  it("throws CloudHttpError for gateway refusals", async () => {
    const client = createCloudClient({ baseUrl: "https://api.test", token: () => "x", fetch: fakeFetch(401, { code: "auth.unauthenticated" }, []) })
    await expect(client.read("install.list", {})).rejects.toBeInstanceOf(CloudHttpError)
  })
})
