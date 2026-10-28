import type { Principal } from "@cmux/ownership"
import { authenticate } from "./auth.ts"
import { APP_NAME, checkSubmission, PUBLISHER, SEMVER } from "./app-registry-bundle.ts"
import type { AppRegistryDO, Result, Submission } from "./app-registry-do.ts"
import type { Env } from "./env.ts"

/**
 * The app registry's HTTP routes (custom-panes-DESIGN.md 6.3), all under /v1/apps/registry/.
 * Public reads answer approved versions only. Person routes need a person's own session (never
 * an install or an agent token) with a verified email. Review routes also need the person on
 * APP_REVIEWERS (comma-separated user ids, the CLOUD_ADMIN_USERS shape); without it they are 404.
 */
export const APP_REGISTRY_PREFIX = "/v1/apps/registry/"

/** A submit body: 2 MiB decoded is about 2.8 MiB of base64, plus the manifest and paths. */
const MAX_SUBMIT_BODY = 4 * 1024 * 1024
const MAX_DECIDE_BODY = 8 * 1024

const json = (body: unknown, status = 200, cache = "no-store") => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": cache } })
const err = (status: number, code: string, message: string) => json({ error: { code, message } }, status)
const PUBLIC_CACHE = "public, max-age=60"

const registry = (env: Env) => {
  const ns = env.APP_REGISTRY_DO
  return ns ? (ns.get(ns.idFromName("global")) as unknown as DurableObjectStub<AppRegistryDO>) : undefined
}

const reviewers = (env: Env) => new Set((env.APP_REVIEWERS ?? "").split(",").map((u) => u.trim()).filter(Boolean))

type Person = { readonly user: string; readonly email: string }

/** The caller as a person, or the refusal: 401 without a valid token, 403 for an install, an agent or an unverified email. */
const person = async (request: Request, env: Env): Promise<Person | Response> => {
  const auth = request.headers.get("authorization") ?? ""
  const p: Principal | undefined = await authenticate(env, auth.startsWith("Bearer ") ? auth.slice(7) : undefined).catch(() => undefined)
  if (!p) return err(401, "auth.unauthenticated", "sign in to use the app registry")
  if (p.kind !== "session" || p.agent !== undefined || !p.user) return err(403, "auth.forbidden", "a person's session is required (never an install or an agent)")
  if (p.email_verified !== true || !p.email) return err(403, "auth.email_unverified", "verify your email to use the app registry")
  return { user: p.user, email: p.email }
}

const readJson = async (request: Request, max: number): Promise<unknown | Response> => {
  if (Number(request.headers.get("content-length") ?? "0") > max) return err(413, "registry.too_large", "body too large")
  // Without a content-length the body is read in chunks and dropped once it passes max.
  const chunks: Array<Uint8Array> = []
  let size = 0
  if (request.body) {
    const reader = request.body.getReader()
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      size += value.byteLength
      if (size > max) {
        await reader.cancel()
        return err(413, "registry.too_large", "body too large")
      }
      chunks.push(value)
    }
  }
  const bytes = new Uint8Array(size)
  let at = 0
  for (const chunk of chunks) {
    bytes.set(chunk, at)
    at += chunk.byteLength
  }
  try {
    return JSON.parse(new TextDecoder().decode(bytes)) as unknown
  } catch {
    return err(400, "registry.invalid", "a JSON body is required")
  }
}

const segment = (s: string) => {
  try {
    return decodeURIComponent(s)
  } catch {
    return ""
  }
}

const APP_PATH = /^apps\/([^/]+)\/([^/]+)$/
const BUNDLE_PATH = /^apps\/([^/]+)\/([^/]+)\/versions\/([^/]+)\/bundle$/
const REVIEW_FILES_PATH = /^review\/submissions\/(sub_[0-9a-f]{20})\/files$/
const REVIEW_DECIDE_PATH = /^review\/submissions\/(sub_[0-9a-f]{20})$/

