import { Effect } from "effect"
import { authenticate } from "../auth.ts"
import { HOLDER, signedFetch } from "../chief-brain/claude-auth.ts"
import { claudeModel } from "../chief-brain/models.ts"
import { Credits, CreditsLive, creditsRequired, maxCallCostUsd, payerTeam, type Reservation } from "../credits.ts"
import type { Env } from "../env.ts"
import { claudeRoute, isClaude, meteredOwner, offers } from "./routes.ts"
import { verifyRunToken, type RunScope } from "./run-token.ts"

/**
 * The model gateway over HTTP (PROTOCOL.md `model/stream` for brains and agents outside the Worker:
 * the opencode brain, and coding agents a Chief starts on a hand):
 *
 *   POST /v1/model-gateway/v1/messages     Anthropic Messages request (stream: true) -> server-sent events
 *
 * Auth (`Authorization: Bearer` or `x-api-key`): a run token (run-token.ts, scoped to team, chief, owner
 * and run) or a chief token (the chief acting for its owner). The model is a Claude name the route
 * serves; the owner must be allowed paid models. Every request holds the call's maximum price in the
 * payer team's prepaid credits before it goes upstream and is charged its real cost (from the
 * stream's usage) when the stream ends, also when it fails or the client goes away. Errors use the
 * Anthropic error shape so stock clients show them.
 */
export const GATEWAY_PATH = /^\/v1\/model-gateway\/v1\/messages$/

const err = (status: number, type: string, message: string) => Response.json({ type: "error", error: { type, message } }, { status, headers: { "cache-control": "no-store" } })
const safeId = (s: string) => s.replace(/[^A-Za-z0-9._:-]/g, "_").slice(0, 128)
const run = <A, E>(env: Env, p: Effect.Effect<A, E, Credits>) => Effect.runPromise(p.pipe(Effect.provide(CreditsLive(env))))

const whoOf = async (env: Env, request: Request): Promise<RunScope | null> => {
  const auth = request.headers.get("authorization") ?? ""
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : (request.headers.get("x-api-key") ?? "")
  if (!token) return null
  const scoped = await verifyRunToken(env, token)
  if (scoped) return scoped
  const p = await authenticate(env, token).catch(() => undefined)
  return p?.user && p.agent ? { team: payerTeam(p.user), chief: p.agent, owner: p.user, run: "chief" } : null
}

interface Usage {
  input: number
  output: number
  cacheRead: number
  cacheWrite: number
}

/** Reads the Messages stream's usage as it passes (message_start, message_delta); calls `end` once at the end or on cancel. */
const usageTap = (end: (u: Usage) => void): TransformStream<Uint8Array, Uint8Array> => {
  const dec = new TextDecoder()
  const u: Usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }
  let buf = ""
  let ended = false
  const read = (block: string) => {
    const data = block.split("\n").find((l) => l.startsWith("data:"))
    if (!data) return
    try {
      const e = JSON.parse(data.slice(5)) as { type?: string; message?: { usage?: Record<string, number> }; usage?: Record<string, number> }
      const x = e.type === "message_start" ? e.message?.usage : e.type === "message_delta" ? e.usage : undefined
      if (!x) return
      if (typeof x.input_tokens === "number") u.input = x.input_tokens
      if (typeof x.cache_read_input_tokens === "number") u.cacheRead = x.cache_read_input_tokens
      if (typeof x.cache_creation_input_tokens === "number") u.cacheWrite = x.cache_creation_input_tokens
      if (typeof x.output_tokens === "number") u.output = Math.max(u.output, x.output_tokens)
    } catch {}
  }
  const finish = () => {
    if (!ended) [(ended = true), end(u)]
  }
  return new TransformStream<Uint8Array, Uint8Array>({
    transform(chunk, out) {
      out.enqueue(chunk)
      buf += dec.decode(chunk, { stream: true })
      let at: number
      while ((at = buf.indexOf("\n\n")) >= 0) [read(buf.slice(0, at)), (buf = buf.slice(at + 2))]
    },
    flush() {
      if (buf) read(buf)
      finish()
    },
    cancel() {
      finish()
    }
  } as Transformer<Uint8Array, Uint8Array> & { cancel(): void })
}

