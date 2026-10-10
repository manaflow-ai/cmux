import type { Env } from "../env.ts"
import { admitRequest, serveChat } from "./route.ts"

/**
 * The Messages API shape on top of the model router (cx-dna4.5): POST /v1/inference/v1/messages
 * (so a client's base URL is <origin>/v1/inference) and /v1/messages/count_tokens. Requests become
 * OpenAI chat/completions and go through the same admission, caps and metering (serveChat); the
 * answer (JSON or SSE) is translated back. Agents that speak only this API (the Chief's native
 * engine, coding agents with a configurable base URL) can then use the router's models.
 *
 * Text and tools only: image and document blocks are refused (no cost bound), thinking blocks and
 * server-side tools are dropped.
 */

type Json = Record<string, unknown>

const fail = (status: number, type: string, message: string) => Response.json({ type: "error", error: { type, message } }, { status })

const text = (v: unknown): string => {
  if (typeof v === "string") return v
  if (Array.isArray(v)) return v.map((b) => (b && typeof b === "object" && (b as Json).type === "text" ? String((b as Json).text ?? "") : "")).join("")
  return ""
}

/** Messages request -> chat/completions body, or an error message. */
export const toChat = (b: Json): Json | string => {
  const messages: Array<Json> = []
  const system = text(b.system)
  if (system) messages.push({ role: "system", content: system })
  if (!Array.isArray(b.messages) || b.messages.length === 0) return "messages must be a non-empty array"
  for (const m of b.messages as Array<Json>) {
    if (!m || (m.role !== "user" && m.role !== "assistant")) return "each message needs role user or assistant"
    if (typeof m.content === "string") {
      messages.push({ role: m.role, content: m.content })
      continue
    }
    if (!Array.isArray(m.content)) return "message content must be a string or an array of blocks"
    let body = ""
    const calls: Array<Json> = []
    const results: Array<Json> = []
    for (const block of m.content as Array<Json>) {
      switch (block?.type) {
        case "text":
          body += String(block.text ?? "")
          break
        case "tool_use":
          if (m.role !== "assistant") return "tool_use blocks belong to assistant messages"
          calls.push({ id: String(block.id ?? ""), type: "function", function: { name: String(block.name ?? ""), arguments: JSON.stringify(block.input ?? {}) } })
          break
        case "tool_result":
          if (m.role !== "user") return "tool_result blocks belong to user messages"
          results.push({ role: "tool", tool_call_id: String(block.tool_use_id ?? ""), content: (block.is_error ? "Error: " : "") + text(block.content) })
          break
        case "thinking":
        case "redacted_thinking":
          break
        default:
          return `content blocks of type ${String(block?.type)} are not accepted (text and tools only)`
      }
    }
    messages.push(...results)
    if (m.role === "assistant") messages.push({ role: "assistant", content: body || null, ...(calls.length ? { tool_calls: calls } : {}) })
    else if (body) messages.push({ role: "user", content: body })
  }
  const out: Json = { model: b.model, messages, max_tokens: b.max_tokens, stream: b.stream === true }
  if (typeof b.temperature === "number") out.temperature = b.temperature
  if (typeof b.top_p === "number") out.top_p = b.top_p
  if (Array.isArray(b.stop_sequences)) out.stop = b.stop_sequences
  if (Array.isArray(b.tools)) {
    // Client tools have no `type` (or "custom"); server tools (web search and the like) are dropped.
    const tools = (b.tools as Array<Json>).filter((t) => t && (t.type === undefined || t.type === "custom"))
    if (tools.length) out.tools = tools.map((t) => ({ type: "function", function: { name: t.name, description: t.description ?? "", parameters: t.input_schema ?? { type: "object" } } }))
  }
  const tc = b.tool_choice as Json | undefined
  if (out.tools && tc?.type === "any") out.tool_choice = "required"
  else if (out.tools && tc?.type === "tool" && typeof tc.name === "string") out.tool_choice = { type: "function", function: { name: tc.name } }
  else if (out.tools && tc?.type === "none") out.tool_choice = "none"
  return out
}