export const handleAppRegistry = async (request: Request, env: Env): Promise<Response> => {
  const url = new URL(request.url)
  const rest = url.pathname.slice(APP_REGISTRY_PREFIX.length)
  const method = request.method
  const isReview = rest.startsWith("review/")
  // Review routes do not exist without a reviewer list, whoever asks.
  if (isReview && reviewers(env).size === 0) return err(404, "not_found", "not found")
  const stub = registry(env)
  if (!stub) return err(503, "registry.unavailable", "the app registry is not available here")

  // Public reads: approved versions only.
  if (rest === "listings" && method === "GET") {
    const query = (url.searchParams.get("query") ?? "").slice(0, 200)
    const cursor = (url.searchParams.get("cursor") ?? "").slice(0, 200)
    return json(await stub.listings(query, cursor), 200, PUBLIC_CACHE)
  }
  const appPath = rest.match(APP_PATH)
  if (appPath && method === "GET") {
    const [publisher, name] = [segment(appPath[1]!), segment(appPath[2]!)]
    if (!PUBLISHER.test(publisher) || !APP_NAME.test(name)) return err(404, "registry.not_found", "no such app")
    const app = await stub.app(`${publisher}/${name}`)
    return app ? json(app, 200, PUBLIC_CACHE) : err(404, "registry.not_found", "no such app")
  }
  const bundlePath = rest.match(BUNDLE_PATH)
  if (bundlePath && method === "GET") {
    const [publisher, name, version] = [segment(bundlePath[1]!), segment(bundlePath[2]!), segment(bundlePath[3]!)]
    if (!PUBLISHER.test(publisher) || !APP_NAME.test(name) || !SEMVER.test(version)) return err(404, "registry.not_found", "no such approved version")
    const bundle = await stub.bundle(`${publisher}/${name}`, version)
    // An approved version never changes, so its bundle may be cached longer.
    return bundle ? json(bundle, 200, "public, max-age=300") : err(404, "registry.not_found", "no such approved version")
  }

  const known = rest === "me" || rest === "submissions" || rest === "review/queue" || REVIEW_FILES_PATH.test(rest) || REVIEW_DECIDE_PATH.test(rest)
  if (!known) return err(404, "not_found", "not found")
  const who = await person(request, env)
  if (who instanceof Response) return who
  const reviewer = reviewers(env).has(who.user)

  if (rest === "me" && method === "GET") return json({ user: who.user, reviewer, publishers: (await stub.me(who.user)).publishers })
  if (rest === "submissions" && method === "GET") return json({ submissions: await stub.mine(who.user) })
  if (rest === "submissions" && method === "POST") {
    const body = await readJson(request, MAX_SUBMIT_BODY)
    if (body instanceof Response) return body
    const checked = await checkSubmission(body)
    if (!checked.ok) return err(checked.refusal.status, checked.refusal.code, checked.refusal.message)
    const r = (await stub.submit(who.user, checked.value)) as Result<Submission>
    return r.ok ? json({ submission: r.value }, 201) : err(r.refusal.status, r.refusal.code, r.refusal.message)
  }
  if (!isReview) return err(405, "method_not_allowed", "method not allowed")

  if (!reviewer) return err(403, "registry.not_reviewer", "this person is not an app reviewer")
  if (rest === "review/queue" && method === "GET") return json({ submissions: await stub.reviewQueue() })
  const files = rest.match(REVIEW_FILES_PATH)
  if (files && method === "GET") {
    const path = url.searchParams.get("path") ?? ""
    const file = path ? await stub.file(files[1]!, path) : null
    return file ? json(file) : err(404, "registry.not_found", "no such file")
  }
  const decide = rest.match(REVIEW_DECIDE_PATH)
  if (decide && method === "POST") {
    const body = await readJson(request, MAX_DECIDE_BODY)
    if (body instanceof Response) return body
    const { decision, reason } = (body ?? {}) as { decision?: unknown; reason?: unknown }
    if (decision !== "approve" && decision !== "reject") return err(400, "registry.decision", 'decision must be "approve" or "reject"')
    const text = typeof reason === "string" ? reason.trim() : ""
    if (decision === "reject" && (text.length < 8 || text.length > 500)) return err(400, "registry.reason", "a rejection needs a reason of 8 to 500 characters")
    if (text.length > 500) return err(400, "registry.reason", "a reason is at most 500 characters")
    const r = (await stub.decide(who.user, decide[1]!, decision, text || null)) as Result<Submission>
    return r.ok ? json({ submission: r.value }) : err(r.refusal.status, r.refusal.code, r.refusal.message)
  }
  return err(405, "method_not_allowed", "method not allowed")
}