export const handleModelGateway = async (request: Request, env: Env): Promise<Response> => {
  if (request.method !== "POST") return err(405, "invalid_request_error", "POST only")
  const who = await whoOf(env, request)
  if (!who) return err(401, "authentication_error", "a run token or chief token is required")
  const text = await request.text()
  let body: { model?: unknown; stream?: unknown; max_tokens?: unknown }
  try {
    body = JSON.parse(text) as typeof body
  } catch {
    return err(400, "invalid_request_error", "the body is a Messages request (JSON)")
  }
  const name = typeof body.model === "string" ? body.model.replace(/\[1m\]$/, "") : ""
  if (!isClaude(name)) return err(400, "invalid_request_error", "this gateway serves claude-opus-5-5, claude-sonnet-5-5 and claude-haiku-5-5")
  if (body.stream !== true) return err(400, "invalid_request_error", "stream must be true")
  if (!offers(env, name) || !meteredOwner(env, who.owner)) return err(403, "permission_error", `${name} is not available for this account here`)
  const model = claudeModel(name, claudeRoute(env).url)
  const maxTokens = typeof body.max_tokens === "number" && body.max_tokens > 0 ? Math.min(body.max_tokens, 128_000) : model.maxTokens
  const team = who.team
  const request_id = safeId(`gw:${who.run}:${crypto.randomUUID()}`)
  let held: Reservation | null = null
  if (creditsRequired(env, name)) {
    const r = await run(env, Credits.use((c) => c.reserve({ team, request: request_id, chief: who.chief, conversation: who.conversation ?? null, maxCostUsd: maxCallCostUsd(model.cost, text.length, maxTokens) })).pipe(
      Effect.map((res) => ({ ok: true as const, res })),
      Effect.catch((e: { _tag?: string; available_usd?: number; needed_usd?: number }) => Effect.succeed({ ok: false as const, e }))
    ))
    if (!r.ok) return r.e._tag === "CreditsExhausted" ? err(402, "invalid_request_error", `out of Cloud credits (available ${r.e.available_usd} USD, this call needs up to ${r.e.needed_usd} USD)`) : err(503, "overloaded_error", "credits could not be checked; retry")
    held = r.res
  }
  const settle = (u: Usage) => {
    if (!held) return Promise.resolve()
    const usd = (u.input * model.cost.input + u.output * model.cost.output + u.cacheRead * model.cost.cacheRead + u.cacheWrite * model.cost.cacheWrite) / 1_000_000
    const h = held
    return run(env, Credits.use((c) => c.settle(h, usd))).catch((e: unknown) => console.warn(JSON.stringify({ msg: "model_gateway.settle_failed", request: request_id, error: String(e).slice(0, 200) })))
  }
  const route = claudeRoute(env)
  const holder = env.CHIEF_BRAIN_DO.get(env.CHIEF_BRAIN_DO.idFromName(HOLDER)) as unknown as { claudeAuth(): Promise<string>; claudeInvalidate(): Promise<void> }
  const fetchRoute = signedFetch(() => holder.claudeAuth(), () => holder.claudeInvalidate(), { auth: route.auth, models: route.models, effortBody: route.effortBody, ...(env.CHIEF_BRAIN_CLAUDE_SERVICE_KEY ? { key: env.CHIEF_BRAIN_CLAUDE_SERVICE_KEY } : {}), ...(env.CHIEF_BRAIN_CACHE_TTL ? { ttl: env.CHIEF_BRAIN_CACHE_TTL } : {}) })
  let res: Response
  try {
    res = await fetchRoute(`${route.url}/v1/messages`, { method: "POST", headers: { "content-type": "application/json", "x-cmux-team-id": team, "x-cmux-chief-id": who.chief, "x-request-id": request_id }, body: JSON.stringify({ ...body, model: name }) })
  } catch {
    // Not sent (the route's sign-in failed before the request): nothing to charge.
    if (held) {
      const h = held
      await run(env, Credits.use((c) => c.release(h))).catch(() => undefined)
    }
    return err(503, "api_error", "the model route is unavailable")
  }
  if (!res.ok || !res.body) {
    await settle({ input: 0, output: 0, cacheRead: 0, cacheWrite: 0 })
    return err(res.status >= 400 && res.status < 600 ? res.status : 502, res.status === 429 ? "rate_limit_error" : "api_error", `the model route answered ${res.status}`)
  }
  return new Response(res.body.pipeThrough(usageTap((u) => void settle(u))), { headers: { "content-type": "text/event-stream", "cache-control": "no-store" } })
}
