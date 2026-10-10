import { isMachineInstallKind } from "../machine-installs.ts"
import { authenticate } from "../auth.ts"
import type { Env } from "../env.ts"
import { cardCost, MODELS, modelById, type ModelEntry, type ProviderId } from "./catalog.ts"
import { providerTarget } from "./providers.ts"
import { callUpstream } from "./upstream.ts"
import { freeCaller, freeSettle, freeAdmit } from "./free.ts"

/**
 * The model router's HTTP surface (plans/cmux-next/model-router.md, cx-dna4.1):
 *   GET  /v1/inference/models            public: the models this deployment can serve now
 *   POST /v1/inference/chat/completions  OpenAI chat/completions (stream, tools)
 *   GET  /v1/inference/status            non-production only: budget lines and provider health
 *
 * A caller is a signed-in team member (Stack session or install token) or, when the free tier is
 * on, an attested device (free.ts). Prompts and outputs are never logged or stored: the request
 * log keeps id, model, provider, token counts, cost, status and timing only.
 */

export type Caller =
  | { readonly kind: "team"; readonly team: string; readonly user: string }
  | { readonly kind: "free"; readonly device: string }

const MAX_BODY_BYTES = 8 * 1024 * 1024

/** Body fields passed upstream; everything else (provider routing fields, n, logit_bias...) is dropped. */
const PASS_FIELDS = ["messages", "tools", "tool_choice", "parallel_tool_calls", "temperature", "top_p", "stop", "stream", "response_format", "seed", "frequency_penalty", "presence_penalty", "reasoning_effort"] as const

const err = (status: number, code: string, message: string, extra: Record<string, unknown> = {}) =>
  Response.json({ error: { code, message, type: status === 402 || status === 429 ? "insufficient_quota" : "invalid_request_error", ...extra } }, { status })

const switchOn = (v: string | undefined) => v === "1" || v === "true"
const disabledProviders = (env: Env) => new Set((env.INFERENCE_DISABLED_PROVIDERS ?? "").split(",").map((s) => s.trim()).filter(Boolean))

/** Providers of a model that this deployment can call now (key or binding present, not switched off). */
export const liveRoutes = (env: Env, m: ModelEntry) => {
  const off = disabledProviders(env)
  return m.routes.filter((r) => !off.has(r.provider) && providerTarget(env, r.provider) !== undefined)
}

const bearer = (request: Request) => {
  const h = request.headers.get("authorization") ?? ""
  return h.toLowerCase().startsWith("bearer ") ? h.slice(7).trim() : undefined
}

const resolveCaller = async (env: Env, request: Request): Promise<Caller | Response> => {
  const token = bearer(request)
  if (!token) return err(401, "auth.required", "sign in, or use the free model from the app")
  const free = await freeCaller(env, token)
  if (free) return free
  const p = await authenticate(env, token)
  if (!p?.user || !p.team) return err(401, "auth.invalid", "the token is not valid")
  if (p.kind === "install" && isMachineInstallKind(p.install_kind) && !switchOn(env.INFERENCE_MACHINES_ENABLED)) return err(403, "auth.forbidden", "machine installs cannot use the model router yet")
  const allowed = (env.INFERENCE_ALLOWED_TEAMS ?? "").split(",").map((t) => t.trim()).filter(Boolean)
  if (allowed.length > 0 && !allowed.includes(p.team)) return err(403, "auth.forbidden", "this team cannot use the model router on this deployment yet")
  return { kind: "team", team: p.team, user: p.user }
}

export const handleInferenceModels = (env: Env): Response => {
  const on = switchOn(env.INFERENCE_ENABLED)
  const freeOn = on && switchOn(env.INFERENCE_FREE_ENABLED)
  const data = on
    ? MODELS.filter((m) => liveRoutes(env, m).length > 0).map((m) => ({
        id: m.id,
        object: "model",
        created: 0,
        owned_by: "cmux",
        name: m.name,
        context_length: m.context,
        max_output_tokens: m.maxOutput,
        tools: m.tools,
        free: Boolean(m.free && freeOn),
        pricing: { input_per_million_usd: m.card.input, output_per_million_usd: m.card.output }
      }))
    : []
  return Response.json({ object: "list", data }, { headers: { "cache-control": "public, max-age=60" } })
}

