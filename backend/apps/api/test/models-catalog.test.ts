import { env } from "cloudflare:workers"
import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import worker from "../src/index.ts"
import { checkPublished } from "../src/models-catalog/route.ts"
import { resetCatalogSnapshot } from "../src/models-catalog/store.ts"
import { paidPerson } from "./setup/inference-person.ts"

/**
 * The live model catalog (user 2026-11-19, chat 40603): published versions, the router's own `cmux`
 * harness, the per-model kill switch (in the catalog and in the router), and the scout's run health.
 * One ModelCatalogDO is shared by the file, so each test reads what it needs after its own writes.
 */

const TOKEN = "catalog-admin-test"
const NEON = "google/gemini-4-neon"
const runEnv = (extra: Record<string, string> = {}) =>
  ({ ...env, MODELS_CATALOG_TOKEN: TOKEN, INFERENCE_ENABLED: "1", INFERENCE_MODEL_ALLOWLIST: `deepseek/deepseek-v4.1-flash-1017,${NEON}`, INFERENCE_VERTEX_RELAY_URL: "https://vertex-relay.test/api/vertex/chat/completions", INFERENCE_VERCEL_RELAY_KEY: "relay-secret", INFERENCE_OPENROUTER_KEY: "k-or", ...extra }) as any

const doc = (extraClaude: Array<Record<string, unknown>> = []) => ({
  schemaVersion: 1,
  generatedAt: new Date().toISOString(),
  source: "live",
  harnesses: [
    { id: "claude", name: "Claude Code", brand: "claude", families: ["claude"], modelSource: "catalog", defaultModel: "claude-opus-5-5", models: [{ id: "claude-opus-5-5", name: "Claude Opus 5.5", shortName: "Opus 5.5" }, ...extraClaude] },
    { id: "codex", name: "Codex", brand: "openai", families: ["codex"], modelSource: "catalog", models: [{ id: "gpt-6.1-sol", name: "GPT-6.1 Sol", shortName: "Sol" }] },
    { id: "gemini", name: "Gemini CLI", brand: "gemini", families: ["gemini"], modelSource: "catalog", models: [{ id: "gemini-4-neon", ref: "google/gemini-4-neon", name: "Gemini 4 Neon", shortName: "Neon" }] }
  ],
  models: {},
  providers: {}
})

const call = async (method: string, path: string, opts: { body?: unknown; auth?: string; headers?: Record<string, string>; e?: unknown } = {}) => {
  const ctx = createExecutionContext()
  const headers: Record<string, string> = { ...(opts.auth ? { authorization: `Bearer ${opts.auth}` } : {}), ...(opts.body !== undefined ? { "content-type": "application/json" } : {}), ...opts.headers }
  const res = await worker.fetch!(new Request(`https://api.test${path}`, { method, headers, ...(opts.body !== undefined ? { body: typeof opts.body === "string" ? opts.body : JSON.stringify(opts.body) } : {}) }) as any, (opts.e ?? runEnv()) as any, ctx)
  const text = await res.text()
  await waitOnExecutionContext(ctx)
  return { status: res.status, text, headers: res.headers, json: () => JSON.parse(text) }
}

beforeEach(() => resetCatalogSnapshot())
afterEach(() => vi.restoreAllMocks())

