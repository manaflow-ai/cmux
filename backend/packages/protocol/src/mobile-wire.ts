import { Schema } from "effect"
import { mobileCatalog, type MobileMessageName } from "./mobile-wire-catalog.ts"

/**
 * cmux.mobile/1 JSON frames (plans/cmux-next/ios-next/a0-rpc.md section 2; schemas/mobile-rpc).
 * Control-plane frames are the cmux.wire/1 shapes of @cmux/ownership `types.ts`; `hello`,
 * `hello.ok`, `read`, `read.result`, `signal` and `channel.*` are new. The same frames ride the
 * `rpc` channel of a CmuxLink session to the Mac. Params stay `unknown` here: each family's
 * params are checked against schemas/mobile-rpc/families/<family>.schema.json by the owner.
 */

export const MOBILE_PROTO = "cmux.mobile/1"
export const MOBILE_VERSION = 1

const Seq = Schema.Int
const Caps = Schema.Array(Schema.String)
const Origin = Schema.Literals(["user", "cli", "mcp", "script", "remote"])
const Json = Schema.Unknown
const JsonObject = Schema.Record(Schema.String, Schema.Unknown)
const Pending = Schema.Array(Schema.String)

export const MobileHello = Schema.Struct({
  t: Schema.Literal("hello"),
  proto: Schema.Literal(MOBILE_PROTO),
  min: Schema.Int,
  max: Schema.Int,
  caps: Caps,
  client: Schema.Struct({
    install: Schema.String,
    platform: Schema.String,
    app_version: Schema.String,
    build: Schema.optionalKey(Schema.String)
  }),
  resume: Schema.optionalKey(Schema.Array(Schema.Struct({ stream: Schema.String, seq: Seq })))
})

export const MobileHelloOk = Schema.Struct({
  t: Schema.Literal("hello.ok"),
  proto: Schema.Literal(MOBILE_PROTO),
  version: Schema.Int,
  caps: Caps,
  server_time: Schema.Int,
  max_frame: Schema.Int
})

export const MobileWelcome = Schema.Struct({
  t: Schema.Literal("welcome"),
  principal: Schema.Struct({ user: Schema.optionalKey(Schema.String), team: Schema.optionalKey(Schema.String), install: Schema.optionalKey(Schema.String) }),
  server_time: Schema.Int,
  streams: Schema.optionalKey(Schema.Array(Schema.String))
})

export const MobileSubscribe = Schema.Struct({
  t: Schema.Literal("subscribe"),
  stream: Schema.optionalKey(Schema.String),
  after_seq: Schema.optionalKey(Seq),
  pending: Schema.optionalKey(Pending),
  epoch: Schema.optionalKey(Schema.String)
})

export const MobileUnsubscribe = Schema.Struct({ t: Schema.Literal("unsubscribe"), stream: Schema.optionalKey(Schema.String) })

export const MobileSnapshotRequest = Schema.Struct({
  t: Schema.Literal("snapshot.request"),
  stream: Schema.optionalKey(Schema.String),
  pending: Schema.optionalKey(Pending)
})

export const MobileOp = Schema.Struct({
  t: Schema.Literal("op"),
  op: Schema.String,
  params: Json,
  idempotency_key: Schema.String,
  origin: Schema.optionalKey(Origin),
  expected_revision: Schema.optionalKey(Schema.String),
  stream: Schema.optionalKey(Schema.String)
})

export const MobileRead = Schema.Struct({ t: Schema.Literal("read"), id: Schema.Int, op: Schema.String, params: Json, stream: Schema.optionalKey(Schema.String) })

export const MobileReadResult = Schema.Struct({ t: Schema.Literal("read.result"), id: Schema.Int, value: Json, revision: Schema.String })

export const MobileResult = Schema.Struct({
  t: Schema.Literal("result"),
  tx: Schema.String,
  idempotency_key: Schema.String,
  value: Json,
  revision: Schema.String,
  replayed: Schema.Boolean
})

