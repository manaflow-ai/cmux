import { describe, expect, it } from "vitest"
import { createdAndBound, person, worker } from "./cloud-bind-support.ts"

/**
 * CLOUD-LINK-FOLLOWUPS (1) part 2: GET /v1/cloud/keyset, public and cacheable (JWKS-style). The VM
 * daemon refetches it on an unknown kid (rate-limited on its side) and once a day. It answers the
 * same {version, keys} the bind answer carries, public halves only.
 */

describe("public link keyset", { timeout: 60_000 }, () => {
  it("answers the bind keyset with no private part, cacheable, no credential needed", async () => {
    const x = person()
    const { keyset } = await createdAndBound(x)
    const res = await worker.fetch("https://api.test/v1/cloud/keyset")
    expect(res.status).toBe(200)
    expect(res.headers.get("cache-control")).toBe("public, max-age=300")
    const body = (await res.json()) as { ok: boolean; value: { version: string; keys: Record<string, Record<string, unknown>> } }
    expect(body).toEqual({ ok: true, value: keyset })
    for (const k of Object.values(body.value.keys)) expect(k).not.toHaveProperty("d")
  })

  it("answers only GET", async () => {
    expect((await worker.fetch("https://api.test/v1/cloud/keyset", { method: "POST" })).status).toBe(405)
  })
})
