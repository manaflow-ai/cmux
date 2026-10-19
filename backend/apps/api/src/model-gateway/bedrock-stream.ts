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
/** Anthropic betas Bedrock's InvokeModel accepts in `anthropic_beta` (others are refused there, so they are dropped and logged). */
export const BEDROCK_BETAS = new Set([
  "interleaved-thinking-2025-05-14",
  "fine-grained-tool-streaming-2025-05-14",
  "token-efficient-tools-2025-02-19",
  "context-1m-2025-08-07",
  "computer-use-2025-01-24",
  "computer-use-2025-11-24",
  "tool-examples-2025-10-29"
])

type Block = { type: string; text?: string; cache_control?: unknown }
type Msg = { role: string; content: string | Array<Block>; output_config?: unknown }

export interface BedrockBodyOptions {
  /** Keep the body's `model` (a route that serves more than one model reads it). */
  readonly keepModel?: boolean
  /** The route's id for the body's model name (service-key: the Bedrock model id). */
  readonly modelId?: (name: string) => string
  /** Send the turn's effort (`output_config`) and `thinking.display`; else Bedrock's proven minimal body. */
  readonly effort?: boolean
  /** The caller's Anthropic betas (the `anthropic-beta` header): the ones Bedrock takes go into the body's `anthropic_beta`. */
  readonly betas?: ReadonlyArray<string>
  /** Gets every field or beta the conversion drops (logged by the caller; never silent). */
  readonly dropped?: (what: string) => void
  /** Prompt cache TTL for every cache mark (default "1h"; "5m" keeps Bedrock's default). */
  readonly ttl?: string
  /** Blocks of the first user message to mark (chief-brain/cache-prefix.ts: where an earlier request wrote, and the view's last whole block); else the 5a rule. */
  readonly cacheBlocks?: ReadonlyArray<number>
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
 * survive between turns). Bedrock reads an entry only at a mark (no look-back), so the request also
 * marks where earlier requests wrote: a later call of the same turn marks the previous call's end;
 * the first user message gets the brain's marks (`cacheBlocks`: the earlier turn's entry it reads,
 * the view's last whole block it writes), or without them the 5a rule. The tools mark goes when a
 * mark needs its place (the system mark after it covers the tools as well).
 */
