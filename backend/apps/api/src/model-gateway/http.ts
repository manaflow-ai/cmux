import { Effect } from "effect"
import { claudeAuthFor, forgetClaudeAuth, HOLDER, signedFetch } from "../chief-brain/claude-auth.ts"
import { claudeModel } from "../chief-brain/models.ts"
import { costOf } from "./bedrock-price.ts"
import { Credits, CreditsLive, creditsRequired, maxCallCostUsd, payerTeam, type Reservation } from "../credits.ts"
import type { Env } from "../env.ts"
import { claudeRoute, HAIKU, isClaude, meteredOwner, offers, OPUS, SONNET } from "./routes.ts"
import { verifyRunToken, type RunGrant } from "./run-token.ts"
import type { LedgerAnswer, LedgerOp } from "./run-ledger.ts"

/**
 * The model gateway over HTTP (PROTOCOL.md `model/stream` for brains and agents outside the Worker:
 * the opencode brain, and coding agents a Chief starts on a hand):
 *
 *   POST /v1/model-gateway/v1/messages     Anthropic Messages request (stream: true) -> server-sent events
 *
 * Auth (`Authorization: Bearer` or `x-api-key`): a run token only (run-token.ts, scoped to team, chief,
 * owner and run, revoked at the run's end, capped per token). A chief token is refused here: it has no
 * per-token cap, and in-Worker brains use the gateway in process (gatewayMessages). The model is a Claude name the route
 * serves; the owner must be allowed paid models. Every request holds the call's maximum price in the
 * payer team's prepaid credits before it goes upstream and is charged its real cost (from the
 * stream's usage) when the stream ends, also when it fails or the client goes away. Errors use the
 * Anthropic error shape so stock clients show them.
 */
export const GATEWAY_PATH = /^\/v1\/model-gateway\/v1\/messages$/

const err = (status: number, type: string, message: string) => Response.json({ type: "error", error: { type, message } }, { status, headers: { "cache-control": "no-store" } })
const safeId = (s: string) => s.replace(/[^A-Za-z0-9._:-]/g, "_").slice(0, 128)
const run = <A, E>(env: Env, p: Effect.Effect<A, E, Credits>) => Effect.runPromise(p.pipe(Effect.provide(CreditsLive(env))))

export type Who = Omit<RunGrant, "conversation" | "jti" | "cap_usd" | "agent"> & { readonly conversation?: string; readonly grant?: RunGrant }
const whoOf = async (env: Env, request: Request): Promise<Who | null> => {
  const auth = request.headers.get("authorization") ?? ""
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : (request.headers.get("x-api-key") ?? "")
  if (!token) return null
  const scoped = await verifyRunToken(env, token)
  return scoped ? { ...scoped, grant: scoped } : null
}

interface Usage {
  input: number
  output: number
  cacheRead: number
  cacheWrite: number
  cacheWrite1h?: number
}

/** Reads the Messages stream's usage as it passes (message_start, message_delta); calls `end` once at the end or on cancel. */
const usageTap = (end: (u: Usage) => Promise<void>): TransformStream<Uint8Array, Uint8Array> => {
  const dec = new TextDecoder()
  const u: Usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }
  let buf = ""
  let ended = false
  const read = (block: string) => {
    const data = block.split("\n").find((l) => l.startsWith("data:"))
    if (!data) return
    try {
      const e = JSON.parse(data.slice(5)) as { type?: string; message?: { usage?: Record<string, number> & { cache_creation?: Record<string, number> } }; usage?: Record<string, number> & { cache_creation?: Record<string, number> } }
      const x = e.type === "message_start" ? e.message?.usage : e.type === "message_delta" ? e.usage : undefined
      if (!x) return
      if (typeof x.input_tokens === "number") u.input = x.input_tokens
      if (typeof x.cache_read_input_tokens === "number") u.cacheRead = x.cache_read_input_tokens
      if (typeof x.cache_creation_input_tokens === "number") u.cacheWrite = x.cache_creation_input_tokens
      if (typeof x.cache_creation?.ephemeral_1h_input_tokens === "number") u.cacheWrite1h = x.cache_creation.ephemeral_1h_input_tokens
      if (typeof x.output_tokens === "number") u.output = Math.max(u.output, x.output_tokens)
    } catch {}
  }
  const finish = (): Promise<void> => {
    if (ended) return Promise.resolve()
    ended = true
    return end(u)
  }
  return new TransformStream<Uint8Array, Uint8Array>({
    transform(chunk, out) {
      out.enqueue(chunk)
      buf += dec.decode(chunk, { stream: true })
      let at: number
      while ((at = buf.indexOf("\n\n")) >= 0) [read(buf.slice(0, at)), (buf = buf.slice(at + 2))]
    },
    // The charge is part of the response: the stream ends after the settle (a dropped promise would be lost with the request).
    async flush() {
      if (buf) read(buf)
      await finish()
    },
    cancel() {
      void finish()
    }
  } as Transformer<Uint8Array, Uint8Array> & { cancel(): void })
}

