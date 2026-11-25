import { env } from "cloudflare:workers"
import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test"
import { afterEach, describe, expect, it, vi } from "vitest"
import worker from "../src/index.ts"
import { MODELS } from "../src/inference/catalog.ts"
import { signedToolId, splitToolId, toChat } from "../src/inference/messages.ts"
import { parseUsage } from "../src/inference/providers.ts"
import { SKIP_THOUGHT_SIGNATURE, withThoughtSignatures } from "../src/inference/upstream.ts"
import { paidPerson } from "./setup/inference-person.ts"

/**
 * Gemini 4 Neon on our own Vertex AI (user 2026-11-19). The Worker reaches Vertex through the
 * dashboard's keyless relay (Vercel OIDC -> GCP Workload Identity Federation); Gemini's thought
 * signatures survive a Messages client by riding in the tool_use id; reasoning tokens bill as output.
 * The relay is faked at its HTTP boundary.
 */

const NEON = "google/gemini-4-neon"
const RELAY = "https://vertex-relay.test/api/vertex/chat/completions"
const SIG = "AY89a1+u7Sa4gav2Hx/ExW7XclVB=="

const vertexEnv = (extra: Record<string, string> = {}) =>
  ({ ...env, INFERENCE_MODEL_ALLOWLIST: NEON, INFERENCE_VERTEX_RELAY_URL: RELAY, INFERENCE_VERCEL_RELAY_KEY: "relay-secret", ...extra }) as any

interface Seen {
  readonly url: string
  readonly headers: Headers
  readonly body: Record<string, any>
}

const record = (reply: () => Response) => {
  const seen: Array<Seen> = []
  const real = globalThis.fetch
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(input instanceof Request ? input.url : String(input))
    if (url.hostname !== "vertex-relay.test") return real(input, init)
    seen.push({ url: url.toString(), headers: new Headers(init?.headers), body: JSON.parse(String(init?.body ?? "{}")) })
    return reply()
  })
  return seen
}

const toolCallReply = () =>
  Response.json({
    id: "v1",
    choices: [{ index: 0, finish_reason: "tool_calls", message: { role: "assistant", tool_calls: [{ id: "call_1", type: "function", function: { name: "get_weather", arguments: '{"city":"Paris"}' }, extra_content: { google: { thought_signature: SIG } } }] } }],
    usage: { prompt_tokens: 90, completion_tokens: 22, total_tokens: 195, completion_tokens_details: { reasoning_tokens: 83 } }
  })

