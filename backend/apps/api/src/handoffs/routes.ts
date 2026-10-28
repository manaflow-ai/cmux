import { authenticate, withGrantClasses } from "../auth.ts"
import type { Env } from "../env.ts"
import { callerOf } from "../home-attachments.ts"
import { MACHINE_STATUSES, MAX_WAIT_MS, SUMMARY_MAX_CHARS, type HandoffResult, type HandoffSize, type MachineCredential } from "./handoff-do.ts"
import type { HandoffListCursor } from "./index-do.ts"

/**
 * Cloud work mode's hand-off routes (handoff-do.ts). Errors are `{error: {code, message}}`.
 *
 * Owner (a signed-in session or a person's install; callerOf):
 *   POST /v1/handoffs + Idempotency-Key  {sessionId, machine, size?: {vcpus?, memoryGb?, pick?, reason?}}
 *                                        -> 201 {handoff, machineToken}; the same request again answers the same hand-off
 *   GET  /v1/handoffs?limit=&cursor=     -> {handoffs: [{id, sessionId, status, summary, createdAt, updatedAt}], nextCursor}
 *   GET  /v1/handoffs/:id                -> {handoff}
 *   GET  /v1/handoffs/:id/wait?after=<version>&timeoutMs=  -> {handoff} once its version passes `after`, or at the deadline (at most 25 s)
 *   POST /v1/handoffs/:id/cancel         -> {handoff}
 * Machine (`x-cmux-handoff-token: <machineToken>`, or the bearer of a VM install bound to the hand-off's machine):
 *   POST /v1/handoffs/:id/report {status: running|needs-you|done|failed, summary?} -> {handoff};
 *                                        409 handoff.finished (with the hand-off) once it is done, failed or cancelled
 *
 * The routes answer 404 where HANDOFF_DO is unbound (production, until hand-off ships there).
 */
export const HANDOFFS_PATH = /^\/v1\/handoffs(?:\/(ho_[0-9a-f]{20})(?:\/(wait|cancel|report))?)?$/

const NO_STORE = { "cache-control": "no-store" }
const json = (value: unknown, status = 200) => Response.json(value, { status, headers: NO_STORE })
const fail = (status: number, code: string, message: string, extra: Record<string, unknown> = {}) => json({ error: { code, message }, ...extra }, status)
const STATUS: Record<string, number> = { "handoff.not_found": 404, "handoff.conflict": 409, "handoff.finished": 409 }
const answer = <T>(r: HandoffResult<T>, map: (v: T) => unknown, status = 200) =>
  r.ok ? json(map(r.value), status) : fail(STATUS[r.code] ?? 400, r.code, r.message, r.handoff ? { handoff: r.handoff } : {})

const stub = (env: Env, id: string) => env.HANDOFF_DO!.get(env.HANDOFF_DO!.idFromName(id))
const hex = async (text: string) => [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)))].map((b) => b.toString(16).padStart(2, "0")).join("")
const body = async (request: Request): Promise<Record<string, unknown> | null> => {
  const v = (await request.json().catch(() => null)) as unknown
  return v !== null && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : null
}
const SESSION = /^[A-Za-z0-9_.:-]{1,128}$/
const MACHINE = /^[A-Za-z0-9_-]{1,64}$/
const text = (v: unknown, max: number): string | null | undefined => (v === undefined || v === null ? null : typeof v === "string" && v.length <= max ? v.trim() || null : undefined)
const amount = (v: unknown): number | null | undefined => (v === undefined || v === null ? null : typeof v === "number" && Number.isFinite(v) && v > 0 && v <= 4096 ? v : undefined)

const parseSize = (v: unknown): HandoffSize | null => {
  if (v === undefined || v === null) return { vcpus: null, memoryGb: null, pick: null, reason: null }
  if (typeof v !== "object" || Array.isArray(v)) return null
  const s = v as Record<string, unknown>
  const size = { vcpus: amount(s.vcpus), memoryGb: amount(s.memoryGb), pick: text(s.pick, 120), reason: text(s.reason, 300) }
  return Object.values(size).includes(undefined) ? null : (size as HandoffSize)
}

const create = async (request: Request, env: Env, owner: string): Promise<Response> => {
  const b = await body(request)
  if (!b) return fail(400, "validation.invalid", "a JSON object body is required")
  if (typeof b.sessionId !== "string" || !SESSION.test(b.sessionId)) return fail(400, "validation.invalid", "sessionId: the agent session id (letters, digits, _ . : -, at most 128)")
  if (typeof b.machine !== "string" || !MACHINE.test(b.machine)) return fail(400, "validation.invalid", "machine: the cloud machine id (letters, digits, _ -, at most 64)")
  const size = parseSize(b.size)
  if (!size) return fail(400, "validation.invalid", "size: {vcpus?, memoryGb?} positive numbers, {pick?, reason?} short text")
  const key = (request.headers.get("idempotency-key") ?? "").trim()
  if (!key || key.length > 128) return fail(400, "validation.invalid", "an Idempotency-Key header is required (at most 128 characters)")
  if (env.CLOUD_MUTATION_LIMIT && !(await env.CLOUD_MUTATION_LIMIT.limit({ key: `handoff:${owner}` })).success) return fail(429, "rate_limited", "too many hand-offs just now; retry in a minute")
  // The id is the owner's key's: a retry after a lost response reaches the same hand-off.
  const id = `ho_${(await hex(`${owner}\u0000${key}`)).slice(0, 20)}`
  const digest = await hex(JSON.stringify([b.sessionId, b.machine, size]))
  return answer(await stub(env, id).init({ id, owner, requestDigest: digest, sessionId: b.sessionId, machine: b.machine, size }), (v) => v, 201)
}