export const handleInferenceStatus = async (env: Env, request: Request): Promise<Response> => {
  if (env.ENVIRONMENT === "production") return err(404, "not_found", "not found")
  const caller = await resolveCaller(env, request)
  if (caller instanceof Response) return caller
  return Response.json(await guard(env).status())
}

export const guard = (env: Env) => env.SPEND_GUARD_DO.get(env.SPEND_GUARD_DO.idFromName("global"))

/**
 * Message content is text only: a string, or parts of type "text". Images, files, audio and video
 * are refused, because their token cost has no bound we can compute from the body (a file part can
 * pull in a large document). Then every prompt token is at least one byte of the body, so the body
 * size bounds the prompt tokens. Tools must be plain functions (no billed server-side tools).
 */
const contentRefusal = (messages: ReadonlyArray<unknown>, tools: unknown): string | undefined => {
  for (const m of messages) {
    if (!m || typeof m !== "object") return "each message must be an object"
    const content = (m as { content?: unknown }).content
    if (content === undefined || content === null || typeof content === "string") continue
    if (!Array.isArray(content)) return "message content must be a string or an array of text parts"
    for (const part of content as Array<{ type?: unknown }>) if (part?.type !== "text") return "only text content parts are accepted"
  }
  if (tools !== undefined && (!Array.isArray(tools) || (tools as Array<{ type?: unknown }>).some((t) => t?.type !== "function"))) return "tools must be an array of function tools"
  return undefined
}

