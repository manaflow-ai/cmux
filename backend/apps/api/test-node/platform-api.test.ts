// platformRead: cmux-platform's POST /v1/read over the PLATFORM binding, as the caller's own bearer.
import { describe, expect, it } from "vitest"
import { platformRead } from "../src/platform-api.ts"

const ORIGIN = "https://api.example.test/v1/integrations/github/token"
const fake = (answer: () => Response | Promise<Response>) => {
  const seen: Array<{ url: string; method: string; auth: string | null; body: string }> = []
  const fetcher = {
    fetch: async (input: Request) => {
      seen.push({ url: input.url, method: input.method, auth: input.headers.get("authorization"), body: await input.text() })
      return answer()
    },
  } as unknown as Fetcher
  return { fetcher, seen }
}

describe("platformRead", () => {
  it("posts {op, params} to /v1/read as the caller and answers the value", async () => {
    const p = fake(() => Response.json({ op: "cloud.vm.self.get", value: { machine: { id: "vm_1" } }, stream: "cloud:team_a", revision: "cloud:3" }))
    const r = await platformRead(p.fetcher, ORIGIN, "Bearer tok", "cloud.vm.self.get", { machine: "vm_1" })
    expect(r).toEqual({ ok: true, value: { machine: { id: "vm_1" } }, revision: "cloud:3" })
    expect(p.seen).toEqual([{ url: "https://api.example.test/v1/read", method: "POST", auth: "Bearer tok", body: JSON.stringify({ op: "cloud.vm.self.get", params: { machine: "vm_1" } }) }])
  })

  it("answers the platform's refusal as final and its outage as retryable", async () => {
    const refused = await platformRead(fake(() => Response.json({ _tag: "Forbidden", code: "auth.forbidden", message: "not your machine" }, { status: 403 })).fetcher, ORIGIN, "Bearer t", "cloud.vm.self.get", {})
    expect(refused).toEqual({ ok: false, status: 403, code: "auth.forbidden", message: "not your machine", retryable: false })
    const down = await platformRead(fake(() => Response.json({ _tag: "OwnerUnreachable", code: "owner.unreachable", message: "retry", retryable: true }, { status: 503 })).fetcher, ORIGIN, "Bearer t", "cloud.vm.self.get", {})
    expect(down).toMatchObject({ ok: false, code: "owner.unreachable", retryable: true })
    const garbled = await platformRead(fake(() => new Response("oops", { status: 502 })).fetcher, ORIGIN, "Bearer t", "cloud.vm.self.get", {})
    expect(garbled).toMatchObject({ ok: false, status: 502, code: "owner.unreachable", retryable: true })
    const malformed = await platformRead(fake(() => Response.json({ op: "x" })).fetcher, ORIGIN, "Bearer t", "cloud.vm.self.get", {})
    expect(malformed).toMatchObject({ ok: false, code: "owner.unreachable", retryable: true })
  })

  it("answers a retryable outage, never a TypeError, when unbound or unreachable", async () => {
    expect(await platformRead(undefined, ORIGIN, "Bearer t", "cloud.vm.self.get", {})).toMatchObject({ ok: false, code: "owner.unreachable", retryable: true })
    const throws = { fetch: async () => { throw new Error("network") } } as unknown as Fetcher
    expect(await platformRead(throws, ORIGIN, "Bearer t", "cloud.vm.self.get", {})).toMatchObject({ ok: false, code: "owner.unreachable", retryable: true })
  })
})
