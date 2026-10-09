import { MOBILE_PROTO, MOBILE_VERSION } from "@cmux/protocol"

/**
 * cmux.mobile/1 session handshake and reads on a control socket (plans/cmux-next/ios-next/a0-rpc.md
 * section 2, b1-control-do.md section 2). Shared by every OwnerDO and by HostDO's control sockets.
 */

/** Largest JSON frame a control socket accepts (an SDP offer is at most 64 KiB plus the envelope). */
export const MAX_CONTROL_FRAME = 131_072
/** Close code after a version mismatch (a0-rpc.md section 2). */
export const CLOSE_VERSION = 4002

/** What a socket negotiated; kept in its attachment so it survives hibernation. */
export interface MobileSession {
  readonly version: number
  readonly caps: ReadonlyArray<string>
  readonly client: { readonly install: string; readonly platform: string; readonly app_version: string }
}

export interface ErrorBody {
  readonly code: string
  readonly message: string
  readonly retryable: boolean
  readonly details?: unknown
}

export const sendJson = (ws: WebSocket, frame: unknown) => {
  try {
    ws.send(JSON.stringify(frame))
  } catch {}
}

export const errorFrame = (e: ErrorBody, id?: number) => ({ t: "error", ...(id === undefined ? {} : { id }), code: e.code, message: e.message, retryable: e.retryable, ...(e.details === undefined ? {} : { details: e.details }) })

const CAP = /^[a-z][a-z0-9.-]{0,63}$/
const str = (v: unknown, max: number): string | undefined => (typeof v === "string" && v.length > 0 && v.length <= max ? v : undefined)

export type HelloOutcome = { readonly ok: true; readonly session: MobileSession; readonly reply: Record<string, unknown> } | { readonly ok: false; readonly error: ErrorBody; readonly close: boolean }

/**
 * Picks the highest common version in `[min, max]` and the caps both sides list. A frame that is
 * not a valid hello is `validation.invalid` (socket stays); no common version is
 * `proto.version_unsupported` and the caller closes with 4002.
 */
export const negotiateHello = (frame: Record<string, unknown>, serverCaps: ReadonlyArray<string>, now = Date.now()): HelloOutcome => {
  const { proto, min, max, caps, client } = frame as { proto?: unknown; min?: unknown; max?: unknown; caps?: unknown; client?: Record<string, unknown> | null }
  if (proto !== MOBILE_PROTO) return { ok: false, close: true, error: { code: "proto.version_unsupported", message: `proto must be ${MOBILE_PROTO}`, retryable: false, details: { min: MOBILE_VERSION, max: MOBILE_VERSION } } }
  if (!Number.isInteger(min) || !Number.isInteger(max) || (min as number) > (max as number) || !Array.isArray(caps) || typeof client !== "object" || client === null) {
    return { ok: false, close: false, error: { code: "validation.invalid", message: "bad hello frame", retryable: false } }
  }
  const install = str(client.install, 128)
  const platform = str(client.platform, 32)
  const appVersion = str(client.app_version, 64)
  if (!install || !platform || !appVersion) return { ok: false, close: false, error: { code: "validation.invalid", message: "hello.client needs install, platform and app_version", retryable: false } }
  const version = Math.min(max as number, MOBILE_VERSION)
  if (version < (min as number) || version < 1) return { ok: false, close: true, error: { code: "proto.version_unsupported", message: `server speaks ${MOBILE_PROTO} version ${MOBILE_VERSION}`, retryable: false, details: { min: MOBILE_VERSION, max: MOBILE_VERSION } } }
  const offered = new Set((caps as Array<unknown>).filter((c): c is string => typeof c === "string" && CAP.test(c)))
  const common = serverCaps.filter((c) => offered.has(c))
  return {
    ok: true,
    session: { version, caps: common, client: { install, platform, app_version: appVersion } },
    reply: { t: "hello.ok", proto: MOBILE_PROTO, version, caps: common, server_time: now, max_frame: MAX_CONTROL_FRAME }
  }
}

/** Handles `hello` on a socket: sends `hello.ok` or `error` (closing with 4002 on a version mismatch). Returns the session or undefined. */
export const answerHello = (ws: WebSocket, frame: Record<string, unknown>, serverCaps: ReadonlyArray<string>): MobileSession | undefined => {
  const r = negotiateHello(frame, serverCaps)
  if (r.ok) {
    sendJson(ws, r.reply)
    return r.session
  }
  sendJson(ws, errorFrame(r.error))
  if (r.close) {
    try {
      ws.close(CLOSE_VERSION, r.error.code)
    } catch {}
  }
  return undefined
}

export type ReadAnswer = { readonly ok: true; readonly value: unknown; readonly revision: string } | { readonly ok: false; readonly code: string; readonly message: string; readonly retryable?: boolean; readonly details?: unknown }

/** Valid `read` frame fields, or an error to send. */
export const readFields = (frame: Record<string, unknown>): { ok: true; id: number; op: string; params: unknown } | { ok: false; error: Record<string, unknown> } => {
  const id = frame.id
  if (!Number.isInteger(id) || (id as number) < 0 || (id as number) > Number.MAX_SAFE_INTEGER) return { ok: false, error: errorFrame({ code: "validation.invalid", message: "read needs an integer id", retryable: false }) }
  if (typeof frame.op !== "string" || frame.op.length === 0 || frame.op.length > 128) return { ok: false, error: errorFrame({ code: "validation.invalid", message: "read needs an op", retryable: false }, id as number) }
  return { ok: true, id: id as number, op: frame.op, params: frame.params ?? {} }
}

/** `read.result` or `error` for one read. */
export const readReply = (id: number, r: ReadAnswer) =>
  r.ok ? { t: "read.result", id, value: r.value ?? null, revision: r.revision || "0" } : errorFrame({ code: r.code, message: r.message, retryable: r.retryable ?? false, ...(r.details === undefined ? {} : { details: r.details }) }, id)
