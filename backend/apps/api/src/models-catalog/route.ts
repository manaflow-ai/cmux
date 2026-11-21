import type { Env } from "../env.ts"
import { MODELS } from "../inference/catalog.ts"
import { allowedModels } from "../inference/chat-request.ts"
import { liveRoutes } from "../inference/route.ts"
import type { Kill, ScoutRun, StoredVersion } from "./catalog-do.ts"
import { catalogStub as stub, readCatalog as read, ROUTER_HARNESS } from "./store.ts"

/**
 * The live model catalog (user 2026-11-19, chat 40603): the one source of truth for which models each
 * harness offers, read at run time by the app, the Chief and the CLI (acpmux catalog/fetch.rs), so a
 * new model needs no app release.
 *
 *   GET  /v1/models/catalog            public: the newest published catalog (schemaVersion 1), with the
 *                                       router's own `cmux` harness and the kill switch applied; strong
 *                                       ETag, 304 on If-None-Match. 503 before the first publish (clients
 *                                       keep their last good or bundled copy).
 *   GET  /v1/models/catalog/health     public: version, last scout run, staleness (503 when stale)
 *   PUT  /internal/v1/models/catalog   publish a new version (the model scout; MODELS_CATALOG_TOKEN)
 *   POST /internal/v1/models/kill      {model, harness?, reason}: the per-model kill switch
 *   POST /internal/v1/models/unkill    {model, harness?}
 *   POST /internal/v1/models/runs      {id, ok, summary}: a scout run's report
 *   GET  /internal/v1/models/status    versions, kills and recent runs
 *
 * The router refuses a killed `cmux` model too (inference/route.ts), so a kill holds for clients that
 * never read this catalog. Contract with the picker: web/services/model-catalog/types.ts (status
 * "disabled" added for the kill switch; `plans`, `statusReason` and top-level `version` are optional).
 */

export { ROUTER_HARNESS }
/** The plans the router serves (inference/plan.ts: paid plans; credits also pay). */
export const ROUTER_PLANS = ["plus", "pro", "max", "team"] as const
/** Published bodies above this are refused; the client refuses above 2 MB. */
export const MAX_PUBLISH_BYTES = 1_500_000
/** The scout runs every 6 h; no good run for this long marks the catalog stale. */
export const STALE_AFTER_MS = 13 * 3_600_000
/** Clients check hourly; a CDN or proxy may keep a copy for 5 min and serve it stale for a day. */
export const CACHE_CONTROL = "public, max-age=300, stale-while-revalidate=86400"

type Json = Record<string, any>

const json = (status: number, body: unknown, headers: Record<string, string> = {}) => Response.json(body, { status, headers: { "cache-control": "no-store", ...headers } })
const fail = (status: number, code: string, message: string) => json(status, { error: { code, message } })

const switchOn = (v: string | undefined) => v === "1" || v === "true"

const killedIn = (kills: ReadonlyArray<Kill>, harness: string, ...ids: Array<string | undefined>) =>
  kills.find((k) => (k.harness === "*" || k.harness === harness) && ids.some((id) => id !== undefined && id === k.model))

/** The router's harness entry: the models this deployment serves now (allowlist, a live route), default first. */
export const routerHarness = (env: Env): Json => {
  const allowed = allowedModels(env)
  const serving = switchOn(env.INFERENCE_ENABLED) ? MODELS.filter((m) => allowed.has(m.id) && liveRoutes(env, m).length > 0) : []
  const order = [...allowed]
  serving.sort((a, b) => order.indexOf(a.id) - order.indexOf(b.id))
  return {
    id: ROUTER_HARNESS,
    name: "cmux",
    brand: "cmux",
    families: [ROUTER_HARNESS],
    modelSource: "catalog",
    ...(serving[0] ? { defaultModel: serving[0].id } : {}),
    models: serving.map((m) => ({ id: m.id, name: m.name, shortName: m.name, provider: m.id.split("/")[0]!, plans: [...ROUTER_PLANS] }))
  }
}

/** Router models' metadata for the catalog's `models` map (only where the published catalog has none). */
const routerModelInfo = (doc: Json) => {
  for (const h of doc.harnesses as Array<Json>) {
    if (h.id !== ROUTER_HARNESS) continue
    for (const hm of h.models as Array<Json>) {
      const m = MODELS.find((x) => x.id === hm.id)
      if (!m || doc.models[m.id]) continue
      doc.models[m.id] = { name: m.name, contextWindow: m.context, maxOutput: m.maxOutput, toolCall: m.tools, input: m.vision ? ["text", "image"] : ["text"], cost: { input: m.card.input, output: m.card.output } }
    }
  }
}

