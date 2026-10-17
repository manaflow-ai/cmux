import { createModels, createProvider, type MutableModels } from "@earendil-works/pi-ai/models"
import type { Api, Model, ModelThinkingLevel } from "@earendil-works/pi-ai"
import { anthropicMessagesApi } from "@earendil-works/pi-ai/api/anthropic-messages.lazy"
import { openAICompletionsApi } from "@earendil-works/pi-ai/api/openai-completions.lazy"
import { ANTHROPIC_MODELS } from "@earendil-works/pi-ai/providers/anthropic.models"
import { OPENROUTER_MODELS } from "@earendil-works/pi-ai/providers/openrouter.models"
import { createAI } from "agents/models/pi-ai"
import type { Env } from "../env.ts"
import { liveOf } from "./brain-stream.ts"
import { type GatewayHooks, type GatewayWho, ModelGatewayLive } from "../model-gateway/gateway.ts"
import { signedFetch } from "./claude-auth.ts"
import { DEFAULT_EFFORT } from "./contract.ts"
import { fakeStreams } from "./fake.ts"
import { claudeRoute, compactorDefault, compactorModel, isClaude, isMetered, isOpenRouter, modelRefusal, OPENROUTER_PREFIX, openRouterUrl, OPUS, pickTurnModel, validModelName } from "../model-gateway/routes.ts"

export { compactorDefault, compactorModel, isClaude, isMetered, liveOf, modelRefusal, pickTurnModel, validModelName }
export { creditsCanStart, creditsNotice, gatewayOptions, turnFailedNotice } from "./brain-gateway.ts"

/**
 * The Chief brain's models (routes and their configuration: model-routes.ts). A model name is
 * `fake` (the deterministic in-process model of fake.ts: tests and offline runs), a Workers AI id
 * `@cf/...` run through the Worker's own AI binding, a Claude name (`claude-opus-5-5`,
 * `claude-sonnet-5-5`, `claude-haiku-5-5`) through the configured Bedrock route (default: the
 * Chatmux metered route, Lawrence 2026-10-14), or `openrouter:<vendor>/<model>` through OpenRouter.
 * Effort is the Chief's `effort` setting (default "low") for Claude and OpenRouter models.
 *
 * The turn loop's `streamSimple` calls are tapped for the live frames (brain-stream.ts); the
 * compactor's `completeSimple` calls are not (they run beside a turn and are never shown).
 */
export const FAKE = "fake"
export const FAKE_PROVIDER = "fake"
/** The model staging and the hosted default use; kept for callers that name it. */
export const CLAUDE = OPUS
const CLAUDE_PROVIDER = "claude-david"
const OPENROUTER_PROVIDER = "openrouter"
const CLOUDFLARE_PROVIDER = "cloudflare"
const MAX_TOKENS = 16_384

export interface BrainModels {
  readonly models: MutableModels
  /** The pi-ai model for a configured name; throws for a model this deployment cannot run. */
  model(name: string): Model<Api>
  /** Thinking level for turns on this model (the Chief's effort). */
  thinking(name: string): ModelThinkingLevel
}

const fakeModel = (): Model<Api> => ({
  id: "fake-echo",
  name: "fake-echo",
  api: "fake",
  provider: FAKE_PROVIDER,
  baseUrl: "fake://",
  reasoning: false,
  input: ["text"],
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
  contextWindow: 200_000,
  maxTokens: MAX_TOKENS
})

const CLAUDE_NAMES: Record<string, string> = { "claude-opus-5-5": "Claude Opus 5.5", "claude-sonnet-5-5": "Claude Sonnet 5.5", "claude-haiku-5-5": "Claude Haiku 5.5" }
/** Prices per million tokens for names the catalog lacks (Haiku 5.5: Anthropic's Haiku tier). */
const CLAUDE_COST: Record<string, Model<Api>["cost"]> = { "claude-haiku-5-5": { input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25 } }

export const claudeModel = (name: string, baseUrl: string): Model<Api> => {
  const known = (ANTHROPIC_MODELS as Record<string, Model<Api>>)[name]
  const base: Model<Api> = known ?? { id: name, name: CLAUDE_NAMES[name] ?? name, api: "anthropic-messages", provider: CLAUDE_PROVIDER, baseUrl, reasoning: true, input: ["text"], cost: CLAUDE_COST[name] ?? { input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75 }, contextWindow: 200_000, maxTokens: MAX_TOKENS, thinkingLevelMap: { off: null, minimal: null, low: "low", medium: "medium", high: "high", xhigh: "xhigh", max: "max" }, compat: { forceAdaptiveThinking: true, supportsTemperature: false } } as Model<Api>
  return { ...base, provider: CLAUDE_PROVIDER, baseUrl, maxTokens: Math.min(base.maxTokens || MAX_TOKENS, MAX_TOKENS) }
}

const openRouterModel = (name: string, baseUrl: string): Model<Api> => {
  const id = name.slice(OPENROUTER_PREFIX.length)
  const known = Object.values(OPENROUTER_MODELS as Record<string, Model<Api>>).find((m) => m.id === id)
  const base: Model<Api> = known ?? { id, name: id, api: "openai-completions", provider: OPENROUTER_PROVIDER, baseUrl, reasoning: true, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 128_000, maxTokens: MAX_TOKENS }
  // Catalog Anthropic models talk Messages at the API root; every other one the completions API.
  return { ...base, provider: OPENROUTER_PROVIDER, baseUrl: base.api === "anthropic-messages" ? baseUrl.replace(/\/v1\/?$/, "") : baseUrl, maxTokens: Math.min(base.maxTokens || MAX_TOKENS, MAX_TOKENS) }
}