export const handleModelGateway = async (request: Request, env: Env, ctx?: { waitUntil(p: Promise<unknown>): void }): Promise<Response> => {
  if (request.method !== "POST") return err(405, "invalid_request_error", "POST only")
  const who = await whoOf(env, request)
  if (!who) return err(401, "authentication_error", "a run token is required")
  return gatewayMessages(env, who, request, ctx)
}

/**
 * The model a request runs on: Claude Code names dated or older ids (claude-haiku-4-5-20251001,
 * claude-sonnet-4-5[1m], its small/fast model) — each family maps to its 5.5 model, and a family
 * the route does not serve maps to the route's first model (staging's session route serves Opus only).
 */
const gatewayModel = (env: Env, raw: string): string => {
  const m = raw.toLowerCase().replace(/\[1m\]$/, "")
  if (!m.startsWith("claude-") && !m.includes("anthropic.claude-")) return raw
  const family = m.includes("haiku") ? HAIKU : m.includes("sonnet") ? SONNET : m.includes("opus") ? OPUS : null
  if (!family) return raw
  return offers(env, family) ? family : (claudeRoute(env).models.find((x) => offers(env, x)) ?? family)
}

/** Upstream statuses worth one more try (throttled or overloaded route; Bedrock throttles per region). */
const RETRY_STATUS = new Set([429, 503, 529])

/**
 * One Messages call for a caller the host already knows (a run token's grant, or a Worker brain such
 * as the opencode brain's container route): allow-list, the run token's ledger, credits, the route
 * (one retry on a throttled or overloaded answer), usage-based charge when the stream ends.
 */