export const MobileReject = Schema.Struct({
  t: Schema.Literal("reject"),
  tx: Schema.String,
  idempotency_key: Schema.String,
  code: Schema.String,
  message: Schema.String,
  details: Schema.optionalKey(Json),
  retryable: Schema.Boolean,
  replayed: Schema.Boolean
})

export const MobileSettled = Schema.Struct({
  t: Schema.Literal("request-settled"),
  tx: Schema.String,
  idempotency_key: Schema.String,
  stream: Schema.String,
  sequence: Seq,
  ok: Schema.Boolean
})

export const MobileEvent = Schema.Struct({
  t: Schema.Literal("event"),
  stream: Schema.String,
  seq: Seq,
  tx: Schema.String,
  op: Schema.String,
  params: Json,
  actor: JsonObject,
  origin: Origin,
  at: Schema.Int,
  effects: Schema.optionalKey(Json),
  epoch: Schema.optionalKey(Schema.String)
})

export const MobileSnapshot = Schema.Struct({
  t: Schema.Literal("snapshot"),
  stream: Schema.String,
  seq: Seq,
  state: Json,
  decided: Schema.Array(Schema.Struct({ idempotency_key: Schema.String, ok: Schema.Boolean, sequence: Seq })),
  rows: Schema.optionalKey(Json),
  epoch: Schema.optionalKey(Schema.String)
})

export const MobilePresenceSet = Schema.Struct({
  t: Schema.Literal("presence.set"),
  state: Schema.Struct({ active: Schema.Boolean, client: Schema.String })
})

export const SignalKind = Schema.Literals(["offer", "answer", "ice", "ice.end", "bye"])
export type SignalKind = typeof SignalKind.Type

/** Ephemeral, relayed by HostDO and never stored. The relay overwrites `from` with the sender's install. */
export const MobileSignal = Schema.Struct({
  t: Schema.Literal("signal"),
  kind: SignalKind,
  session: Schema.String,
  to: Schema.String,
  from: Schema.optionalKey(Schema.String),
  body: JsonObject
})

export const MobileError = Schema.Struct({
  t: Schema.Literal("error"),
  id: Schema.optionalKey(Schema.Int),
  code: Schema.String,
  message: Schema.String,
  retryable: Schema.Boolean,
  details: Schema.optionalKey(Json)
})

export const ChannelKind = Schema.Literals(["rpc", "terminal", "browser", "rd", "files.upload", "files.download"])
export type ChannelKind = typeof ChannelKind.Type
export const ChannelClass = Schema.Literals(["interactive", "bulk", "datagram"])
export type ChannelClass = typeof ChannelClass.Type

export const MobileChannelOpen = Schema.Struct({
  t: Schema.Literal("channel.open"),
  channel: Schema.Int,
  kind: ChannelKind,
  class: ChannelClass,
  window: Schema.Int,
  params: JsonObject,
  resume: Schema.optionalKey(Schema.Struct({ recv_seq: Seq }))
})

export const MobileChannelOpened = Schema.Struct({
  t: Schema.Literal("channel.opened"),
  channel: Schema.Int,
  window: Schema.Int,
  params: JsonObject,
  resumed: Schema.Boolean
})

export const MobileChannelRefused = Schema.Struct({
  t: Schema.Literal("channel.refused"),
  channel: Schema.Int,
  code: Schema.String,
  message: Schema.String,
  retryable: Schema.Boolean,
  details: Schema.optionalKey(Json)
})

export const MobileChannelClose = Schema.Struct({
  t: Schema.Literal("channel.close"),
  channel: Schema.Int,
  code: Schema.optionalKey(Schema.String),
  message: Schema.optionalKey(Schema.String)
})

export const MobileChannelClosed = Schema.Struct({
  t: Schema.Literal("channel.closed"),
  channel: Schema.Int,
  code: Schema.optionalKey(Schema.String),
  message: Schema.optionalKey(Schema.String)
})