export const bedrockBody = (raw: string, opts: BedrockBodyOptions = {}): string => {
  try {
    const body = JSON.parse(raw) as Record<string, unknown>
    const out: Record<string, unknown> = { anthropic_version: BEDROCK_VERSION, ...Object.fromEntries(Object.entries(body).filter(([k]) => BODY_KEYS.has(k) || (opts.keepModel === true && k === "model"))) }
    for (const k of Object.keys(body)) if (!BODY_KEYS.has(k) && k !== "model" && k !== "metadata" && k !== "output_config") opts.dropped?.(`field ${k}`)
    // Anthropic betas travel in a header; Bedrock reads them from the body (`anthropic_beta`), and only the ones it knows.
    const asked = [...(opts.betas ?? []), ...(Array.isArray(body.anthropic_beta) ? (body.anthropic_beta as Array<unknown>).filter((b): b is string => typeof b === "string") : [])]
    const betas = [...new Set(asked.map((b) => b.trim()).filter(Boolean))]
    for (const b of betas.filter((b) => !BEDROCK_BETAS.has(b))) opts.dropped?.(`beta ${b}`)
    const kept = betas.filter((b) => BEDROCK_BETAS.has(b))
    if (kept.length > 0) out.anthropic_beta = kept
    if (opts.keepModel === true && typeof out.model === "string" && opts.modelId) out.model = opts.modelId(out.model)
    const messages = Array.isArray(body.messages) ? (body.messages as Array<Msg>) : []
    const system: Array<Block> = typeof body.system === "string" ? [{ type: "text", text: body.system }] : Array.isArray(body.system) ? (body.system as Array<Block>) : []
    for (const m of messages.filter((x) => x.role === "system")) system.push(...(typeof m.content === "string" ? [{ type: "text", text: m.content }] : m.content.filter((b) => b.type === "text")))
    // The active effort is the last system message's output_config (pi-ai's mid-conversation effort), else the
    // body's own output_config (a call with no system messages, as the compactor's completeSimple).
    const effort = ([...messages].reverse().find((m) => m.role === "system" && m.output_config !== undefined)?.output_config ?? body.output_config) as { effort?: unknown } | undefined
    const plain = messages.filter((x) => x.role !== "system").map(({ output_config: _drop, ...m }) => m)
    out.messages = plain
    if (system.length > 0) out.system = system
    else delete out.system
    const thinking = body.thinking as { type?: string; display?: unknown } | undefined
    if (thinking?.type === "adaptive") out.thinking = { type: "adaptive", ...(opts.effort === true && typeof thinking.display === "string" ? { display: thinking.display } : {}) }
    if (opts.effort === true && typeof effort?.effort === "string" && out.thinking) out.output_config = { effort: effort.effort }
    markCache(out, opts.ttl ?? "1h", opts.cacheBlocks)
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

const MARKABLE = new Set(["text", "image", "tool_result"])

const markCache = (out: Record<string, unknown>, ttl: string, hinted?: ReadonlyArray<number>): void => {
  const users = (out.messages as Array<Msg>).filter((m) => m.role === "user")
  const blocks = Array.isArray(users[0]?.content) ? users[0].content : []
  const marks = marksOf([out.system, out.tools, out.messages])
  const add = (b: Block | undefined, why: string) => {
    if (!b || !MARKABLE.has(b.type) || b.cache_control !== undefined) return
    if (marks.length >= MAX_MARKS) {
      // The tools mark is redundant with the system mark after it: it gives its place first.
      const tool = Array.isArray(out.tools) ? (out.tools as Array<Block>).find((t) => t.cache_control !== undefined) : undefined
      if (tool) [delete tool.cache_control, marks.splice(marks.indexOf(tool), 1)]
    }
    if (marks.length < MAX_MARKS) marks.push(Object.assign(b, { cache_control: { type: "ephemeral" } }))
    else console.warn(JSON.stringify({ msg: "bedrock_body.view_mark_skipped", why, marks: marks.length }))
  }
  // The brain's marks go on the first user message (the view) on every call of a turn, the write mark first:
  // the header lists it before the read mark, so a full request keeps the entry the next turn reads.
  const [write, ...reads] = hinted ?? []
  if (write !== undefined) add(blocks[write], "brain write mark")
  // A later call of the same turn (an assistant message after the second to last user message): the previous
  // call ended at that user message and wrote there. A message steered in before the first call is no such end.
  const msgs = out.messages as Array<Msg>
  const prev = users.length >= 2 ? users[users.length - 2] : undefined
  const earlier = prev !== undefined && msgs.slice(msgs.indexOf(prev) + 1).some((m) => m.role === "assistant")
  if (prev && earlier && Array.isArray(prev.content)) add(prev.content[prev.content.length - 1], "previous call")
  for (const k of reads) add(blocks[k], "brain read mark")
  if (write === undefined && !earlier) {
    // [frozen view blocks..., "</chat>" block, delta blocks...] (OptChat 5a): the mark goes where the previous
    // turn's request ended: its newest user block, the second to last user block of the delta. With no earlier
    // user block (the turn after a re-render), it goes on the frozen view's end.
    const end = blocks.findIndex((b) => b.type === "text" && typeof b.text === "string" && b.text.endsWith("</chat>"))
    const delta = end < 0 ? [] : blocks.slice(end + 1).filter((b) => b.type === "text" && /^\d+\+1\|user: /.test(b.text ?? ""))
    add(delta.length >= 2 ? delta[delta.length - 2] : end >= 0 ? blocks[end] : undefined, "5a")
  }
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