describe("live model catalog", () => {
  it("is 503 before the first publish, so clients keep their last good copy", async () => {
    const r = await call("GET", "/v1/models/catalog")
    expect(r.status).toBe(503)
    expect(r.json().error.code).toBe("catalog.unpublished")
  })

  it("refuses a publish without the admin token, and a malformed catalog", async () => {
    expect((await call("PUT", "/internal/v1/models/catalog", { body: doc() })).status).toBe(401)
    expect((await call("PUT", "/internal/v1/models/catalog", { body: doc(), auth: "wrong" })).status).toBe(401)
    const bad = await call("PUT", "/internal/v1/models/catalog", { body: { ...doc(), harnesses: [] }, auth: TOKEN })
    expect(bad.status).toBe(400)
    expect(checkPublished(JSON.stringify({ ...doc(), harnesses: doc().harnesses.filter((h) => h.id !== "codex") }))).toBe("the catalog has no codex models")
  })

  it("serves the newest version with the router's cmux harness, a strong ETag and 304", async () => {
    const pub = await call("PUT", "/internal/v1/models/catalog", { body: doc(), auth: TOKEN, headers: { "x-cmux-note": "test publish" } })
    expect(pub.status).toBe(200)
    const version = pub.json().version as number
    resetCatalogSnapshot()
    const r = await call("GET", "/v1/models/catalog")
    expect(r.status).toBe(200)
    expect(r.headers.get("x-cmux-catalog-version")).toBe(String(version))
    const etag = r.headers.get("etag")!
    expect(etag).toMatch(/^"[A-Za-z0-9_-]{43}"$/)
    const served = r.json()
    expect(served.version).toBe(version)
    const cmux = served.harnesses.find((h: any) => h.id === "cmux")
    expect(cmux.models.map((m: any) => m.id)).toEqual(["deepseek/deepseek-v4.1-flash-1017", NEON])
    expect(cmux.defaultModel).toBe("deepseek/deepseek-v4.1-flash-1017")
    expect(cmux.models[1]).toMatchObject({ provider: "google", plans: ["plus", "pro", "max", "team"] })
    expect(served.models[NEON]).toMatchObject({ cost: { input: 3, output: 15 }, toolCall: true })
    const again = await call("GET", "/v1/models/catalog", { headers: { "if-none-match": etag } })
    expect(again.status).toBe(304)
  })

  it("the kill switch disables a model in every harness and in the router, and lifts again", async () => {
    await call("PUT", "/internal/v1/models/catalog", { body: doc(), auth: TOKEN })
    const k = await call("POST", "/internal/v1/models/kill", { body: { model: NEON, reason: "provider outage" }, auth: TOKEN })
    expect(k.status).toBe(200)
    resetCatalogSnapshot()
    const served = (await call("GET", "/v1/models/catalog")).json()
    const gemini = served.harnesses.find((h: any) => h.id === "gemini").models[0]
    expect(gemini).toMatchObject({ status: "disabled", statusReason: "provider outage" })
    expect(served.harnesses.find((h: any) => h.id === "cmux").models.find((m: any) => m.id === NEON).status).toBe("disabled")

    // The router refuses it before any money moves, and its models list hides it.
    const { t } = await paidPerson("catalog-kill-router")
    const fetchSpy = vi.spyOn(globalThis, "fetch")
    const chat = await call("POST", "/v1/inference/chat/completions", { body: { model: NEON, max_tokens: 16, messages: [{ role: "user", content: "hi" }] }, auth: t })
    expect(chat.status).toBe(403)
    expect(chat.json().error.code).toBe("model.disabled")
    expect(fetchSpy.mock.calls.some(([u]) => String(u instanceof Request ? u.url : u).includes("vertex-relay.test"))).toBe(false)
    const list = (await call("GET", "/v1/inference/models")).json()
    expect(list.data.map((m: any) => m.id)).not.toContain(NEON)

    await call("POST", "/internal/v1/models/unkill", { body: { model: NEON }, auth: TOKEN })
    resetCatalogSnapshot()
    const after = (await call("GET", "/v1/models/catalog")).json()
    expect(after.harnesses.find((h: any) => h.id === "gemini").models[0].status).toBeUndefined()
  })

  it("a kill outlives a later publish", async () => {
    await call("POST", "/internal/v1/models/kill", { body: { model: "claude-opus-5-5", harness: "claude", reason: "bad build" }, auth: TOKEN })
    await call("PUT", "/internal/v1/models/catalog", { body: doc([{ id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", shortName: "Sonnet 5.5" }]), auth: TOKEN })
    resetCatalogSnapshot()
    const claude = (await call("GET", "/v1/models/catalog")).json().harnesses.find((h: any) => h.id === "claude")
    expect(claude.models.find((m: any) => m.id === "claude-opus-5-5").status).toBe("disabled")
    // The default moves off a killed model.
    expect(claude.defaultModel).toBe("claude-sonnet-5-5")
    await call("POST", "/internal/v1/models/unkill", { body: { model: "claude-opus-5-5", harness: "claude" }, auth: TOKEN })
  })

  it("health is stale (503) until a scout run reports, then names what it added", async () => {
    await call("PUT", "/internal/v1/models/catalog", { body: doc(), auth: TOKEN })
    const before = await call("GET", "/v1/models/catalog/health")
    if (before.json().lastOkRunAt === null) expect(before.status).toBe(503)
    const run = await call("POST", "/internal/v1/models/runs", { body: { id: "run-1", ok: true, summary: { added: [NEON], failed: [], unserved: [] } }, auth: TOKEN })
    expect(run.status).toBe(200)
    const h = await call("GET", "/v1/models/catalog/health")
    expect(h.status).toBe(200)
    expect(h.json()).toMatchObject({ stale: false, lastRun: { id: "run-1", ok: true, added: [NEON] } })
    const status = (await call("GET", "/internal/v1/models/status", { auth: TOKEN })).json()
    expect(status.runs[0].summary.added).toEqual([NEON])
    expect(status.history.length).toBeGreaterThan(0)
  })
})
