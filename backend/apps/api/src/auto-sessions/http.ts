import type { AutoResult } from "./model.ts"

/** What every Auto mode route shares: the answers, the bounded body reads and the field checks. Errors are `{error: {code, message}}`. */
const NO_STORE = { "cache-control": "no-store" }
export const json = (value: unknown, status = 200): Response => Response.json(value, { status, headers: NO_STORE })
/** An answer whose JSON text is already built (stored records go out as they were stored). */
export const rawJson = (text: string): Response => new Response(text, { headers: { ...NO_STORE, "content-type": "application/json" } })
export const noContent = (): Response => new Response(null, { status: 204, headers: NO_STORE })
export const fail = (status: number, code: string, message: string, extra: Record<string, unknown> = {}): Response => json({ error: { code, message }, ...extra }, status)
export const invalid = (message: string): Response => fail(400, "validation.invalid", message)
export const notFound = (): Response => fail(404, "not_found", "not found")

const STATUS: Record<string, number> = {
  not_found: 404,
  "auto.stale_epoch": 409,
  "auto.not_holder": 409,
  "auto.no_machine": 409,
  "auto.held_in_cloud": 409,
  "auto.seq_gap": 409,
  "auto.snapshot_incomplete": 409,
  "auto.no_snapshot": 404,
  "auto.chunk_mismatch": 400,
  "auto.too_large": 413,
  "auto.closed": 409
}
/** A refusal goes out with the chat as it is now, and with what its code promises (`lastSeq`, `missing`), beside `error`. */
export const refusal = (r: Extract<AutoResult<unknown>, { ok: false }>): Response => fail(STATUS[r.code] ?? 400, r.code, r.message, { ...(r.session ? { session: r.session } : {}), ...r.extra })
export const answer = <T>(r: AutoResult<T>, map: (v: T) => unknown, status = 200): Response => (r.ok ? json(map(r.value), status) : refusal(r))

/** The request's body, or null when it is larger than `max` bytes. Never reads past the limit. */
export const readBounded = async (request: Request, max: number): Promise<Uint8Array<ArrayBuffer> | null> => {
  if (Number(request.headers.get("content-length") ?? "0") > max) return null
  const parts: Array<Uint8Array> = []
  let size = 0
  if (request.body) {
    const reader = request.body.getReader()
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      size += value.byteLength
      if (size > max) {
        await reader.cancel().catch(() => undefined)
        return null
      }
      parts.push(value)
    }
  }
  const out = new Uint8Array(new ArrayBuffer(size))
  let at = 0
  for (const p of parts) {
    out.set(p, at)
    at += p.byteLength
  }
  return out
}

const TOO_LARGE = (max: number): Response => fail(413, "auto.too_large", `the request body is at most ${max} bytes`)
export const SMALL_BODY = 64 * 1024

/** A JSON object body of at most `max` bytes, or the refusal to answer. */
export const bodyOf = async (request: Request, max = SMALL_BODY): Promise<Record<string, unknown> | Response> => {
  const bytes = await readBounded(request, max)
  if (!bytes) return TOO_LARGE(max)
  let v: unknown = null
  try {
    v = JSON.parse(new TextDecoder().decode(bytes))
  } catch {
    v = null
  }
  return v !== null && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : invalid("a JSON object body is required")
}
export const bytesOf = async (request: Request, max: number): Promise<Uint8Array<ArrayBuffer> | Response> => (await readBounded(request, max)) ?? TOO_LARGE(max)

export const CHAT_ID = /^[A-Za-z0-9_.:-]{1,128}$/
export const MESSAGE_ID = /^[A-Za-z0-9_.:-]{1,128}$/
export const DEVICE = /^[A-Za-z0-9_.-]{1,64}$/
export const MACHINE = /^[A-Za-z0-9_-]{1,64}$/
export const TEAM = /^team_[0-9a-f]{20}$/
export const HARNESS = /^[a-z0-9][a-z0-9_.-]{0,31}$/
const HOLDER = /^(?:device:[A-Za-z0-9_.-]{1,64}|vm:[A-Za-z0-9_-]{1,64})$/

export const count = (v: unknown): number | null => (typeof v === "number" && Number.isSafeInteger(v) && v >= 0 ? v : null)
export const bounded = (value: string | null, fallback: number, max: number): number => {
  const n = value === null || value === "" ? fallback : Number(value)
  return Number.isSafeInteger(n) ? Math.max(0, Math.min(n, max)) : fallback
}
/** The `holder` and `epoch` every write names, from a body or from the chunk headers. */
export const writerOf = (holder: unknown, epoch: unknown): { readonly holder: string; readonly epoch: number } | null => {
  const e = count(typeof epoch === "string" && /^\d{1,15}$/.test(epoch) ? Number(epoch) : epoch)
  return typeof holder === "string" && HOLDER.test(holder) && e !== null ? { holder, epoch: e } : null
}
export const WRITER_HELP = "holder: device:<id> or vm:<machine>; epoch: the epoch the holder last saw"
export const repoOf = (v: unknown): { readonly remote: string; readonly branch: string } | null => {
  if (v === null || typeof v !== "object" || Array.isArray(v)) return null
  const { remote, branch } = v as { remote?: unknown; branch?: unknown }
  return typeof remote === "string" && remote.length > 0 && remote.length <= 2048 && typeof branch === "string" && branch.length > 0 && branch.length <= 255 ? { remote, branch } : null
}
export const titleOf = (v: unknown): string | null => (typeof v === "string" && v.length <= 200 ? v.trim() : null)

export const hex = async (text: string): Promise<string> => [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)))].map((b) => b.toString(16).padStart(2, "0")).join("")
