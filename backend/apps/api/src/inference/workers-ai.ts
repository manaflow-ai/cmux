import type { ModelEntry } from "./catalog.ts"
import { parseUsage, type UpstreamUsage } from "./providers.ts"

/**
 * Workers AI through the AI binding. The binding answers in one of three shapes depending on the
 * model: OpenAI chat completions (`choices`), the Responses API (`output`), or the classic
 * Workers AI shape (`response` + `tool_calls`). Each becomes one OpenAI chat completion. A
 * streaming client gets that completion as SSE chunks (one content chunk, one usage chunk,
 * [DONE]), so every provider looks the same to the client. The call itself is not streamed.
 */

interface ToolCallOut {
  readonly id: string
  readonly type: "function"
  readonly function: { readonly name: string; readonly arguments: string }
}

interface Completion {
  readonly content: string | null
  readonly reasoning?: string
  readonly toolCalls: ReadonlyArray<ToolCallOut>
  readonly finish: string
  readonly usage?: UpstreamUsage
}

const str = (v: unknown) => (typeof v === "string" ? v : undefined)
const callId = (i: number) => `call_${crypto.randomUUID().replace(/-/g, "").slice(0, 20)}${i}`
const args = (v: unknown) => (typeof v === "string" ? v : JSON.stringify(v ?? {}))

const fromAny = (raw: unknown): Completion | undefined => {
  if (!raw || typeof raw !== "object") return undefined
  const r = raw as Record<string, unknown>
  const usage = parseUsage(r.usage) ?? (r.usage && typeof r.usage === "object" ? fromResponsesUsage(r.usage as Record<string, unknown>) : undefined)
  if (Array.isArray(r.choices)) {
    const msg = ((r.choices[0] as Record<string, unknown> | undefined)?.message ?? {}) as Record<string, unknown>
    const calls = Array.isArray(msg.tool_calls) ? (msg.tool_calls as Array<Record<string, unknown>>) : []
    return {
      content: str(msg.content) ?? null,
      ...(str(msg.reasoning_content) ? { reasoning: str(msg.reasoning_content)! } : {}),
      toolCalls: calls.map((c, i) => {
        const fn = (c.function ?? {}) as Record<string, unknown>
        return { id: str(c.id) ?? callId(i), type: "function", function: { name: str(fn.name) ?? "", arguments: args(fn.arguments) } }
      }),
      finish: str((r.choices[0] as Record<string, unknown> | undefined)?.finish_reason) ?? (calls.length ? "tool_calls" : "stop"),
      ...(usage ? { usage } : {})
    }
  }
  if (Array.isArray(r.output)) {
    let content = ""
    let reasoning = ""
    const toolCalls: Array<ToolCallOut> = []
    for (const item of r.output as Array<Record<string, unknown>>) {
      if (item.type === "function_call") toolCalls.push({ id: str(item.call_id) ?? callId(toolCalls.length), type: "function", function: { name: str(item.name) ?? "", arguments: args(item.arguments) } })
      const parts = Array.isArray(item.content) ? (item.content as Array<Record<string, unknown>>) : []
      for (const p of parts) {
        if (item.type === "message" && typeof p.text === "string") content += p.text
        if (item.type === "reasoning" && typeof p.text === "string") reasoning += p.text
      }
    }
    return { content: content || null, ...(reasoning ? { reasoning } : {}), toolCalls, finish: toolCalls.length ? "tool_calls" : "stop", ...(usage ? { usage } : {}) }
  }
  if ("response" in r || "tool_calls" in r) {
    const calls = Array.isArray(r.tool_calls) ? (r.tool_calls as Array<Record<string, unknown>>) : []
    return {
      content: str(r.response) ?? null,
      toolCalls: calls.map((c, i) => ({ id: str(c.id) ?? callId(i), type: "function", function: { name: str(c.name) ?? "", arguments: args(c.arguments) } })),
      finish: calls.length ? "tool_calls" : "stop",
      ...(usage ? { usage } : {})
    }
  }
  return undefined
}

const fromResponsesUsage = (u: Record<string, unknown>): UpstreamUsage | undefined =>
  typeof u.input_tokens === "number" && typeof u.output_tokens === "number" ? { input: u.input_tokens, output: u.output_tokens } : undefined

/** The fields Workers AI chat models take. */
const workersAiInput = (body: Record<string, unknown>) => {
  const out: Record<string, unknown> = { messages: body.messages }
  for (const k of ["tools", "tool_choice", "temperature", "top_p", "max_tokens", "seed", "frequency_penalty", "presence_penalty", "response_format", "reasoning_effort"]) {
    if (body[k] !== undefined) out[k] = body[k]
  }
  if (out.reasoning_effort !== undefined) out.reasoning = { effort: out.reasoning_effort }
  return out
}

export interface WorkersAiResult {
  readonly response: Response
  readonly usage?: UpstreamUsage
}

/** Runs the model and answers an OpenAI-shaped response (JSON, or SSE when `stream`). Throws on an upstream error. */
export const runWorkersAi = async (ai: Ai, model: ModelEntry, providerModel: string, body: Record<string, unknown>, requestId: string): Promise<WorkersAiResult> => {
  const raw = await (ai.run as (m: string, i: unknown) => Promise<unknown>)(providerModel, workersAiInput(body))
  const c = fromAny(raw)
  if (!c) throw new Error("workers-ai: unrecognized answer shape")
  const created = Math.floor(Date.now() / 1000)
  const message = { role: "assistant", content: c.content, ...(c.reasoning ? { reasoning: c.reasoning } : {}), ...(c.toolCalls.length ? { tool_calls: c.toolCalls } : {}) }
  const usage = c.usage ? { prompt_tokens: c.usage.input, completion_tokens: c.usage.output, total_tokens: c.usage.input + c.usage.output } : undefined
  const base = { id: `chatcmpl-${requestId}`, created, model: model.id }
  if (body.stream !== true) {
    return { response: Response.json({ ...base, object: "chat.completion", choices: [{ index: 0, message, finish_reason: c.finish }], ...(usage ? { usage } : {}) }), ...(c.usage ? { usage: c.usage } : {}) }
  }
  const delta = { role: "assistant", content: c.content ?? "", ...(c.reasoning ? { reasoning: c.reasoning } : {}), ...(c.toolCalls.length ? { tool_calls: c.toolCalls.map((t, index) => ({ index, ...t })) } : {}) }
  const chunks = [
    { ...base, object: "chat.completion.chunk", choices: [{ index: 0, delta, finish_reason: null }] },
    { ...base, object: "chat.completion.chunk", choices: [{ index: 0, delta: {}, finish_reason: c.finish }] },
    ...(usage ? [{ ...base, object: "chat.completion.chunk", choices: [], usage }] : [])
  ]
  const text = chunks.map((x) => `data: ${JSON.stringify(x)}\n\n`).join("") + "data: [DONE]\n\n"
  return { response: new Response(text, { headers: { "content-type": "text/event-stream; charset=utf-8", "cache-control": "no-cache" } }), ...(c.usage ? { usage: c.usage } : {}) }
}