export const MobileFrame = Schema.Union([
  MobileHello,
  MobileHelloOk,
  MobileWelcome,
  MobileSubscribe,
  MobileUnsubscribe,
  MobileSnapshotRequest,
  MobileOp,
  MobileRead,
  MobileReadResult,
  MobileResult,
  MobileReject,
  MobileSettled,
  MobileEvent,
  MobileSnapshot,
  MobilePresenceSet,
  MobileSignal,
  MobileError,
  MobileChannelOpen,
  MobileChannelOpened,
  MobileChannelRefused,
  MobileChannelClose,
  MobileChannelClosed
])
export type MobileFrame = typeof MobileFrame.Type

/** Every envelope `t`. A JSON record whose `t` is not one of these is a channel message. */
export const mobileFrameTypes = [
  "hello", "hello.ok", "welcome", "subscribe", "unsubscribe", "snapshot.request", "op", "read", "read.result", "result",
  "reject", "request-settled", "event", "snapshot", "presence.set", "signal", "error",
  "channel.open", "channel.opened", "channel.refused", "channel.close", "channel.closed"
] as const satisfies ReadonlyArray<MobileFrame["t"]>

/** A JSON record on a channel whose `t` names a catalog `message` (for example `terminal.viewport`). */
export interface MobileChannelMessage {
  readonly t: MobileMessageName
  readonly body: Readonly<Record<string, unknown>>
}

export type MobileJson = { readonly frame: MobileFrame } | { readonly message: MobileChannelMessage }

const decodeFrame = Schema.decodeUnknownSync(MobileFrame)
const encodeFrame = Schema.encodeSync(MobileFrame)
const frameTypes = new Set<string>(mobileFrameTypes)
const channelMessages = new Set<string>(mobileCatalog.families.flatMap((f) => f.messages.filter((m) => m.kind === "message").map((m) => m.name)))

export class MobileWireError extends Error {
  constructor(readonly code: string, message: string) {
    super(message)
  }
}

/** Decodes one envelope frame; throws `MobileWireError` (`proto.unknown_frame`, `validation.invalid`). */
export const decodeMobileFrame = (json: unknown): MobileFrame => {
  const t = typeof json === "object" && json !== null ? (json as { t?: unknown }).t : undefined
  if (typeof t !== "string" || !frameTypes.has(t)) throw new MobileWireError("proto.unknown_frame", `unknown frame ${String(t)}`)
  try {
    return decodeFrame(json)
  } catch (e) {
    throw new MobileWireError("validation.invalid", `bad ${t} frame: ${(e as Error).message}`)
  }
}

export const encodeMobileFrame = (frame: MobileFrame): Record<string, unknown> => encodeFrame(frame) as Record<string, unknown>

/** Decodes any JSON record of either plane: an envelope frame or a catalog channel message. */
export const decodeMobileJson = (json: unknown): MobileJson => {
  const o = typeof json === "object" && json !== null && !Array.isArray(json) ? (json as Record<string, unknown>) : undefined
  const t = o?.t
  if (o && typeof t === "string" && !frameTypes.has(t) && channelMessages.has(t)) {
    const { t: _t, ...body } = o
    return { message: { t: t as MobileMessageName, body } }
  }
  return { frame: decodeMobileFrame(json) }
}

export const encodeMobileJson = (value: MobileJson): Record<string, unknown> =>
  "frame" in value ? encodeMobileFrame(value.frame) : { ...value.message.body, t: value.message.t }

/** The catalog message a frame carries (`op`/`read`/`event` op, `channel.open` kind, `signal.<kind>`), if any. */
export const mobileMessageOf = (frame: MobileFrame): string | undefined => {
  switch (frame.t) {
    case "op":
    case "read":
    case "event":
      return frame.op
    case "channel.open":
      return frame.kind
    case "signal":
      return `signal.${frame.kind}`
    default:
      return undefined
  }
}