const STOP: Readonly<Record<string, string>> = { stop: "end_turn", length: "max_tokens", tool_calls: "tool_use", content_filter: "refusal" }

const usageOf = (u: unknown) => {
  const x = (u ?? {}) as Json
  return { input_tokens: Number(x.prompt_tokens ?? 0), output_tokens: Number(x.completion_tokens ?? 0) }
}

const fromChatJson = (j: Json, model: unknown): Json => {
  const choice = ((j.choices as Array<Json> | undefined)?.[0] ?? {}) as Json
  const msg = (choice.message ?? {}) as Json
  const content: Array<Json> = []
  if (typeof msg.content === "string" && msg.content) content.push({ type: "text", text: msg.content })
  for (const c of (msg.tool_calls as Array<Json> | undefined) ?? []) {
    const fn = (c.function ?? {}) as Json
    let input: unknown = {}
    try {
      input = JSON.parse(String(fn.arguments ?? "{}"))
    } catch {
      input = {}
    }
    content.push({ type: "tool_use", id: String(c.id ?? `toolu_${crypto.randomUUID()}`), name: String(fn.name ?? ""), input })
  }
  return { id: `msg_${String(j.id ?? crypto.randomUUID()).replace(/^chatcmpl-/, "")}`, type: "message", role: "assistant", model, content, stop_reason: STOP[String(choice.finish_reason)] ?? "end_turn", stop_sequence: null, usage: usageOf(j.usage) }
}

/**
 * chat/completions SSE -> Messages SSE (text and tool_use blocks; reasoning is dropped). Providers
 * send each tool call's deltas in order; an interleaved provider would split a call into two blocks.
 */
const sseTranslator = (model: unknown) => {
  const enc = new TextEncoder()
  const dec = new TextDecoder()
  let pending = ""
  let started = false
  let open: { index: number; kind: "text" | "tool"; tool?: number } | undefined
  let next = 0
  let stop = "end_turn"
  let usage = { input_tokens: 0, output_tokens: 0 }
  const send = (c: TransformStreamDefaultController<Uint8Array>, event: string, data: Json) => c.enqueue(enc.encode(`event: ${event}\ndata: ${JSON.stringify({ type: event, ...data })}\n\n`))
  const close = (c: TransformStreamDefaultController<Uint8Array>) => {
    if (open) send(c, "content_block_stop", { index: open.index })
    open = undefined
  }
  const start = (c: TransformStreamDefaultController<Uint8Array>, id: unknown) => {
    if (started) return
    started = true
    send(c, "message_start", { message: { id: `msg_${String(id ?? crypto.randomUUID()).replace(/^chatcmpl-/, "")}`, type: "message", role: "assistant", model, content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 0, output_tokens: 0 } } })
  }
  const finish = (c: TransformStreamDefaultController<Uint8Array>) => {
    close(c)
    send(c, "message_delta", { delta: { stop_reason: stop, stop_sequence: null }, usage })
    send(c, "message_stop", {})
  }
  let done = false
  const chunk = (c: TransformStreamDefaultController<Uint8Array>, data: string) => {
    if (data === "[DONE]") {
      if (!done) start(c, undefined), finish(c)
      done = true
      return
    }
    let j: Json
    try {
      j = JSON.parse(data) as Json
    } catch {
      return
    }
    start(c, j.id)
    if (j.usage) usage = usageOf(j.usage)
    for (const ch of (j.choices as Array<Json> | undefined) ?? []) {
      const d = (ch.delta ?? {}) as Json
      if (typeof d.content === "string" && d.content) {
        if (open?.kind !== "text") {
          close(c)
          open = { index: next++, kind: "text" }
          send(c, "content_block_start", { index: open.index, content_block: { type: "text", text: "" } })
        }
        send(c, "content_block_delta", { index: open.index, delta: { type: "text_delta", text: d.content } })
      }
      for (const t of (d.tool_calls as Array<Json> | undefined) ?? []) {
        const k = Number(t.index ?? 0)
        const fn = (t.function ?? {}) as Json
        if (open?.kind !== "tool" || open.tool !== k) {
          close(c)
          open = { index: next++, kind: "tool", tool: k }
          send(c, "content_block_start", { index: open.index, content_block: { type: "tool_use", id: String(t.id ?? `toolu_${crypto.randomUUID()}`), name: String(fn.name ?? ""), input: {} } })
        }
        if (typeof fn.arguments === "string" && fn.arguments) send(c, "content_block_delta", { index: open.index, delta: { type: "input_json_delta", partial_json: fn.arguments } })
      }
      if (typeof ch.finish_reason === "string") stop = STOP[ch.finish_reason] ?? "end_turn"
    }
  }
  return new TransformStream<Uint8Array, Uint8Array>({
    transform(bytes, c) {
      pending += dec.decode(bytes, { stream: true })
      let nl: number
      while ((nl = pending.indexOf("\n")) >= 0) {
        const line = pending.slice(0, nl).trim()
        pending = pending.slice(nl + 1)
        if (line.startsWith("data:")) chunk(c, line.slice(5).trim())
      }
    },
    flush(c) {
      // No [DONE]: the upstream broke or sent nothing. Say so; never present a cut answer as complete.
      if (!done) {
        close(c)
        c.enqueue(enc.encode(`event: error\ndata: ${JSON.stringify({ type: "error", error: { type: "api_error", message: "the model stream ended early; retry" } })}\n\n`))
      }
    }
  })
}

