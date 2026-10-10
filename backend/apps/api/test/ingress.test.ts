import { describe, expect, it } from "vitest"
import { verifyGitHub, verifyLinear, verifySlack } from "../src/ingress/providers.ts"
import { freshTimestamp, hmacHex, readRawBody, timingSafeEqual } from "../src/ingress/verify.ts"

const SECRET = "test-secret"
const now = Date.UTC(2026, 9, 2, 12, 0, 0)

describe("verify primitives", () => {
  it("compares in constant time and checks the replay window", async () => {
    expect(timingSafeEqual("abc", "abc")).toBe(true)
    expect(timingSafeEqual("abc", "abd")).toBe(false)
    expect(timingSafeEqual("abc", "abcd")).toBe(false)
    expect(freshTimestamp(String(now / 1000 - 299), now)).toBe(true)
    expect(freshTimestamp(String(now / 1000 - 301), now)).toBe(false)
    expect(freshTimestamp("12abc", now)).toBe(false)
    // RFC 4231 test case 2.
    expect(await hmacHex("Jefe", "what do ya want for nothing?")).toBe("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
  })
  it("refuses bodies over the limit by header and by stream", async () => {
    const declared = await readRawBody(new Request("https://x", { method: "POST", body: "x", headers: { "content-length": "999999999" } }), 10)
    expect(declared).toMatchObject({ ok: false, status: 413 })
    const streamed = await readRawBody(new Request("https://x", { method: "POST", body: "x".repeat(11) }), 10)
    expect(streamed).toMatchObject({ ok: false, status: 413 })
    expect(await readRawBody(new Request("https://x", { method: "POST", body: "hello" }), 10)).toMatchObject({ ok: true, text: "hello" })
  })
})

describe("GitHub", () => {
  const body = JSON.stringify({ action: "opened", installation: { id: 42 }, pull_request: { number: 7 } })
  const headers = async (b = body) => new Headers({ "x-hub-signature-256": `sha256=${await hmacHex(SECRET, b)}`, "x-github-delivery": "d-1", "x-github-event": "pull_request" })
  it("refuses a tampered body, a wrong secret and non-App hooks", async () => {
    expect((await verifyGitHub(SECRET, await headers(), body.replace("7", "8"))).ok).toBe(false)
    expect((await verifyGitHub("other", await headers(), body)).ok).toBe(false)
    const plain = JSON.stringify({ action: "opened" })
    expect(await verifyGitHub(SECRET, await headers(plain), plain)).toMatchObject({ ok: false, status: 400 })
  })
})

describe("Slack", () => {
  const ts = String(now / 1000)
  const sign = async (b: string, t = ts) => new Headers({ "x-slack-request-timestamp": t, "x-slack-signature": `v0=${await hmacHex(SECRET, `v0:${t}:${b}`)}` })
  it("refuses stale and forged requests", async () => {
    const ev = JSON.stringify({ type: "event_callback", team_id: "T1", event_id: "Ev1", event: { type: "message" } })
    const old = String(now / 1000 - 600)
    expect(await verifySlack(SECRET, await sign(ev, old), ev, now)).toMatchObject({ ok: false, status: 401 })
    expect((await verifySlack("other", await sign(ev), ev, now)).ok).toBe(false)
  })
})

describe("Linear", () => {
  const make = (ts: number) => JSON.stringify({ type: "Issue", action: "create", organizationId: "org-1", webhookTimestamp: ts, data: { id: "i1" } })
  const sign = async (b: string) => new Headers({ "linear-signature": await hmacHex(SECRET, b), "linear-delivery": "ld-1", "linear-event": "Issue" })
  it("refuses a delivery older than one minute or forged", async () => {
    const b = make(now - 61_000)
    expect(await verifyLinear(SECRET, await sign(b), b, now)).toMatchObject({ ok: false, status: 401 })
    const fresh = make(now)
    expect((await verifyLinear("other", await sign(fresh), fresh, now)).ok).toBe(false)
  })
})
