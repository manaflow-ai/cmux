/**
 * The metered Claude route forwards the request body to Bedrock's InvokeModelWithResponseStream as
 * is, and answers Bedrock's binary event stream. The Anthropic client speaks the Messages API over
 * server-sent events, so the signed fetch converts both ways:
 *
 * - request: Bedrock's body keys only (no `metadata`; `model` only for a multi-model route), the
 *   effort as top-level `output_config` (the Chatmux route drops it today, so effort has no effect
 *   there), `anthropic_version` bedrock-2023-05-31, 1 h cache marks, and no Anthropic beta headers
 *   (Bedrock refuses unknown ones);
 * - response: each event-stream frame's payload is `{"bytes": base64(<Messages stream event JSON>)}`,
 *   written out as `event: <type>\ndata: <json>\n\n`.
 */
const BODY_KEYS = new Set(["max_tokens", "system", "messages", "tools", "tool_choice", "temperature", "top_p", "top_k", "stop_sequences", "thinking", "stream"])
export const BEDROCK_VERSION = "bedrock-2023-05-31"

type Block = { type: string; text?: string; cache_control?: unknown }
type Msg = { role: string; content: string | Array<Block>; output_config?: unknown }

export interface BedrockBodyOptions {
  /** Keep the body's `model` (a route that serves more than one model reads it). */
  readonly keepModel?: boolean
  /** Send the turn's effort (`output_config`) and `thinking.display`; else Bedrock's proven minimal body. */
  readonly effort?: boolean
  /** Prompt cache TTL for every cache mark (default "1h"; "5m" keeps Bedrock's default). */
  readonly ttl?: string
}
/** Anthropic allows at most this many cache marks per request. */
const MAX_MARKS = 4

/**
 * The Messages request body as Bedrock takes it (JSON in, JSON out); a body that is not JSON is
 * passed through. The client's newer shape (system as a `system` role message with
 * `output_config`, adaptive thinking with extra fields) becomes the shape Bedrock validates:
 * top-level `system` blocks, plain messages, `thinking: {type: "adaptive"}`; with `effort`, also
 * `thinking.display` and the turn's effort as top-level `output_config: {effort}` (Bedrock's field for
 * adaptive Claude; the Chatmux route drops it).
 *
 * Cache: every cache mark gets the TTL (default 1 h, so the system prompt and the memory prefix
 * survive between turns), and the first user message gets one more mark at the end of its last
 * stable view piece (the block before the view's growing tail and the new messages; memory.ts
 * cutAtMarks) when the request has room for it.
 */
export const bedrockBody = (raw: string, opts: BedrockBodyOptions = {}): string => {
  try {
    const body = JSON.parse(raw) as Record<string, unknown>
    const out: Record<string, unknown> = { anthropic_version: BEDROCK_VERSION, ...Object.fromEntries(Object.entries(body).filter(([k]) => BODY_KEYS.has(k) || (opts.keepModel === true && k === "model"))) }
    const messages = Array.isArray(body.messages) ? (body.messages as Array<Msg>) : []
    const system: Array<Block> = typeof body.system === "string" ? [{ type: "text", text: body.system }] : Array.isArray(body.system) ? (body.system as Array<Block>) : []
    for (const m of messages.filter((x) => x.role === "system")) system.push(...(typeof m.content === "string" ? [{ type: "text", text: m.content }] : m.content.filter((b) => b.type === "text")))
    // The active effort is the last system message's output_config (pi-ai's mid-conversation effort).
    const effort = [...messages].reverse().find((m) => m.role === "system" && m.output_config !== undefined)?.output_config as { effort?: unknown } | undefined
    const plain = messages.filter((x) => x.role !== "system").map(({ output_config: _drop, ...m }) => m)
    out.messages = plain
    if (system.length > 0) out.system = system
    else delete out.system
    const thinking = body.thinking as { type?: string; display?: unknown } | undefined
    if (thinking?.type === "adaptive") out.thinking = { type: "adaptive", ...(opts.effort === true && typeof thinking.display === "string" ? { display: thinking.display } : {}) }
    if (opts.effort === true && typeof effort?.effort === "string" && out.thinking) out.output_config = { effort: effort.effort }
    markCache(out, opts.ttl ?? "1h")
    return JSON.stringify(out)
  } catch {
    return raw
  }
}

const marksOf = (v: unknown): Array<Block> => {
  const found: Array<Block> = []
  const walk = (x: unknown) => {
    if (Array.isArray(x)) return x.forEach(walk)
    if (x && typeof x === "object") {
      if ((x as Block).cache_control !== undefined) found.push(x as Block)
      for (const [k, y] of Object.entries(x)) if (k !== "cache_control" && typeof y === "object") walk(y)
    }
  }
  walk(v)
  return found
}

const markCache = (out: Record<string, unknown>, ttl: string): void => {
  const first = (out.messages as Array<Msg>).find((m) => m.role === "user")
  const blocks = Array.isArray(first?.content) ? first.content : []
  // [stable view pieces..., view tail, new messages]: the mark goes on the last stable piece.
  const prefix = blocks.length >= 3 ? blocks[blocks.length - 3] : undefined
  const marks = marksOf([out.system, out.tools, out.messages])
  if (prefix && prefix.type === "text" && prefix.cache_control === undefined && marks.length < MAX_MARKS) marks.push(Object.assign(prefix, { cache_control: { type: "ephemeral" } }))
  if (ttl === "5m") return
  for (const b of marks) b.cache_control = { ...(b.cache_control as object), type: "ephemeral", ttl }
}

/** Bedrock's binary event stream as Messages server-sent events. Frame CRCs are not checked (TLS covers the transport). */
export const eventStreamToSse = (body: ReadableStream<Uint8Array>): ReadableStream<Uint8Array> => {
  const enc = new TextEncoder()
  const dec = new TextDecoder()
  let buf = new Uint8Array(0)
  return body.pipeThrough(
    new TransformStream<Uint8Array, Uint8Array>({
      transform(chunk, out) {
        const next = new Uint8Array(buf.length + chunk.length)
        next.set(buf)
        next.set(chunk, buf.length)
        buf = next
        while (buf.length >= 12) {
          const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength)
          const total = view.getUint32(0)
          const headers = view.getUint32(4)
          if (total < 16 || buf.length < total) break
          const payload = buf.subarray(12 + headers, total - 4)
          buf = buf.slice(total)
          try {
            const frame = JSON.parse(dec.decode(payload)) as { bytes?: string; message?: string }
            const event = frame.bytes ? (JSON.parse(dec.decode(Uint8Array.from(atob(frame.bytes), (c) => c.charCodeAt(0)))) as { type?: string }) : { type: "error", error: { type: "api_error", message: frame.message ?? "model stream error" } }
            out.enqueue(enc.encode(`event: ${event.type ?? "error"}\ndata: ${JSON.stringify(event)}\n\n`))
          } catch {
            out.enqueue(enc.encode(`event: error\ndata: ${JSON.stringify({ type: "error", error: { type: "api_error", message: "unreadable model stream frame" } })}\n\n`))
          }
        }
      },
      flush(out) {
        if (buf.length > 0) out.enqueue(enc.encode(`event: error\ndata: ${JSON.stringify({ type: "error", error: { type: "api_error", message: "model stream ended inside a frame" } })}\n\n`))
      }
    })
  )
}
