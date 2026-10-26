import { INFERENCE_ENTRY_PLAN } from "@cmux/protocol"
import { personalTeamIdFor } from "../domains/user.ts"
import { isMachineInstallKind } from "../machine-installs.ts"
import { authenticate } from "../auth.ts"
import { principalForOwner, selectTeam, TEAM_HEADER } from "../team-select.ts"
import { roleHas } from "../domains/team-roles.ts"

/** Grant classes that may spend (any mutation or money class). */
const SPEND_CLASSES: ReadonlySet<string> = new Set(["mutate-own", "mutate-shared", "money"])
import { nextMonthStart, userLimitMicros } from "../usage-user.ts"
import type { Env } from "../env.ts"
import { cardCost, MODELS, modelById, routeCost, type ModelEntry, type ProviderId } from "./catalog.ts"
import { providerTarget } from "./providers.ts"
import { callUpstream } from "./upstream.ts"
import { freeCaller, freeSettle, freeAdmit } from "./free.ts"
import { includedMicrosFor, includedReached } from "./included-stop.ts"
import { creditsMargin, creditsMinReserveUsd } from "../credits.ts"

const creditFloorMicros = (env: Env) => Math.ceil(creditsMinReserveUsd(env) * 1_000_000)

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
  | { readonly kind: "team"; readonly team: string; readonly user: string; readonly limitMicros: number; readonly plan?: string | null }
  /** No paid plan, but prepaid cmux credits (credits.ts): each call is held and charged on the credit ledger, never billed. */
  | { readonly kind: "credits"; readonly team: string; readonly user: string }
  | { readonly kind: "free"; readonly device: string }

/** What a 402 offers the app's missing-access card (plans/cmux-next/paid-plan.md): buy credits, bring a key, or see the plans. */
export const ACCESS_ACTIONS = ["add_credits", "add_api_key", "see_plans"] as const
const TOPUP_PATH = "/v1/credits/topup"

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
  // Cheapest first (paid-plan.md §2); sort is stable, so equal or unpriced routes keep catalog order.
  return m.routes.filter((r) => !off.has(r.provider) && providerTarget(env, r.provider) !== undefined).sort((a, b) => routeCost(a) - routeCost(b))
}

/** Outside production, `x-cmux-provider` pins one provider (per-provider staging checks); production ignores it. */
export const PROVIDER_PIN_HEADER = "x-cmux-provider"

/** Bearer token, or `x-api-key` (Messages API clients send the key there). */
const bearer = (request: Request) => {
  const h = request.headers.get("authorization") ?? ""
  if (h.toLowerCase().startsWith("bearer ")) return h.slice(7).trim()
  return request.headers.get("x-api-key")?.trim() || undefined
}

