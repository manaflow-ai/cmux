import type { Env } from "../env.ts"
import { personalTeamIdFor } from "../domains/user.ts"
import { Effort, ModelName } from "../chief-brain/contract.ts"
import { Schema } from "effect"

/**
 * The model gateway's routes (hq-1f PROTOCOL.md `model/stream`: Cloud brains reach models only
 * through the host, which owns keys, routes, caps and credits). Everything is configuration, so an
 * enterprise can point the gateway at its own routes; nothing here is a fixed host or key.
 *
 * - Claude (`claude-opus-5-5`, `claude-sonnet-5-5`, `claude-haiku-5-5`): a route in front of Bedrock
 *   that takes Bedrock's body and answers Bedrock's event stream (bedrock-stream.ts converts both
 *   ways). CHIEF_BRAIN_CLAUDE_URL (default: the Chatmux metered route); CHIEF_BRAIN_CLAUDE_AUTH:
 *   - `stack-session` (default; `stack` is the same): X-Stack-Auth of a signed-in person, refreshed by
 *     the holder object (claude-auth.ts);
 *   - `service-key`: the route's scoped service key (secret CHIEF_BRAIN_CLAUDE_SERVICE_KEY) as
 *     `x-api-key`, with `x-cmux-team-id` (the payer team, required), `x-cmux-chief-id`,
 *     `x-request-id` (the credits request id) and a User-Agent; the body names the Bedrock model id;
 *   - `bearer`: a generic route token (secret CHIEF_BRAIN_CLAUDE_TOKEN) as `Authorization: Bearer`.
 *   CHIEF_BRAIN_CLAUDE_MODELS: the Claude names the route serves (default: Opus for `stack-session`,
 *   all three for `service-key`).
 * - `openrouter:<vendor>/<model>`: OpenRouter with the Worker secret OPENROUTER_API_KEY;
 *   OPENROUTER_BASE_URL overrides the endpoint.
 * - `fake` and Workers AI `@cf/...` (models.ts).
 *
 * Paid models (Claude, OpenRouter) also need an owner on CHIEF_BRAIN_CLAUDE_OWNERS(+_EXTRA), the
 * deployment's daily cap and, per call, prepaid credits (gateway.ts).
 */
export const OPUS = "claude-opus-5-5"
export const SONNET = "claude-sonnet-5-5"
export const HAIKU = "claude-haiku-5-5"
export const CLAUDE_NAMES = [OPUS, SONNET, HAIKU] as const
const DEFAULT_CLAUDE_URL = "https://chatmux.dev/api/claude-david"
export const OPENROUTER_PREFIX = "openrouter:"
const DEFAULT_OPENROUTER_URL = "https://openrouter.ai/api/v1"

export const isClaude = (name: string | undefined | null): name is string => typeof name === "string" && (CLAUDE_NAMES as ReadonlyArray<string>).includes(name)
export const isOpenRouter = (name: string | undefined | null): name is string => typeof name === "string" && name.startsWith(OPENROUTER_PREFIX)
/** A model billed to a deployment account (Claude route or OpenRouter): allow-list, holder cap, never the compactor. */
export const isMetered = (name: string | undefined | null): name is string => isClaude(name) || isOpenRouter(name)

export type RouteAuth = "stack-session" | "service-key" | "bearer"
/** The Bedrock model id a `service-key` route takes in the body's `model`. */
export const BEDROCK_IDS: Readonly<Record<string, string>> = { [OPUS]: "global.anthropic.claude-opus-5-5", [SONNET]: "global.anthropic.claude-sonnet-5-5", [HAIKU]: "global.anthropic.claude-haiku-5-5" }

export interface ClaudeRoute {
  readonly url: string
  readonly auth: RouteAuth
  readonly models: ReadonlyArray<string>
  /**
   * Send effort (`output_config`) and `thinking.display` in the Bedrock body. Off by default on the
   * `stack` route: the Chatmux route drops `output_config` and the extended body is not yet proven
   * there; on by default for a `bearer` route; CHIEF_BRAIN_CLAUDE_EFFORT_BODY "1"/"0" overrides.
   */
  readonly effortBody: boolean
}
export const routeAuth = (env: Env): RouteAuth => (env.CHIEF_BRAIN_CLAUDE_AUTH === "service-key" || env.CHIEF_BRAIN_CLAUDE_AUTH === "bearer" ? env.CHIEF_BRAIN_CLAUDE_AUTH : "stack-session")
export const claudeRoute = (env: Env): ClaudeRoute => {
  const auth = routeAuth(env)
  return {
    url: env.CHIEF_BRAIN_CLAUDE_URL || DEFAULT_CLAUDE_URL,
    auth,
    models: (env.CHIEF_BRAIN_CLAUDE_MODELS || (auth === "service-key" ? CLAUDE_NAMES.join(",") : OPUS)).split(",").map((s) => s.trim()).filter(isClaude),
    // The service-key route passes effort and thinking through (1f-D, chatmux2 PR 766).
    effortBody: env.CHIEF_BRAIN_CLAUDE_EFFORT_BODY ? env.CHIEF_BRAIN_CLAUDE_EFFORT_BODY === "1" : auth !== "stack-session"
  }
}
export const openRouterUrl = (env: Env): string => env.OPENROUTER_BASE_URL || DEFAULT_OPENROUTER_URL