/** Marks every killed model `disabled` (the picker hides it; the models.dev overlay never re-adds it). */
export const applyKills = (doc: Json, kills: ReadonlyArray<Kill>) => {
  for (const h of doc.harnesses as Array<Json>) {
    for (const m of h.models as Array<Json>) {
      const k = killedIn(kills, h.id, m.id, m.ref)
      if (k) Object.assign(m, { status: "disabled", statusReason: k.reason })
    }
    const def = (h.models as Array<Json>).find((m) => m.id === h.defaultModel)
    if (def?.status === "disabled") {
      const next = (h.models as Array<Json>).find((m) => m.status !== "disabled")
      if (next) h.defaultModel = next.id
      else delete h.defaultModel
    }
  }
  for (const [id, info] of Object.entries(doc.models as Record<string, Json>)) {
    const k = kills.find((x) => x.harness === "*" && x.model === id)
    if (k) Object.assign(info, { status: "disabled", statusReason: k.reason })
  }
}

interface Built {
  readonly key: string
  readonly body: string
  readonly etag: string
  readonly version: number
}
let built: Built | undefined

const sha256 = async (text: string) => {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)))
  return btoa(String.fromCharCode(...d)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

/** The served document for a stored version and the kills, built once per change. */
export const buildServed = async (env: Env, stored: StoredVersion, kills: ReadonlyArray<Kill>): Promise<Built> => {
  const router = routerHarness(env)
  const key = `${stored.version}|${JSON.stringify(kills)}|${JSON.stringify(router)}`
  if (built?.key === key) return built
  const doc = JSON.parse(stored.body) as Json
  doc.version = stored.version
  doc.source = "live"
  doc.harnesses = [...(doc.harnesses as Array<Json>).filter((h) => h.id !== ROUTER_HARNESS), router]
  routerModelInfo(doc)
  applyKills(doc, kills)
  const body = JSON.stringify(doc)
  built = { key, body, etag: `"${await sha256(body)}"`, version: stored.version }
  return built
}

const matches = (header: string | null, etag: string) => !!header && header.split(",").some((v) => v.trim().replace(/^W\//, "") === etag || v.trim() === "*")

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, HEAD, OPTIONS",
  "access-control-allow-headers": "If-None-Match",
  "access-control-expose-headers": "ETag, X-Cmux-Catalog-Source, X-Cmux-Catalog-Version"
}

const serveCatalog = async (env: Env, request: Request): Promise<Response> => {
  const { stored, kills } = await read(env)
  if (!stored) return new Response(JSON.stringify({ error: { code: "catalog.unpublished", message: "no catalog is published yet; keep the last good copy" } }), { status: 503, headers: { ...CORS, "content-type": "application/json", "cache-control": "no-store", "retry-after": "600" } })
  const b = await buildServed(env, stored, kills)
  const headers = { ...CORS, etag: b.etag, "cache-control": CACHE_CONTROL, "x-cmux-catalog-source": "live", "x-cmux-catalog-version": String(b.version), "x-content-type-options": "nosniff" }
  if (matches(request.headers.get("if-none-match"), b.etag)) return new Response(null, { status: 304, headers })
  return new Response(request.method === "HEAD" ? null : b.body, { status: 200, headers: { ...headers, "content-type": "application/json; charset=utf-8" } })
}

const parseSummary = (text: string): Json => {
  try {
    const v = JSON.parse(text) as unknown
    return v && typeof v === "object" ? (v as Json) : {}
  } catch {
    return {}
  }
}

const summarizeRun = (r: ScoutRun | undefined) => {
  if (!r) return null
  const s = parseSummary(r.summary)
  return { id: r.id, at: new Date(r.at).toISOString(), ok: r.ok, added: s.added ?? [], failed: s.failed ?? [], unserved: s.unserved ?? [] }
}

const serveHealth = async (env: Env): Promise<Response> => {
  const s = stub(env)
  const [stored, runs, kills] = await Promise.all([s.history(1), s.runs(20), s.kills()])
  const lastOk = runs.find((r) => r.ok)
  const stale = !lastOk || Date.now() - lastOk.at > STALE_AFTER_MS
  const body = {
    version: stored[0]?.version ?? null,
    publishedAt: stored[0] ? new Date(stored[0].publishedAt).toISOString() : null,
    lastRun: summarizeRun(runs[0]),
    lastOkRunAt: lastOk ? new Date(lastOk.at).toISOString() : null,
    stale,
    kills: kills.length
  }
  return json(stored[0] && !stale ? 200 : 503, body, CORS)
}

/** Constant-time compare of the bearer with MODELS_CATALOG_TOKEN. */
const admin = (env: Env, request: Request): boolean => {
  const want = env.MODELS_CATALOG_TOKEN
  const h = request.headers.get("authorization") ?? ""
  if (!want || !h.toLowerCase().startsWith("bearer ")) return false
  const a = new TextEncoder().encode(h.slice(7).trim())
  const b = new TextEncoder().encode(want)
  let diff = a.length ^ b.length
  for (let i = 0; i < Math.max(a.length, b.length); i++) diff |= (a[i] ?? 0) ^ (b[i] ?? 0)
  return diff === 0
}

const SLUG = /^[a-z0-9][a-z0-9-]{0,63}$/
const MODEL_ID = /^[A-Za-z0-9][A-Za-z0-9._:/@[\]+-]{0,199}$/

/** The checks a published document must pass (a subset of acpmux catalog/schema.rs; the client checks the rest). */
export const checkPublished = (text: string): string | null => {
  if (new TextEncoder().encode(text).length > MAX_PUBLISH_BYTES) return `the catalog is above ${MAX_PUBLISH_BYTES} bytes`
  let doc: Json
  try {
    doc = JSON.parse(text) as Json
  } catch {
    return "the body is not JSON"
  }
  if (doc?.schemaVersion !== 1) return "schemaVersion must be 1"
  if (typeof doc.generatedAt !== "string" || Number.isNaN(Date.parse(doc.generatedAt))) return "generatedAt must be an ISO time"
  if (!Array.isArray(doc.harnesses) || doc.harnesses.length === 0 || doc.harnesses.length > 64) return "harnesses must hold 1 to 64 entries"
  if (!doc.models || typeof doc.models !== "object" || !doc.providers || typeof doc.providers !== "object") return "models and providers must be objects"
  for (const h of doc.harnesses as Array<Json>) {
    if (typeof h?.id !== "string" || !SLUG.test(h.id) || !Array.isArray(h.models)) return `harness ${String(h?.id)} is malformed`
    for (const m of h.models as Array<Json>) if (typeof m?.id !== "string" || !MODEL_ID.test(m.id) || typeof m.name !== "string") return `harness ${h.id}: a model is malformed`
  }
  for (const need of ["claude", "codex"]) {
    const h = (doc.harnesses as Array<Json>).find((x) => x.id === need)
    if (!h || h.models.length === 0) return `the catalog has no ${need} models`
  }
  return null
}

const body = async (request: Request): Promise<Json | null> => {
  const text = await request.text()
  if (text.length > 64_000) return null
  try {
    const v = JSON.parse(text) as unknown
    return v && typeof v === "object" ? (v as Json) : null
  } catch {
    return null
  }
}

export const handleModelsCatalog = async (env: Env, request: Request, path: string): Promise<Response> => {
  if (!env.MODEL_CATALOG_DO) return fail(404, "not_found", "not found")
  if (path === "/v1/models/catalog") {
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS })
    if (request.method === "GET" || request.method === "HEAD") return serveCatalog(env, request)
    return fail(405, "method.not_allowed", "GET only")
  }
  if (path === "/v1/models/catalog/health" && request.method === "GET") return serveHealth(env)
  if (!path.startsWith("/internal/v1/models/")) return fail(404, "not_found", "not found")
  if (!admin(env, request)) return fail(401, "auth.invalid", "bad token")
  const s = stub(env)
  if (path === "/internal/v1/models/catalog" && request.method === "PUT") {
    const text = await request.text()
    const problem = checkPublished(text)
    if (problem) return fail(400, "catalog.invalid", problem)
    const version = await s.publish(text, request.headers.get("x-cmux-note") ?? "")
    await read(env, true)
    return json(200, { version })
  }
  if ((path === "/internal/v1/models/kill" || path === "/internal/v1/models/unkill") && request.method === "POST") {
    const b = await body(request)
    const model = typeof b?.model === "string" ? b.model : ""
    const harness = typeof b?.harness === "string" && b.harness ? b.harness : "*"
    if (!MODEL_ID.test(model) || (harness !== "*" && !SLUG.test(harness))) return fail(400, "validation.invalid", "model (and harness, a slug or *) required")
    if (path.endsWith("/kill")) {
      const reason = typeof b?.reason === "string" && b.reason.trim() ? b.reason.trim() : "turned off by cmux"
      await s.kill(harness, model, reason, typeof b?.by === "string" ? b.by : "admin")
    } else await s.unkill(harness, model)
    await read(env, true)
    return json(200, { kills: await s.kills() })
  }
  if (path === "/internal/v1/models/runs" && request.method === "POST") {
    const b = await body(request)
    if (!b || typeof b.id !== "string" || typeof b.ok !== "boolean") return fail(400, "validation.invalid", "id and ok required")
    await s.recordRun({ id: b.id, at: Date.now(), ok: b.ok, summary: JSON.stringify(b.summary && typeof b.summary === "object" ? b.summary : {}) })
    return json(200, { ok: true })
  }
  if (path === "/internal/v1/models/status" && request.method === "GET") {
    const [history, kills, runs] = await Promise.all([s.history(20), s.kills(), s.runs(20)])
    return json(200, { history, kills, runs: runs.map((r) => ({ ...r, summary: parseSummary(r.summary) })) })
  }
  return fail(404, "not_found", "not found")
}