export const handleChatCompletions = async (env: Env, request: Request, ctx: ExecutionContext): Promise<Response> => {
  if (!switchOn(env.INFERENCE_ENABLED)) return err(503, "inference.disabled", "the model router is off on this deployment")
  const caller = await resolveCaller(env, request)
  if (caller instanceof Response) return caller
  const length = Number(request.headers.get("content-length") ?? "0")
  if (length > MAX_BODY_BYTES) return err(413, "validation.too_large", "request body is too large")
  const bytes = new Uint8Array(await request.arrayBuffer())
  if (bytes.byteLength > MAX_BODY_BYTES) return err(413, "validation.too_large", "request body is too large")
  const raw = new TextDecoder().decode(bytes)
  let body: Record<string, unknown>
  try {
    body = JSON.parse(raw) as Record<string, unknown>
  } catch {
    return err(400, "validation.invalid", "body must be JSON")
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) return err(400, "validation.invalid", "body must be a JSON object")
  const model = typeof body.model === "string" ? modelById(body.model) : undefined
  if (!model) return err(404, "model.not_found", "unknown model; GET /v1/inference/models lists the models")
  if (!Array.isArray(body.messages) || body.messages.length === 0) return err(400, "validation.invalid", "messages must be a non-empty array")
  if (body.tools !== undefined && !model.tools) return err(400, "validation.invalid", "this model does not take tools")
  if (body.n !== undefined && body.n !== 1) return err(400, "validation.invalid", "n must be 1")
  const refused = contentRefusal(body.messages as ReadonlyArray<unknown>, body.tools)
  if (refused) return err(400, "validation.invalid", refused)
  const requested = Number(body.max_completion_tokens ?? body.max_tokens ?? model.defaultMaxTokens)
  if (!Number.isInteger(requested) || requested < 1) return err(400, "validation.invalid", "max_tokens must be a positive integer")
  const free = caller.kind === "free"
  if (free && !model.free) return err(403, "free.model", "the free tier serves only the free models; sign in for the others")
  const maxTokens = Math.min(requested, model.maxOutput, free ? Number(env.INFERENCE_FREE_MAX_TOKENS ?? "4096") || 4096 : model.maxOutput)
  const routes = liveRoutes(env, model)
  if (routes.length === 0) return err(503, "provider.unavailable", "no provider can serve this model now")

  const id = crypto.randomUUID()
  const promptBound = bytes.byteLength
  const maxUsd = cardCost(model, Math.min(promptBound, model.context), maxTokens)
  const maxMicros = Math.ceil(maxUsd * 1_000_000)

  // Admission: the free device's own quota, or the team's monthly hard cap.
  if (caller.kind === "free") {
    const admitted = await freeAdmit(env, caller.device, Math.min(promptBound, model.context) + maxTokens)
    if (admitted) return admitted
  } else {
    const meter = env.USAGE_METER_DO.get(env.USAGE_METER_DO.idFromName(caller.team))
    const check = await meter.check(caller.team)
    if (!check.allowed) return err(402, "team.cap_reached", "the team reached its monthly usage cap")
  }

  const upstreamBody: Record<string, unknown> = {}
  for (const k of PASS_FIELDS) if (body[k] !== undefined) upstreamBody[k] = body[k]
  upstreamBody.max_tokens = maxTokens
  if (body.stream === true) upstreamBody.stream_options = { include_usage: true }

  const tried = new Set<ProviderId>()
  let last: Response | undefined
  for (let attempt = 0; attempt < routes.length; attempt++) {
    const candidates = routes.map((r) => r.provider).filter((p) => !tried.has(p))
    const plan = await guard(env).plan(id, candidates, maxMicros, free)
    if (!plan.ok) {
      log(env, { id, model: model.id, caller: caller.kind, status: plan.code, line: plan.line ?? null, max_usd: maxUsd })
      return last ?? (plan.code === "budget.exhausted" ? err(429, "budget.exhausted", "the daily model budget is used up; try again later", { retryable: true }) : err(503, plan.code, "no provider can serve this model now"))
    }
    tried.add(plan.provider)
    const route = routes.find((r) => r.provider === plan.provider)!
    const outcome = await callUpstream(env, ctx, {
      id,
      model,
      route,
      body: upstreamBody,
      onDone: async (r) => {
        const usd = r.usage ? (r.usage.costUsd ?? cardCost(model, r.usage.input, r.usage.output)) : r.charged === "none" ? 0 : maxUsd
        if (usd > maxUsd * 1.0001) console.warn(JSON.stringify({ msg: "inference.cost_over_bound", id, model: model.id, provider: plan.provider, usd, max_usd: maxUsd }))
        await guard(env).settle(id, plan.provider, usd * 1_000_000, r.ttfbMs)
        if (caller.kind === "free") await freeSettle(env, caller.device, r.usage ? r.usage.input + r.usage.output : Math.min(promptBound, model.context) + maxTokens)
        else if (usd > 0) {
          const meter = env.USAGE_METER_DO.get(env.USAGE_METER_DO.idFromName(caller.team))
          await meter.record(caller.team, [{ key: `inference:${id}`, meter: "model.spend_usd", quantity: usd, source: "coderouter", observed_at: Date.now() }])
        }
        log(env, { id, model: model.id, provider: plan.provider, caller: caller.kind, status: r.status, attempt, input: r.usage?.input ?? null, output: r.usage?.output ?? null, usd, priced_by: r.usage?.costUsd !== undefined ? "provider" : r.usage ? "card" : "reservation", ttfb_ms: r.ttfbMs, stream: body.stream === true })
      }
    })
    if (outcome.kind === "response") return outcome.response
    if (outcome.kind === "charged") {
      // The provider may have billed (a timeout or a broken body after the request was sent): the
      // full reservation is spent and there is no fallback, so a client cannot repeat it for free.
      ctx.waitUntil(guard(env).settle(id, plan.provider, maxMicros, null))
      log(env, { id, model: model.id, provider: plan.provider, caller: caller.kind, status: "upstream.charged_failure", upstream_status: outcome.status, attempt, usd: maxUsd })
      return err(502, "upstream.failed", "the model provider failed; retry", { retryable: true })
    }
    // Failed before the first byte: drop the reservation, count the failure, try the next provider.
    await guard(env).fail(id, plan.provider)
    log(env, { id, model: model.id, provider: plan.provider, caller: caller.kind, status: "upstream.failed", upstream_status: outcome.status, attempt })
    last = err(502, "upstream.failed", "the model provider failed; retry", { retryable: true })
  }
  return last ?? err(503, "provider.unavailable", "no provider can serve this model now")
}

const log = (env: Env, fields: Record<string, unknown>) => console.log(JSON.stringify({ msg: "inference.request", environment: env.ENVIRONMENT, ...fields }))