export const resolveCaller = async (env: Env, request: Request): Promise<Caller | Response> => {
  const token = bearer(request)
  if (!token) return err(401, "auth.required", "sign in, or use the free model from the app")
  const free = await freeCaller(env, token)
  if (free) return free
  const authed = await authenticate(env, token)
  if (!authed?.user || !authed.team) return err(401, "auth.invalid", "the token is not valid")
  // Team selection (x-cmux-team, a session only), checked against the team's TeamDO now.
  const selected = await selectTeam(env, { ...authed, user: authed.user, team: authed.team }, request.headers.get(TEAM_HEADER))
  if (!selected.ok) return err(selected.code === "owner.unreachable" ? 503 : 403, selected.code, selected.message, selected.code === "owner.unreachable" ? { retryable: true } : {})
  // The install as UserDO holds it now (a revoked install stops at once), and in a shared team a
  // role with team.resources (guests and billing-only members use no AI).
  const granted = await principalForOwner(env, "cloud:InferenceRouter", selected.principal).catch(() => null)
  if (granted === null) return err(503, "owner.unreachable", "team membership could not be checked; retry", { retryable: true })
  if (!granted) return err(401, "auth.invalid", "the token is not valid")
  if ("refused" in granted) return err(403, "auth.forbidden", granted.refused)
  const p = { ...granted, user: authed.user, team: selected.principal.team }
  if (p.kind === "install" && isMachineInstallKind(p.install_kind) && !switchOn(env.INFERENCE_MACHINES_ENABLED)) return err(403, "auth.forbidden", "machine installs cannot use the model router yet")
  // Spending money is a mutation: an install whose grant is read-only uses no AI (review P3). A personal
  // Cloud VM's install (kind vm) holds vm-self: it may spend, and the VM's owner (the install's user) pays.
  const spends = (c: string) => SPEND_CLASSES.has(c) || (c === "vm-self" && p.install_kind === "vm")
  if (p.kind === "install" && !(p.grant_classes ?? []).some(spends)) return err(403, "auth.forbidden", "this install's grant cannot spend on AI models")
  // A machine install acts in its bound team without team selection's lookup: check the member's role there now (review P2).
  if (p.kind === "install" && isMachineInstallKind(p.install_kind) && p.team !== personalTeamIdFor(p.user)) {
    const role = await (env.TEAM_DO.get(env.TEAM_DO.idFromName(p.team)) as unknown as { memberRole(entity: string, user: string): Promise<string | null> }).memberRole(p.team, p.user).catch(() => undefined)
    if (role === undefined) return err(503, "owner.unreachable", "team membership could not be checked; retry", { retryable: true })
    if (!roleHas(role ?? undefined, "team.resources")) return err(403, "team.not_member", "not a member of this team")
  }
  const allowed = (env.INFERENCE_ALLOWED_TEAMS ?? "").split(",").map((t) => t.trim()).filter(Boolean)
  if (allowed.length > 0 && !allowed.includes(p.team)) return err(403, "auth.forbidden", "this team cannot use the model router on this deployment yet")
  // Paid plans only (cx-ds09i): a personal team pays through its owner's personal plan, a shared
  // team through its team plan (inference/plan.ts, protocol inference-plans.ts).
  const personal = p.team === personalTeamIdFor(p.user)
  const stackUser = personal ? (p.stack_user_id ?? (await env.USER_DO.get(env.USER_DO.idFromName(p.user)).stackUserOf(p.user)) ?? undefined) : undefined
  const plan = personal && !stackUser ? ({ ok: true, paid: false } as const) : await env.TEAM_DO.get(env.TEAM_DO.idFromName(p.team)).inferencePlan(p.team, p.user, stackUser)
  if (!plan.ok) return err(503, "plan.unavailable", "the plan check is not available now; retry", { retryable: true })
  if (!plan.paid) {
    // No paid plan: prepaid cmux credits pay instead ("Use cmux credits", paid-plan.md step 1).
    const credits = await env.USAGE_METER_DO.get(env.USAGE_METER_DO.idFromName(p.team)).creditBalance(p.team, Date.now(), 0).catch(() => null)
    if (credits === null) return err(503, "credits.unavailable", "the credit balance could not be read; retry", { retryable: true })
    if (credits.available_micros > 0) return { kind: "credits", team: p.team, user: p.user }
    return err(402, "inference.plan_required", "AI models need cmux credits, your own API key, or a paid plan", { details: { plan: INFERENCE_ENTRY_PLAN, actions: ACCESS_ACTIONS, credits: { available_usd: credits.available_micros / 1_000_000, topup_path: TOPUP_PATH } } })
  }
  return { kind: "team", team: p.team, user: p.user, limitMicros: userLimitMicros(plan.user_limit_usd), plan: plan.plan ?? null }
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

/** Switch, caller and a JSON object body of at most MAX_BODY_BYTES (shared by both API shapes). */
export const admitRequest = async (env: Env, request: Request): Promise<{ caller: Caller; body: Record<string, unknown>; bytes: number } | Response> => {
  if (!switchOn(env.INFERENCE_ENABLED)) return err(503, "inference.disabled", "the model router is off on this deployment")
  const caller = await resolveCaller(env, request)
  if (caller instanceof Response) return caller
  const length = Number(request.headers.get("content-length") ?? "0")
  if (length > MAX_BODY_BYTES) return err(413, "validation.too_large", "request body is too large")
  const bytes = new Uint8Array(await request.arrayBuffer())
  if (bytes.byteLength > MAX_BODY_BYTES) return err(413, "validation.too_large", "request body is too large")
  let body: Record<string, unknown>
  try {
    body = JSON.parse(new TextDecoder().decode(bytes)) as Record<string, unknown>
  } catch {
    return err(400, "validation.invalid", "body must be JSON")
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) return err(400, "validation.invalid", "body must be a JSON object")
  return { caller, body, bytes: bytes.byteLength }
}

export const handleChatCompletions = async (env: Env, request: Request, ctx: ExecutionContext): Promise<Response> => {
  const admitted = await admitRequest(env, request)
  if (admitted instanceof Response) return admitted
  return serveChat(env, ctx, admitted.caller, admitted.body, admitted.bytes, request.headers.get(PROVIDER_PIN_HEADER))
}

/**
 * One OpenAI chat/completions request from an admitted caller. `promptBytes` bounds the prompt
 * tokens (one token is at least one byte of the request).
 */
export const serveChat = async (env: Env, ctx: ExecutionContext, caller: Caller, body: Record<string, unknown>, promptBytes: number, pin?: string | null): Promise<Response> => {
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
  const pinned = env.ENVIRONMENT !== "production" && pin ? pin : undefined
  const routes = liveRoutes(env, model).filter((r) => pinned === undefined || r.provider === pinned)
  if (pinned !== undefined && routes.length === 0) return err(400, "provider.not_on_route", `${pinned} does not serve this model on this deployment`)
  if (routes.length === 0) return err(503, "provider.unavailable", "no provider can serve this model now")

  const id = crypto.randomUUID()
  const promptBound = promptBytes
  const maxUsd = cardCost(model, Math.min(promptBound, model.context), maxTokens)
  const maxMicros = Math.ceil(maxUsd * 1_000_000)

  // Admission: the free device's own quota, or the team's monthly hard cap.
  if (caller.kind === "free") {
    const admitted = await freeAdmit(env, caller.device, id, Math.min(promptBound, model.context) + maxTokens)
    if (admitted) return admitted
  } else if (caller.kind === "credits") {
    const held = await env.USAGE_METER_DO.get(env.USAGE_METER_DO.idFromName(caller.team)).creditReserve(caller.team, `inference:${id}`, Math.max(maxMicros, creditFloorMicros(env)), null, null)
    if (!held.ok) {
      const d = "available_micros" in held ? { available_usd: held.available_micros / 1_000_000, needed_usd: held.needed_micros / 1_000_000 } : { available_usd: 0, needed_usd: maxUsd }
      return err(402, "credits.insufficient", "Not enough cmux credits for this call. Add credits or use your own API key.", { details: { ...d, plan: INFERENCE_ENTRY_PLAN, actions: ACCESS_ACTIONS, credits: { topup_path: TOPUP_PATH } } })
    }
  } else {
    const meter = env.USAGE_METER_DO.get(env.USAGE_METER_DO.idFromName(caller.team))
    const check = await meter.check(caller.team)
    if (!check.allowed) return err(402, "team.cap_reached", "the team reached its monthly usage cap")
    // The member's own monthly limit (usage-user.ts): reserved before the global lines, released at once if they refuse.
    // A team whose usage above the plan's included amount cannot be billed stops at that amount, checked in the
    // reservation's own transaction (cx-y79zh S5).
    const held = await meter.reserveUser(caller.team, caller.user, id, maxMicros, caller.limitMicros, includedMicrosFor(env, caller))
    if (!held.ok && held.included) return includedReached(held.spent_usd, held.limit_usd)
    if (!held.ok) {
      return err(402, "usage.user_limit_reached", "You reached your monthly AI spending limit for this team. A team admin can raise it.", { details: { limit_usd: held.limit_usd, spent_usd: held.spent_usd, resets_at: nextMonthStart(Date.now()) } })
    }
  }
  /**
   * The member's reservation ends: real cost, or null when no provider was billed. One UsageMeterDO
   * call writes the call's fact, the member's spend and the team's model spend in one transaction
   * (cx-y79zh S1): the limit and the team counter read the same fact.
   */
  const settleMember = (micros: number | null): Promise<unknown> => {
    if (caller.kind === "team") return env.USAGE_METER_DO.get(env.USAGE_METER_DO.idFromName(caller.team)).settleCall(caller.team, id, micros)
    if (caller.kind !== "credits") return Promise.resolve()
    // Prepaid: the hold becomes the real price (cost x margin), or is dropped when nothing was billed.
    const m = env.USAGE_METER_DO.get(env.USAGE_METER_DO.idFromName(caller.team))
    const request = `inference:${id}`
    return micros === null ? m.creditRelease(caller.team, request) : m.creditSettle(caller.team, request, Math.round(micros * creditsMargin(env)), Math.round(micros), null, null)
  }

  const upstreamBody: Record<string, unknown> = {}
  for (const k of PASS_FIELDS) if (body[k] !== undefined) upstreamBody[k] = body[k]
  upstreamBody.max_tokens = maxTokens
  if (body.stream === true) upstreamBody.stream_options = { include_usage: true }

  const tried = new Set<ProviderId>()
  let last: Response | undefined
  // Until a request goes to a provider, nothing was billed: a throw (a guard RPC, a body bug) drops
  // the member's reservation at once instead of holding it for an hour (review P2).
  let sent = false
  try {
  for (let attempt = 0; attempt < routes.length; attempt++) {
    const candidates = routes.map((r) => r.provider).filter((p) => !tried.has(p))
    const plan = await guard(env).plan(id, caller.kind === "free" ? `device:${caller.device}` : `team:${caller.team}`, candidates, maxMicros, free)
    if (!plan.ok) {
      if (caller.kind === "free") await freeSettle(env, caller.device, id, 0)
      // Nothing was billed: earlier attempts here failed before the first byte (a billed one returns above).
      await settleMember(null)
      log(env, { id, model: model.id, caller: caller.kind, status: plan.code, line: plan.line ?? null, max_usd: maxUsd })
      if (last) return last
      if (plan.code === "concurrency.limit") return err(429, "concurrency.limit", "too many requests at once; wait for one to finish", { retryable: true })
      return plan.code === "budget.exhausted" ? err(429, "budget.exhausted", "the daily model budget is used up; try again later", { retryable: true }) : err(503, plan.code, "no provider can serve this model now")
    }
    tried.add(plan.provider)
    const route = routes.find((r) => r.provider === plan.provider)!
    sent = true
    const outcome = await callUpstream(env, ctx, {
      id,
      model,
      route,
      body: upstreamBody,
      onDone: async (r) => {
        const usd = r.usage ? (r.usage.costUsd ?? cardCost(model, r.usage.input, r.usage.output)) : r.charged === "none" ? 0 : maxUsd
        if (usd > maxUsd * 1.0001) console.warn(JSON.stringify({ msg: "inference.cost_over_bound", id, model: model.id, provider: plan.provider, usd, max_usd: maxUsd }))
        // The global line and the member settle independently: one failed call never blocks the other (review P2).
        const settled = await Promise.allSettled([guard(env).settle(id, plan.provider, usd * 1_000_000, r.ttfbMs), settleMember(usd * 1_000_000)])
        for (const x of settled) if (x.status === "rejected") console.error(JSON.stringify({ msg: "inference.settle_failed", id, error: String(x.reason).slice(0, 160) }))
        if (caller.kind === "free") await freeSettle(env, caller.device, id, r.usage ? r.usage.input + r.usage.output : r.charged === "none" ? 0 : Math.min(promptBound, model.context) + maxTokens)
        log(env, { id, model: model.id, provider: plan.provider, caller: caller.kind, status: r.status, attempt, input: r.usage?.input ?? null, output: r.usage?.output ?? null, usd, priced_by: r.usage?.costUsd !== undefined ? "provider" : r.usage ? "card" : "reservation", ttfb_ms: r.ttfbMs, stream: body.stream === true })
      }
    })
    if (outcome.kind === "response") return outcome.response
    if (outcome.kind === "charged") {
      // The provider may have billed (a timeout or a broken body after the request was sent): the
      // full reservation is spent and there is no fallback, so a client cannot repeat it for free.
      ctx.waitUntil(guard(env).settle(id, plan.provider, maxMicros, null))
      ctx.waitUntil(settleMember(maxMicros))
      log(env, { id, model: model.id, provider: plan.provider, caller: caller.kind, status: "upstream.charged_failure", upstream_status: outcome.status, attempt, usd: maxUsd })
      return err(502, "upstream.failed", "the model provider failed; retry", { retryable: true })
    }
    // Failed before the first byte: drop the reservation, count the failure, try the next provider.
    // Failed before the first byte: nothing billed, so a throw in fail() itself still releases the member (review P3).
    sent = false
    await guard(env).fail(id, plan.provider)
    log(env, { id, model: model.id, provider: plan.provider, caller: caller.kind, status: "upstream.failed", upstream_status: outcome.status, attempt })
    last = err(502, "upstream.failed", "the model provider failed; retry", { retryable: true })
  }
  } catch (e) {
    if (!sent) await settleMember(null).catch(() => undefined)
    throw e
  }
  if (caller.kind === "free") await freeSettle(env, caller.device, id, 0)
  await settleMember(null)
  return last ?? err(503, "provider.unavailable", "no provider can serve this model now")
}

const log = (env: Env, fields: Record<string, unknown>) => console.log(JSON.stringify({ msg: "inference.request", environment: env.ENVIRONMENT, ...fields }))

