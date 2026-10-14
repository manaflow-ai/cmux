/**
 * The metered Claude route forwards the request body to Bedrock's InvokeModelWithResponseStream as
 * is, and answers Bedrock's binary event stream. The Anthropic client speaks the Messages API over
 * server-sent events, so the signed fetch converts both ways:
 *
 * - request: Bedrock's body keys only (no `model`, no `metadata`; the effort level `output_config` has
 *   no Bedrock field, so a thinking level has no effect here), `anthropic_version`
 *   bedrock-2023-05-31, and no Anthropic beta headers (Bedrock refuses unknown ones);
 * - response: each event-stream frame's payload is `{"bytes": base64(<Messages stream event JSON>)}`,
 *   written out as `event: <type>\ndata: <json>\n\n`.
 */
const BODY_KEYS = new Set(["max_tokens", "system", "messages", "tools", "tool_choice", "temperature", "top_p", "top_k", "stop_sequences", "thinking", "stream"])
export const BEDROCK_VERSION = "bedrock-2023-05-31"

type Block = { type: string; text?: string; cache_control?: unknown }
type Msg = { role: string; content: string | Array<Block>; output_config?: unknown }

/**
 * The Messages request body as Bedrock takes it (JSON in, JSON out); a body that is not JSON is
 * passed through. The client's newer shape (system as a `system` role message with
 * `output_config`, adaptive thinking with extra fields) becomes the shape Bedrock validates:
 * top-level `system` blocks, plain messages, `thinking: {type: "adaptive"}`.
 */
export const bedrockBody = (raw: string): string => {
  try {
    const body = JSON.parse(raw) as Record<string, unknown>
    const out: Record<string, unknown> = { anthropic_version: BEDROCK_VERSION, ...Object.fromEntries(Object.entries(body).filter(([k]) => BODY_KEYS.has(k))) }
    const messages = Array.isArray(body.messages) ? (body.messages as Array<Msg>) : []
    const system: Array<Block> = typeof body.system === "string" ? [{ type: "text", text: body.system }] : Array.isArray(body.system) ? (body.system as Array<Block>) : []
    for (const m of messages.filter((x) => x.role === "system")) system.push(...(typeof m.content === "string" ? [{ type: "text", text: m.content }] : m.content.filter((b) => b.type === "text")))
    out.messages = messages.filter((x) => x.role !== "system").map(({ output_config: _drop, ...m }) => m)
    if (system.length > 0) out.system = system
    else delete out.system
    const thinking = body.thinking as { type?: string; budget_tokens?: number } | undefined
    if (thinking?.type === "adaptive") out.thinking = { type: "adaptive" }
    return JSON.stringify(out)
  } catch {
    return raw
  }
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