export const gatewayMessages = async (env: Env, who: Who, request: Request, ctx?: { waitUntil(p: Promise<unknown>): void }): Promise<Response> => {
  const text = await request.text()
  let body: { model?: unknown; stream?: unknown; max_tokens?: unknown }
  try {
    body = JSON.parse(text) as typeof body
  } catch {
    return err(400, "invalid_request_error", "the body is a Messages request (JSON)")
  }
  const name = gatewayModel(env, typeof body.model === "string" ? body.model : "")
  if (!isClaude(name)) return err(400, "invalid_request_error", "this gateway serves Claude models (opus, sonnet, haiku)")
  if (body.stream !== true) return err(400, "invalid_request_error", "stream must be true")
  if (!offers(env, name) || !meteredOwner(env, who.owner)) return err(403, "permission_error", `${name} is not available for this account here`)
  const model = claudeModel(name, claudeRoute(env).url, "1h")
  const maxTokens = typeof body.max_tokens === "number" && body.max_tokens > 0 ? Math.min(body.max_tokens, 128_000) : model.maxTokens
  const team = who.team
  const request_id = safeId(`gw:${who.run}:${crypto.randomUUID()}`)
  const maxCost = maxCallCostUsd(model.cost, text.length, maxTokens)
  // A run token: its run must still run, and this call's maximum price must fit its spend cap.
  const g = who.grant
  const ledger = g ? (env.CHIEF_BRAIN_DO.get(env.CHIEF_BRAIN_DO.idFromName(`${g.chief}/${g.conversation}`)) as unknown as { runToken(run: string, jti: string, cap: number, o: LedgerOp): Promise<LedgerAnswer> }) : null
  if (g && ledger) {
    const a = await ledger.runToken(g.run, g.jti, g.cap_usd, { op: "hold", usd: maxCost, agent: g.agent }).catch(() => null)
    if (!a) return err(503, "overloaded_error", "the run could not be checked; retry")
    if (!a.ok) return a.code === "run_ended" ? err(401, "authentication_error", "this run has ended; the token no longer works") : err(429, "rate_limit_error", `this run token's model budget is spent: ${a.used_usd.toFixed(4)} of ${g.cap_usd} USD used, this call holds up to ${maxCost.toFixed(4)} USD`)
  }
  const unhold = (usd: number) => (g && ledger ? ledger.runToken(g.run, g.jti, g.cap_usd, { op: "settle", held: maxCost, usd }).catch(() => undefined) : Promise.resolve())
  let held: Reservation | null = null
  if (creditsRequired(env, name)) {
    const r = await run(env, Credits.use((c) => c.reserve({ team, request: request_id, chief: who.chief, conversation: who.conversation ?? null, maxCostUsd: maxCost })).pipe(
      Effect.map((res) => ({ ok: true as const, res })),
      Effect.catch((e: { _tag?: string; available_usd?: number; needed_usd?: number; text?: string }) => Effect.succeed({ ok: false as const, e }))
    ))
    if (!r.ok) await unhold(0)
    if (!r.ok && r.e._tag === "CreditsRateLimited") return err(429, "rate_limit_error", String(r.e.text))
    if (!r.ok) return r.e._tag === "CreditsExhausted" ? err(402, "invalid_request_error", `out of Cloud credits (available ${r.e.available_usd} USD, this call needs up to ${r.e.needed_usd} USD)`) : err(503, "overloaded_error", "credits could not be checked; retry")
    held = r.res
  }
  const settle = async (u: Usage): Promise<void> => {
    // The Bedrock price (bedrock-price.ts): 1-hour writes as the response counts them; with no split, the 1-hour rate (never short).
    const usd = costOf(name, u, "1h")?.total ?? (u.input * model.cost.input + u.output * model.cost.output + u.cacheRead * model.cost.cacheRead + u.cacheWrite * model.cost.cacheWrite) / 1_000_000
    await unhold(usd)
    if (!held) return
    const h = held
    return run(env, Credits.use((c) => c.settle(h, usd))).then(() => undefined, (e: unknown) => console.warn(JSON.stringify({ msg: "model_gateway.settle_failed", request: request_id, error: String(e).slice(0, 200) })))
  }
  const route = claudeRoute(env)
  const holder = env.CHIEF_BRAIN_DO.get(env.CHIEF_BRAIN_DO.idFromName(HOLDER)) as unknown as { claudeAuth(): Promise<string>; claudeInvalidate(): Promise<void> }
  const dropped: Array<string> = []
  const fetchRoute = signedFetch(() => claudeAuthFor(env, () => holder), () => (forgetClaudeAuth(), holder.claudeInvalidate()), { log: (w) => void dropped.push(w), forwardBetas: true, auth: route.auth, models: route.models, effortBody: route.effortBody, ...(env.CHIEF_BRAIN_CLAUDE_SERVICE_KEY ? { key: env.CHIEF_BRAIN_CLAUDE_SERVICE_KEY } : {}), ...(env.CHIEF_BRAIN_CACHE_TTL ? { ttl: env.CHIEF_BRAIN_CACHE_TTL } : {}) })
  let res: Response
  try {
    // The caller's betas go on (the Bedrock conversion maps the ones Bedrock takes and logs the rest).
    const beta = request.headers.get("anthropic-beta")
    const send = (id: string) => fetchRoute(`${route.url}/v1/messages`, { method: "POST", headers: { "content-type": "application/json", "x-cmux-team-id": team, "x-cmux-chief-id": who.chief, "x-request-id": id, ...(beta ? { "anthropic-beta": beta } : {}) }, body: JSON.stringify({ ...body, model: name }) })
    res = await send(request_id)
    if (RETRY_STATUS.has(res.status)) {
      await res.body?.cancel().catch(() => undefined)
      res = await send(`${request_id}:r1`.slice(0, 128))
    }
  } catch {
    // Not sent (the route's sign-in failed before the request): nothing to charge.
    await unhold(0)
    if (held) {
      const h = held
      await run(env, Credits.use((c) => c.release(h))).catch(() => undefined)
    }
    return err(503, "api_error", "the model route is unavailable")
  }
  if (dropped.length > 0) console.warn(JSON.stringify({ msg: "model_gateway.dropped", request: request_id, model: name, dropped: [...new Set(dropped)].slice(0, 40) }))
  if (!res.ok || !res.body) {
    await settle({ input: 0, output: 0, cacheRead: 0, cacheWrite: 0 })
    // The route's refusal text (a validation message, no secret) goes to the log and to the caller, so the next failure names the field.
    const why = (await res.text().catch(() => "")).slice(0, 1500)
    console.warn(JSON.stringify({ msg: "model_gateway.upstream_refused", request: request_id, model: name, status: res.status, body: why, dropped: [...new Set(dropped)].slice(0, 40) }))
    const detail = ((): string => {
      try {
        const j = JSON.parse(why) as { error?: { message?: unknown }; message?: unknown }
        return String(j.error?.message ?? j.message ?? why)
      } catch {
        return why
      }
    })().slice(0, 500)
    return err(res.status >= 400 && res.status < 600 ? res.status : 502, res.status === 429 ? "rate_limit_error" : res.status === 400 ? "invalid_request_error" : "api_error", `the model route answered ${res.status}${detail ? `: ${detail}` : ""}`)
  }
  // The charge outlives a client that goes away mid-stream (waitUntil), so the hold is settled, not left.
  return new Response(res.body.pipeThrough(usageTap((u) => { const p = settle(u); ctx?.waitUntil(p); return p })), { headers: { "content-type": "text/event-stream", "cache-control": "no-store" } })
}
