import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import type { Env } from "../src/env.ts"
import { execRoot } from "../src/chief-brain-cc/vm.ts"
import { BackgroundLost, backgroundPoll, settleBackground } from "../src/providers/freestyle/background.ts"
import { freestyleHands } from "../src/providers/freestyle/hand.ts"
import { FreestyleDriver } from "../src/providers/freestyle/team-vm.ts"

/**
 * Freestyle's edge cuts a request it holds open at about 125 s (524; production 2026-11-21 cut a 290 s exec-await),
 * though exec-await runs a command for up to 300 s. Every exec-await this Worker sends itself asks for a background
 * request after 60 s, unless it carries a key in stdin, and polls the stored answer with the same credential.
 */

type Seen = { method: string; path: string; after: string | null; auth: string | null; stdin: boolean }
const seen: Array<Seen> = []
let polls = 0

/** A provider whose exec-await of `sleep past the edge` the edge cuts unless it went to the background. */
const stubFreestyle = (stored: () => Response = () => Response.json({ statusCode: 0, stdout: "done\n", stderr: "" })) =>
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const req = new Request(input, init)
    const url = new URL(req.url)
    const body = req.method === "POST" ? ((await req.json().catch(() => ({}))) as { command?: string; stdin?: string }) : {}
    seen.push({ method: req.method, path: url.pathname, after: req.headers.get("x-freestyle-background-after-secs"), auth: req.headers.get("authorization"), stdin: Boolean(body.stdin) })
    if (req.method === "POST" && /^\/v5\/vms\/[^/]+\/exec-await$/.test(url.pathname)) {
      if (body.command !== "sleep past the edge") return Response.json({ statusCode: 0, stdout: "", stderr: "" })
      if (req.headers.get("x-freestyle-background-after-secs") !== "60") return new Response("edge timeout", { status: 524 })
      return Response.json({ requestId: "bg-1" }, { status: 202 })
    }
    if (req.method === "GET" && url.pathname === "/v5/background-requests/bg-1") {
      polls++
      return polls === 1 ? Response.json({ status: "pending" }, { status: 202 }) : stored()
    }
    return Response.json({ code: "UNMOCKED" }, { status: 500 })
  })

const env = {
  HAND_FREESTYLE_API_KEY: "test-only-hand-key",
  CLOUD_FREESTYLE_API_URL: "https://freestyle.test",
  CHIEF_CC_FREESTYLE_API_KEY: "test-only-cc-key",
  CHIEF_CC_FREESTYLE_API_URL: "https://freestyle.test"
} as unknown as Env

const before = backgroundPoll.ms
beforeEach(() => {
  backgroundPoll.ms = 1
})
afterEach(() => {
  backgroundPoll.ms = before
  seen.length = 0
  polls = 0
  vi.restoreAllMocks()
})

const calls = () => seen.map((s) => `${s.method} ${s.path}`)

describe("an exec-await longer than the provider edge holds a request runs as a background request", () => {
  it("a hand sandbox's install (150 s)", async () => {
    stubFreestyle()
    expect(await freestyleHands.exec(env, "fsvm-1", "sleep past the edge", 150_000)).toBe(0)
    expect(calls()).toEqual(["POST /v5/vms/fsvm-1/exec-await", "GET /v5/background-requests/bg-1", "GET /v5/background-requests/bg-1"])
    for (const s of seen) expect(s.auth).toBe("Bearer test-only-hand-key")
  })

  it("a team VM exec", async () => {
    stubFreestyle()
    const driver = new FreestyleDriver("test-only-team-key", "https://freestyle.test", "sh-team")
    expect(await driver.exec("fsvm-2", "sleep past the edge", 290_000)).toEqual({ code: 0, stdout: "done\n" })
    expect(calls()).toEqual(["POST /v5/vms/fsvm-2/exec-await", "GET /v5/background-requests/bg-1", "GET /v5/background-requests/bg-1"])
    for (const s of seen) expect(s.auth).toBe("Bearer test-only-team-key")
  })

  it("a Cloud Chief turn machine's root exec without stdin; one with a key in stdin never goes to the background", async () => {
    stubFreestyle()
    expect(await execRoot(env, "fsvm-3", "sleep past the edge", null, 290_000)).toEqual({ exit: 0, stdout: "done\n" })
    expect(seen[0]).toMatchObject({ after: "60", auth: "Bearer test-only-cc-key" })
    expect(seen[1]).toMatchObject({ method: "GET", path: "/v5/background-requests/bg-1", auth: "Bearer test-only-cc-key" })
    seen.length = 0
    await execRoot(env, "fsvm-3", "true", new TextEncoder().encode("tskey-auth-test"), 30_000)
    expect(seen).toEqual([{ method: "POST", path: "/v5/vms/fsvm-3/exec-await", after: null, auth: "Bearer test-only-cc-key", stdin: true }])
  })

  it("a stored refusal keeps its status, and a lost answer is an error, never a second run", async () => {
    stubFreestyle(() => Response.json({ code: "CONFLICT" }, { status: 409 }))
    await expect(execRoot(env, "fsvm-4", "sleep past the edge", null, 290_000)).rejects.toThrow("exec: 409")
    expect(seen.filter((s) => s.method === "POST")).toHaveLength(1)
  })
})

describe("settleBackground", () => {
  const accepted = () => Response.json({ requestId: "bg-9" }, { status: 202 })
  it("passes any answer but a 202 through", async () => {
    const ok = Response.json({ statusCode: 0 })
    expect(await settleBackground(ok, "https://freestyle.test", {}, Date.now() + 60_000)).toEqual({ res: ok, polled: false })
  })

  it("gives up after five failed polls in a row, and on a 202 that names no request", async () => {
    let n = 0
    const down: typeof fetch = async () => (n++, new Response("busy", { status: 503 }))
    await expect(settleBackground(accepted(), "https://freestyle.test", {}, Date.now() + 60_000, down)).rejects.toBeInstanceOf(BackgroundLost)
    expect(n).toBe(5)
    const bad = Response.json({ requestId: "../x" }, { status: 202 })
    await expect(settleBackground(bad, "https://freestyle.test", {}, Date.now() + 60_000, down)).rejects.toBeInstanceOf(BackgroundLost)
    expect(n).toBe(5)
  })

  it("reads the id from the header, and polls with the given credential only", async () => {
    const asked: Array<{ url: string; auth: string | null }> = []
    const answer: typeof fetch = async (input, init) => {
      const req = new Request(input, init)
      asked.push({ url: req.url, auth: req.headers.get("authorization") })
      return Response.json({ statusCode: 0, stdout: "x" })
    }
    const res = new Response(null, { status: 202, headers: { "x-freestyle-background-request-id": "bg-h" } })
    const got = await settleBackground(res, "https://freestyle.test/", { authorization: "Bearer k" }, Date.now() + 60_000, answer)
    expect(got.polled).toBe(true)
    expect(asked).toEqual([{ url: "https://freestyle.test/v5/background-requests/bg-h", auth: "Bearer k" }])
  })
})