/** A provider credential that is not a person's: a constant key (or a placeholder the signed fetch replaces). */
const keyAuth = (key: string) => ({ apiKey: { name: "key", login: async () => ({ type: "api_key" as const, key }), resolve: async () => ({ auth: { apiKey: key }, source: "config" as const }) } })

export interface BrainModelOptions {
  /** The metered Claude route's credential (claude-auth.ts holder): `auth` throws ClaudeAuthError on failure. */
  readonly claude?: { auth: () => Promise<string>; refused: () => Promise<void> }
  /** The Chief's effort (BrainConfig.effort). */
  readonly effort?: () => string
  /** Who calls (run, model request, conversation, chief, owner) and the gateway's hooks (model-gateway/gateway.ts). */
  readonly who?: () => GatewayWho
  readonly hooks?: GatewayHooks
}

export const brainModels = (env: Env, sessionId: string, opts: BrainModelOptions = {}): BrainModels => {
  const raw = createModels()
  const route = claudeRoute(env)
  if (opts.claude) {
    const api = anthropicMessagesApi()
    const fetch = signedFetch(opts.claude.auth, opts.claude.refused, { auth: route.auth, models: route.models, effortBody: route.effortBody, ...(env.CHIEF_BRAIN_CLAUDE_SERVICE_KEY ? { key: env.CHIEF_BRAIN_CLAUDE_SERVICE_KEY } : {}), ...(env.CHIEF_BRAIN_CACHE_TTL ? { ttl: env.CHIEF_BRAIN_CACHE_TTL } : {}) })
    raw.setProvider(
      createProvider({
        id: CLAUDE_PROVIDER,
        name: CLAUDE_PROVIDER,
        baseUrl: route.url,
        // A placeholder the signed fetch removes: the route authenticates by its own header only.
        auth: keyAuth("route-signed"),
        models: route.models.map((m) => claudeModel(m, route.url)),
        api: { stream: (m, c, o) => api.stream(m, c, { ...o, fetch }), streamSimple: (m, c, o) => api.streamSimple(m, c, { ...o, fetch }) }
      })
    )
  }
  const orUrl = openRouterUrl(env)
  // OpenRouter ids are open-ended: the provider lists the ids this object has been asked for.
  const orModels = new Map<string, Model<Api>>()
  const setOpenRouter = () =>
    env.OPENROUTER_API_KEY &&
    raw.setProvider(createProvider({ id: OPENROUTER_PROVIDER, name: OPENROUTER_PROVIDER, baseUrl: orUrl, auth: keyAuth(env.OPENROUTER_API_KEY), models: [...orModels.values()], api: { "anthropic-messages": anthropicMessagesApi(), "openai-completions": openAICompletionsApi() } }))
  setOpenRouter()
  raw.setProvider(createProvider({ id: FAKE_PROVIDER, name: FAKE_PROVIDER, auth: keyAuth("unused"), models: [fakeModel()], api: fakeStreams() }))
  const cloudflare = env.AI ? createAI({ binding: env.AI }) : undefined
  if (cloudflare) raw.setProvider(cloudflare.provider)
  // An OpenRouter id a resumed turn names before any model() call (after an eviction) is registered on lookup.
  const lookup = new Proxy(raw, {
    get(target, key) {
      if (key === "getModel") return (provider: string, id: string) => target.getModel(provider, id) ?? (provider === OPENROUTER_PROVIDER && env.OPENROUTER_API_KEY ? (openRouter(`${OPENROUTER_PREFIX}${id}`), target.getModel(provider, id)) : undefined)
      const v = Reflect.get(target, key, target) as unknown
      return typeof v === "function" ? (v as (...a: Array<unknown>) => unknown).bind(target) : v
    }
  }) as MutableModels
  // Turn calls (streamSimple) and compactor calls (completeSimple) go through the model gateway: credits, usage, live events.
  const noone = (): GatewayWho => ({ run: undefined, generation: undefined, conversation: undefined, agent: null, owner: null })
  const models = new ModelGatewayLive(env, sessionId, lookup, opts.who ?? noone, opts.hooks).models()
  function openRouter(name: string): Model<Api> {
    const m = openRouterModel(name, orUrl)
    if (!orModels.has(m.id)) [orModels.set(m.id, m), setOpenRouter()]
    return m
  }
  return {
    models,
    model: (name) => {
      if (name === FAKE) return fakeModel()
      if (isClaude(name)) return claudeModel(name, route.url)
      if (isOpenRouter(name)) {
        if (!env.OPENROUTER_API_KEY) throw new Error(`model ${name} needs OPENROUTER_API_KEY, which this deployment does not have`)
        return openRouter(name)
      }
      if (!cloudflare) throw new Error(`model ${name} needs the Workers AI binding, which this deployment does not have`)
      // One affinity key per chief: its requests reach the same replica (prefix cache hits across turns).
      const m = cloudflare(name, { sessionAffinity: sessionId }) as unknown as Model<Api>
      return { ...m, provider: CLOUDFLARE_PROVIDER, maxTokens: Math.min(m.maxTokens || MAX_TOKENS, MAX_TOKENS) }
    },
    // The Chief's effort for Claude and OpenRouter; Workers AI keeps "low" (its models take no higher levels).
    thinking: (name) => (name === FAKE ? "off" : isMetered(name) ? ((opts.effort?.() || DEFAULT_EFFORT) as ModelThinkingLevel) : "low")
  }
}