/** Whether the route has its credential configured (the stack secret, the service key, or the bearer token). */
export const claudeRouteReady = (env: Env): boolean => {
  const auth = routeAuth(env)
  if (auth === "service-key") return !!env.CHIEF_BRAIN_CLAUDE_SERVICE_KEY
  if (auth === "bearer") return !!env.CHIEF_BRAIN_CLAUDE_TOKEN
  try {
    const v = JSON.parse(env.CHIEF_BRAIN_CLAUDE_STACK_AUTH ?? "") as { refreshToken?: unknown }
    return typeof v.refreshToken === "string" && v.refreshToken.length > 0
  } catch {
    return false
  }
}

/** Whether this deployment can run `name` at all. */
export const offers = (env: Env, name: string): boolean => {
  if (isClaude(name)) return claudeRouteReady(env) && claudeRoute(env).models.includes(name)
  if (isOpenRouter(name)) return !!env.OPENROUTER_API_KEY
  return Schema.is(ModelName)(name)
}

/**
 * Owners whose Chiefs may run on a metered model (Claude route or OpenRouter). An entry is a user id
 * (`user_…`) or that user's personal team id (`team_…`, personalTeamIdFor), so production can list
 * people by the team ids the billing view shows.
 */
export const meteredOwner = (env: Env, owner: string | null): boolean => {
  if (owner === null || owner === "") return false
  const list = `${env.CHIEF_BRAIN_CLAUDE_OWNERS ?? ""},${env.CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA ?? ""}`.split(",").map((s) => s.trim()).filter(Boolean)
  return list.includes(owner) || list.includes(personalTeamIdFor(owner))
}

export const validModelName = (v: unknown): v is string => Schema.is(ModelName)(v)
export const validEffort = (v: unknown): boolean => Schema.is(Effort)(v)

export type Refusal = { readonly ok: false; readonly code: string; readonly message: string }

/** Why an owner's patch may not use its models here, or null (names are already valid). */
export const modelRefusal = (env: Env, owner: string, patch: { readonly model?: unknown; readonly compactor_model?: unknown }): Refusal | null => {
  // The compactor runs in the background: of the paid models only Haiku, where the route serves it and
  // the owner may use paid models (the gateway charges each compactor call to the team's credits).
  const c = patch.compactor_model
  if (typeof c === "string" && isMetered(c) && !(c === HAIKU && offers(env, c) && meteredOwner(env, owner))) return { ok: false, code: "validation.invalid", message: `the compactor cannot run on ${c} here` }
  const m = patch.model
  if (typeof m !== "string" || (!isClaude(m) && !isOpenRouter(m))) return null
  if (!offers(env, m) || !meteredOwner(env, owner))
    return { ok: false, code: isClaude(m) ? "chief_claude_unavailable" : "chief_model_unavailable", message: `${m} is not available for this account here` }
  return null
}

/** The compactor's default: CHIEF_BRAIN_COMPACTOR_MODEL (never metered), else the turn model when it is not metered, else the fallback. */
export const compactorDefault = (env: Env, turnModel: string, fallback: string): string => compactorModel(env, env.CHIEF_BRAIN_COMPACTOR_MODEL || turnModel, fallback) || "fake"

/** The compactor's model at run time: Haiku where the route serves it (charged to credits), any other paid model becomes the fallback (see modelRefusal). */
export const compactorModel = (env: Env, set: string, fallback: string): string => (set === HAIKU && offers(env, HAIKU) ? HAIKU : isMetered(set) ? (isMetered(fallback) && !(fallback === HAIKU && offers(env, HAIKU)) ? "fake" : fallback) : set)

/**
 * The model a turn runs on: `model` when it is not paid or `allowed(model)` (owner allow-list, the
 * route serves it, the deployment's daily cap; claude-auth.ts holderTurn); else the configured
 * fallback, which passes the same gate when it is paid. `model` null = no model may run (no silent
 * paid spend). `reason` says why the Chief's model was refused (shown on the run as a note step).
 */
export const pickTurnModel = async (model: string, fallback: string | undefined, allowed: (m: string) => Promise<string>): Promise<{ readonly model: string | null; readonly reason?: string }> => {
  const verdict = isMetered(model) ? await allowed(model) : "ok"
  if (verdict === "ok") return { model }
  const reason = `${model}: ${verdict}`
  // A paid Chief falls back only to a paid model the route serves and the same gate allows (Haiku):
  // never silently to a different, unmetered model (parity run 2026-10-16: a rate-limited Workers AI model).
  if (!fallback || !isMetered(fallback)) return { model: null, reason: fallback ? `${reason}; no paid fallback (${fallback} is not one)` : reason }
  const second = await allowed(fallback)
  return second === "ok" ? { model: fallback, reason } : { model: null, reason: `${reason}; ${fallback}: ${second}` }
}