const ERROR_TYPE: Readonly<Record<number, string>> = { 400: "invalid_request_error", 401: "authentication_error", 402: "billing_error", 403: "permission_error", 404: "not_found_error", 413: "request_too_large", 429: "rate_limit_error", 503: "overloaded_error" }

const fromChatError = async (r: Response): Promise<Response> => {
  const j = (await r.json().catch(() => ({}))) as { error?: { message?: string } }
  const out = fail(r.status, ERROR_TYPE[r.status] ?? "api_error", j.error?.message ?? "the request failed")
  for (const h of ["retry-after", "x-cmux-request-id"]) {
    const v = r.headers.get(h)
    if (v) out.headers.set(h, v)
  }
  return out
}

export const handleMessages = async (env: Env, request: Request, ctx: ExecutionContext): Promise<Response> => {
  const admitted = await admitRequest(env, request)
  if (admitted instanceof Response) return fromChatError(admitted)
  if (typeof admitted.body.max_tokens !== "number") return fail(400, "invalid_request_error", "max_tokens is required")
  const chat = toChat(admitted.body)
  if (typeof chat === "string") return fail(400, "invalid_request_error", chat)
  const bytes = Math.max(admitted.bytes, new TextEncoder().encode(JSON.stringify(chat)).length)
  const r = await serveChat(env, ctx, admitted.caller, chat, bytes)
  if (!r.ok) return fromChatError(r)
  const headers = { "x-cmux-request-id": r.headers.get("x-cmux-request-id") ?? "" }
  if (chat.stream === true) return new Response(r.body!.pipeThrough(sseTranslator(admitted.body.model)), { headers: { ...headers, "content-type": "text/event-stream; charset=utf-8", "cache-control": "no-cache" } })
  return Response.json(fromChatJson((await r.json()) as Json, admitted.body.model), { headers })
}

/** Token count estimate (bytes / 3, rounded up): an upper-leaning estimate; no provider call. */
export const handleCountTokens = async (env: Env, request: Request): Promise<Response> => {
  if (env.INFERENCE_FREE_IP_LIMIT && !(await env.INFERENCE_FREE_IP_LIMIT.limit({ key: request.headers.get("cf-connecting-ip") ?? "unknown" })).success) return fail(429, "rate_limit_error", "too many requests from this network")
  const admitted = await admitRequest(env, request)
  if (admitted instanceof Response) return fromChatError(admitted)
  return Response.json({ input_tokens: Math.ceil(admitted.bytes / 3) })
}