const encodeCursor = (c: HandoffListCursor) => btoa(JSON.stringify(c)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const decodeCursor = (value: string): HandoffListCursor | null => {
  try {
    const v = JSON.parse(atob(value.replace(/-/g, "+").replace(/_/g, "/"))) as { createdAt?: unknown; id?: unknown }
    return Number.isSafeInteger(v.createdAt) && typeof v.id === "string" ? { createdAt: v.createdAt as number, id: v.id } : null
  } catch {
    return null
  }
}
const bounded = (value: string | null, fallback: number, max: number) => {
  const n = value === null || value === "" ? fallback : Number(value)
  return Number.isSafeInteger(n) ? Math.max(0, Math.min(n, max)) : fallback
}

const owner = async (request: Request, env: Env, id: string | undefined, sub: string | undefined): Promise<Response> => {
  const write = request.method === "POST"
  const caller = await callerOf(request, env, write ? "mutate-shared" : "read")
  if ("status" in caller) return fail(caller.status, caller.code, caller.message)
  const url = new URL(request.url)
  if (!id) {
    if (write) return create(request, env, caller.user)
    if (request.method !== "GET") return fail(405, "method_not_allowed", "GET or POST")
    const cursor = url.searchParams.get("cursor")
    const before = cursor ? decodeCursor(cursor) : undefined
    if (before === null) return fail(400, "validation.invalid", "cursor: use the nextCursor of the previous page")
    const ns = env.HANDOFF_INDEX_DO!
    const page = await ns.get(ns.idFromName(caller.user)).list(Math.max(1, bounded(url.searchParams.get("limit"), 50, 100)), before)
    return json({ handoffs: page.handoffs, nextCursor: page.next ? encodeCursor(page.next) : null })
  }
  if (sub === "cancel") return write ? answer(await stub(env, id).cancel(caller.user), (handoff) => ({ handoff })) : fail(405, "method_not_allowed", "POST")
  if (request.method !== "GET") return fail(405, "method_not_allowed", "GET")
  if (sub === "wait") return answer(await stub(env, id).wait(caller.user, bounded(url.searchParams.get("after"), 0, Number.MAX_SAFE_INTEGER), bounded(url.searchParams.get("timeoutMs"), MAX_WAIT_MS, MAX_WAIT_MS)), (handoff) => ({ handoff }))
  return answer(await stub(env, id).get(caller.user), (handoff) => ({ handoff }))
}

/** The machine's credential: the hand-off's token, or a live VM install (its owner and bound machine). */
const machineCredential = async (request: Request, env: Env): Promise<MachineCredential | Response> => {
  const token = request.headers.get("x-cmux-handoff-token")?.trim()
  if (token) return { token }
  const bearer = /^Bearer (.+)$/.exec(request.headers.get("authorization") ?? "")?.[1]
  const p = await authenticate(env, bearer)
  if (!p || p.kind !== "install" || p.install_kind !== "vm") return fail(401, "auth.unauthenticated", "the hand-off's machine token or its machine's VM install is required")
  const granted = await withGrantClasses(env, p).catch(() => null)
  if (granted === null) return fail(503, "owner.unreachable", "the install could not be checked; retry")
  if (!granted?.user || granted.install_kind !== "vm" || !granted.bound_machine) return fail(401, "auth.unauthenticated", "install revoked or not bound to a machine")
  return { owner: granted.user, machine: granted.bound_machine }
}

const report = async (request: Request, env: Env, id: string): Promise<Response> => {
  if (request.method !== "POST") return fail(405, "method_not_allowed", "POST")
  const cred = await machineCredential(request, env)
  if (cred instanceof Response) return cred
  const b = await body(request)
  if (!b || typeof b.status !== "string" || !MACHINE_STATUSES.has(b.status)) return fail(400, "validation.invalid", "status: running, needs-you, done or failed")
  const summary = text(b.summary, SUMMARY_MAX_CHARS)
  if (summary === undefined) return fail(400, "validation.invalid", `summary: text of at most ${SUMMARY_MAX_CHARS} characters`)
  return answer(await stub(env, id).report(cred, b.status, summary), (handoff) => ({ handoff }))
}

export const handleHandoffs = async (request: Request, env: Env, m: RegExpMatchArray): Promise<Response> => {
  if (!env.HANDOFF_DO || !env.HANDOFF_INDEX_DO) return fail(404, "not_found", "not found")
  try {
    return m[2] === "report" ? await report(request, env, m[1]!) : await owner(request, env, m[1], m[2])
  } catch (e) {
    console.error(JSON.stringify({ msg: "handoffs.route_failed", error: String(e).slice(0, 200) }))
    return fail(503, "handoff.unavailable", "the hand-off store is unavailable; retry")
  }
}
