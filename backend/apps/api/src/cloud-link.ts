import type { Env } from "./env.ts"

/**
 * Bind-path helpers for CloudDO (state-placement.md 5.8 items 1-2): the one-time bind token, its
 * hash, and the shape check of the bind agent's request. The token exists in plaintext only in the
 * create call that writes it into the VM and in the bind request; only its sha256 is stored.
 */

const b64u = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")

/** 32 random bytes, base64url (43 characters). */
export const newBindToken = () => b64u(crypto.getRandomValues(new Uint8Array(32)))

export const sha256Hex = async (s: string) => [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)))].map((b) => b.toString(16).padStart(2, "0")).join("")

export interface BindRequest {
  readonly team: string
  readonly machine: string
  readonly bind_token: string
  readonly wg_public_key: string
  readonly daemon: { readonly version: string; readonly capabilities: ReadonlyArray<string> }
}

const str = (v: unknown, max: number): v is string => typeof v === "string" && v.length > 0 && v.length <= max
/** Printable ASCII only: connect_info shows these strings to clients and the CLI (review P3-4). */
const printable = (v: unknown, max: number): v is string => str(v, max) && /^[\x20-\x7e]+$/.test(v)

/** A WireGuard public key: standard base64 of exactly 32 bytes. */
export const isWgKey = (v: unknown): v is string => {
  if (typeof v !== "string" || !/^[A-Za-z0-9+/]{43}=$/.test(v)) return false
  try {
    return atob(v).length === 32
  } catch {
    return false
  }
}

/** The bind agent's body, or null for any malformed field (answered validation.invalid). */
export const parseBindRequest = (body: unknown): BindRequest | null => {
  const b = (body ?? {}) as Record<string, unknown>
  const d = (b.daemon ?? {}) as Record<string, unknown>
  if (!str(b.team, 64) || !/^team_[a-z0-9]{20}$/.test(b.team)) return null
  if (!str(b.machine, 64) || !/^vm_[a-z0-9]{20}$/.test(b.machine)) return null
  if (!str(b.bind_token, 128)) return null
  if (!isWgKey(b.wg_public_key)) return null
  if (!printable(d.version, 64) || !Array.isArray(d.capabilities) || d.capabilities.length > 32 || !d.capabilities.every((c) => printable(c, 64))) return null
  return { team: b.team, machine: b.machine, bind_token: b.bind_token, wg_public_key: b.wg_public_key, daemon: { version: d.version, capabilities: d.capabilities as Array<string> } }
}

export type BindReply = { readonly ok: true; readonly value: unknown } | { readonly ok: false; readonly code: string; readonly message: string }

/** The bind body is a few hundred bytes; anything above this is refused unread (review P3-3). */
export const BIND_BODY_MAX_BYTES = 4096

/** The body as text, or null once it passes `max` bytes (stops reading there). */
const readBounded = async (request: Request, max: number): Promise<string | null> => {
  if (Number(request.headers.get("content-length") ?? 0) > max) return null
  if (!request.body) return ""
  const reader = request.body.getReader()
  const parts: Array<Uint8Array> = []
  let size = 0
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
  const all = new Uint8Array(size)
  let at = 0
  for (const p of parts) {
    all.set(p, at)
    at += p.byteLength
  }
  return new TextDecoder().decode(all)
}

const STATUS: Readonly<Record<string, number>> = { "validation.invalid": 400, "auth.forbidden": 403, "cloud.rate_limited": 429 }

/**
 * POST /v1/cloud/bind (no bearer: the one-time token is the credential). Routed to the team's
 * CloudDO, which refuses without creating an object nobody created.
 */
export const handleCloudBind = async (request: Request, env: Env): Promise<Response> => {
  const text = await readBounded(request, BIND_BODY_MAX_BYTES)
  let body: unknown = null
  try {
    body = text === null ? null : JSON.parse(text)
  } catch {}
  const parsed = parseBindRequest(body)
  if (!parsed) return Response.json({ ok: false, error: { code: "validation.invalid", message: "invalid bind request" } }, { status: 400 })
  const stub = env.CLOUD_DO.get(env.CLOUD_DO.idFromName(parsed.team)) as unknown as { bindMachine(entity: string, b: BindRequest): Promise<BindReply> }
  let r: BindReply
  try {
    r = await stub.bindMachine(parsed.team, parsed)
  } catch {
    return Response.json({ ok: false, error: { code: "owner.unreachable", message: "retry later" } }, { status: 503 })
  }
  if (r.ok) return Response.json({ ok: true, value: r.value })
  return Response.json({ ok: false, error: { code: r.code, message: r.message } }, { status: STATUS[r.code] ?? 503 })
}