const send = async (t: string, path: string, body: unknown, runEnv = vertexEnv()) => {
  const ctx = createExecutionContext()
  const res = await worker.fetch!(new Request(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${t}`, "anthropic-version": "2023-06-01" }, body: JSON.stringify(body) }) as any, runEnv, ctx)
  const text = await res.text()
  await waitOnExecutionContext(ctx)
  return { status: res.status, text, headers: res.headers }
}

const TOOLS = [{ name: "get_weather", description: "Weather", input_schema: { type: "object", properties: { city: { type: "string" } } } }]

afterEach(() => {
  vi.restoreAllMocks()
})

describe("Gemini 4 Neon on our Vertex AI", () => {
  it("the catalog serves it only through Vertex, at the list price", () => {
    const neon = MODELS.find((m) => m.id === NEON)!
    expect(neon.routes.map((r) => r.provider)).toEqual(["vertex"])
    expect(neon.card).toEqual({ input: 3, output: 15 })
    expect(neon.tools).toBe(true)
  })

  it("calls the Vertex relay with the relay key and billing labels", async () => {
    const { t } = await paidPerson("vertex-relay-call")
    const seen = record(toolCallReply)
    const r = await send(t, "/v1/inference/chat/completions", { model: NEON, max_tokens: 64, messages: [{ role: "user", content: "hi" }] })
    expect(r.status).toBe(200)
    expect(r.headers.get("x-cmux-provider")).toBe("vertex")
    expect(seen).toHaveLength(1)
    expect(seen[0]!.url).toBe(RELAY)
    expect(seen[0]!.headers.get("authorization")).toBe("Bearer relay-secret")
    expect(seen[0]!.body.model).toBe(NEON)
    expect(seen[0]!.body.labels).toEqual({ cmux_service: "model-router", cmux_env: (env as unknown as { ENVIRONMENT: string }).ENVIRONMENT })
  })

  it("is unavailable when the relay is not configured", async () => {
    const { t } = await paidPerson("vertex-relay-missing")
    const seen = record(toolCallReply)
    const r = await send(t, "/v1/inference/chat/completions", { model: NEON, max_tokens: 64, messages: [{ role: "user", content: "hi" }] }, vertexEnv({ INFERENCE_VERTEX_RELAY_URL: "" }))
    expect(r.status).toBe(503)
    expect(seen).toHaveLength(0)
  })

  it("a Messages tool turn keeps the thought signature across the next request", async () => {
    const { t } = await paidPerson("vertex-messages-signature")
    const seen = record(toolCallReply)
    const first = await send(t, "/v1/inference/v1/messages", { model: NEON, max_tokens: 64, tools: TOOLS, messages: [{ role: "user", content: "Weather in Paris?" }] })
    expect(first.status).toBe(200)
    const reply = JSON.parse(first.text)
    const use = reply.content.find((b: any) => b.type === "tool_use")
    expect(use.name).toBe("get_weather")
    expect(use.id).toMatch(/^[A-Za-z0-9_-]+$/)
    expect(splitToolId(use.id)).toEqual({ id: "call_1", signature: SIG })

    // The client sends the turn back as Messages blocks; the relay must get Vertex's own id and signature.
    const second = await send(t, "/v1/inference/v1/messages", {
      model: NEON,
      max_tokens: 64,
      tools: TOOLS,
      messages: [
        { role: "user", content: "Weather in Paris?" },
        { role: "assistant", content: [use] },
        { role: "user", content: [{ type: "tool_result", tool_use_id: use.id, content: "12 C, rain" }] }
      ]
    })
    expect(second.status).toBe(200)
    const sent = seen[1]!.body.messages as Array<any>
    const assistant = sent.find((m) => m.role === "assistant")
    expect(assistant.tool_calls[0].id).toBe("call_1")
    expect(assistant.tool_calls[0].extra_content).toEqual({ google: { thought_signature: SIG } })
    expect(sent.find((m) => m.role === "tool").tool_call_id).toBe("call_1")
  })

  it("streams a tool_use block whose id carries the signature", async () => {
    const { t } = await paidPerson("vertex-messages-stream")
    const chunks = [
      { id: "s1", choices: [{ index: 0, delta: { role: "assistant", tool_calls: [{ index: 0, id: "call_9", type: "function", function: { name: "get_weather", arguments: '{"city":"Paris"}' }, extra_content: { google: { thought_signature: SIG } } }] } }] },
      { id: "s1", choices: [{ index: 0, delta: { content: "" }, finish_reason: "tool_calls" }], usage: { prompt_tokens: 90, completion_tokens: 22, total_tokens: 169 } }
    ]
    const sse = chunks.map((c) => `data: ${JSON.stringify(c)}\n\n`).join("") + "data: [DONE]\n\n"
    record(() => new Response(sse, { headers: { "content-type": "text/event-stream" } }))
    const r = await send(t, "/v1/inference/v1/messages", { model: NEON, max_tokens: 64, stream: true, tools: TOOLS, messages: [{ role: "user", content: "Weather?" }] })
    expect(r.status).toBe(200)
    const start = r.text.split("\n").find((l) => l.startsWith("data:") && l.includes('"content_block_start"') && l.includes("tool_use"))!
    const block = JSON.parse(start.slice(5)).content_block
    expect(splitToolId(block.id)).toEqual({ id: "call_9", signature: SIG })
    expect(r.text).toContain('"stop_reason":"tool_use"')
  })
})

describe("thought signatures and Gemini usage", () => {
  it("ids round-trip, and an id without a signature is unchanged", () => {
    for (const sig of [SIG, "a", "ab+/", "QUJD", "QUI=", "x".repeat(900)]) expect(splitToolId(signedToolId("call_7_with_underscores", sig))).toEqual({ id: "call_7_with_underscores", signature: sig })
    expect(signedToolId("toolu_abc", undefined)).toBe("toolu_abc")
    expect(splitToolId("toolu_abc")).toEqual({ id: "toolu_abc" })
    expect(splitToolId("gts1_999_short")).toEqual({ id: "gts1_999_short" })
  })

  it("toChat strips the signature into extra_content", () => {
    const chat = toChat({ model: NEON, max_tokens: 8, messages: [{ role: "user", content: "q" }, { role: "assistant", content: [{ type: "tool_use", id: signedToolId("c1", SIG), name: "f", input: {} }] }, { role: "user", content: [{ type: "tool_result", tool_use_id: signedToolId("c1", SIG), content: "r" }] }] }) as any
    expect(chat.messages[1].tool_calls[0]).toMatchObject({ id: "c1", extra_content: { google: { thought_signature: SIG } } })
    expect(chat.messages[2]).toMatchObject({ role: "tool", tool_call_id: "c1" })
  })

  it("toChat keeps a system message inside the thread (Claude Code 2.1.3xx)", () => {
    const chat = toChat({ model: NEON, max_tokens: 8, system: [{ type: "text", text: "top" }], messages: [{ role: "user", content: [{ type: "text", text: "q" }] }, { role: "system", content: [{ type: "text", text: "reminder" }] }] }) as any
    expect(chat.messages).toEqual([{ role: "system", content: "top" }, { role: "user", content: "q" }, { role: "system", content: "reminder" }])
    expect(toChat({ model: NEON, max_tokens: 8, messages: [{ role: "tool", content: "x" }] })).toBe("each message needs role user, assistant or system")
  })

  it("Vertex gets the placeholder when a turn's calls have no signature; other providers never see extra_content", () => {
    const messages = [{ role: "assistant", content: null, tool_calls: [{ id: "a", type: "function", function: { name: "f", arguments: "{}" } }, { id: "b", type: "function", function: { name: "g", arguments: "{}" } }] }]
    const vertex = withThoughtSignatures("vertex", messages) as Array<any>
    expect(vertex[0].tool_calls[0].extra_content).toEqual({ google: { thought_signature: SKIP_THOUGHT_SIGNATURE } })
    expect(vertex[0].tool_calls[1].extra_content).toBeUndefined()
    const signed = [{ role: "assistant", tool_calls: [{ id: "a", extra_content: { google: { thought_signature: SIG } } }] }]
    expect(withThoughtSignatures("vertex", signed)).toEqual(signed)
    expect((withThoughtSignatures("openai", signed) as Array<any>)[0].tool_calls[0]).toEqual({ id: "a" })
  })

  it("reasoning tokens outside completion_tokens bill as output", () => {
    expect(parseUsage({ prompt_tokens: 90, completion_tokens: 22, total_tokens: 195, completion_tokens_details: { reasoning_tokens: 83 } })).toEqual({ input: 90, output: 105 })
    expect(parseUsage({ prompt_tokens: 90, completion_tokens: 22, total_tokens: 112 })).toEqual({ input: 90, output: 22 })
    expect(parseUsage({ prompt_tokens: 90, completion_tokens: 22 })).toEqual({ input: 90, output: 22 })
  })
})
