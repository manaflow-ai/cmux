import { createModels, createProvider, type MutableModels } from "@earendil-works/pi-ai/models"
import type { Api, Model, ModelThinkingLevel } from "@earendil-works/pi-ai"
import { anthropicMessagesApi } from "@earendil-works/pi-ai/api/anthropic-messages.lazy"
import { ANTHROPIC_MODELS } from "@earendil-works/pi-ai/providers/anthropic.models"
import { createAI } from "agents/models/pi-ai"
import { signedFetch } from "./claude-auth.ts"
import { fakeStreams } from "./fake.ts"

/**
 * The Chief brain's models. A model name is either `fake` (the deterministic in-process model of
 * fake.ts: tests and offline runs) or a Workers AI id `@cf/...`, run through the Worker's own AI
 * binding (no key, no outside route; the coordinator's model decision for the Durable Object
 * Chief, plans/cmux-next/chief.md section 7 item 3), or `claude-opus-5-5`: Claude through the
 * metered Bedrock route of the Chatmux service (Lawrence 2026-10-14: "the bedrock key coderouter
 * thing for now, should bill towards that"), signed by claude-auth.ts. The team subrouter is a
 * tailnet host a deployed Worker cannot reach, so it is not a choice here.
 */
export const FAKE = "fake"
export const FAKE_PROVIDER = "fake"
export const CLAUDE = "claude-opus-5-5"
const CLAUDE_PROVIDER = "claude-david"
const CLAUDE_URL = "https://chatmux.dev/api/claude-david"
const CLOUDFLARE_PROVIDER = "cloudflare"

export interface BrainModels {
  readonly models: MutableModels
  /** The pi-ai model for a configured name; throws for a Workers AI name when the binding is absent. */
  model(name: string): Model<Api>
  /** Thinking level for turns on this model. */
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
  maxTokens: 16_384
})

/** A model name the brain accepts: `fake`, or `@cf/<vendor>/<model>`. */
export const validModelName = (v: unknown): v is string => typeof v === "string" && (v === FAKE || v === CLAUDE || /^@cf\/[a-z0-9._-]{1,64}\/[a-z0-9._-]{1,96}$/.test(v))

const claudeModel = (baseUrl: string): Model<Api> => {
  const known = (ANTHROPIC_MODELS as Record<string, Model<Api>>)[CLAUDE]
  const base: Model<Api> = known ?? { id: CLAUDE, name: "Claude Opus 5.5", api: "anthropic-messages", provider: CLAUDE_PROVIDER, baseUrl, reasoning: true, input: ["text"], cost: { input: 4, output: 20, cacheRead: 0.2, cacheWrite: 5 }, contextWindow: 200_000, maxTokens: 16_384 }
  return { ...base, provider: CLAUDE_PROVIDER, baseUrl, maxTokens: Math.min(base.maxTokens || 16_384, 16_384) }
}

/**
 * `claude.auth` returns the route's X-Stack-Auth value (throws ClaudeAuthError, fixed text, when the
 * sign-in fails), `claude.refused` drops a token the route answered 401 to; `claudeUrl` overrides the route (tests).
 */
export const brainModels = (ai: Ai | undefined, sessionId: string, claude?: { auth: () => Promise<string>; refused: () => Promise<void> }, claudeUrl = CLAUDE_URL): BrainModels => {
  const models = createModels()
  if (claude) {
    const api = anthropicMessagesApi()
    const fetch = signedFetch(claude.auth, claude.refused)
    models.setProvider(
      createProvider({
        id: CLAUDE_PROVIDER,
        name: CLAUDE_PROVIDER,
        baseUrl: claudeUrl,
        // A placeholder the signed fetch removes: the route authenticates by X-Stack-Auth only.
        auth: { apiKey: { name: "none", login: async () => ({ type: "api_key", key: "route-signed" }), resolve: async () => ({ auth: { apiKey: "route-signed" }, source: "config" }) } },
        models: [claudeModel(claudeUrl)],
        api: { stream: (m, c, o) => api.stream(m, c, { ...o, fetch }), streamSimple: (m, c, o) => api.streamSimple(m, c, { ...o, fetch }) }
      })
    )
  }
  models.setProvider(
    createProvider({
      id: FAKE_PROVIDER,
      name: FAKE_PROVIDER,
      auth: { apiKey: { name: "none", login: async () => ({ type: "api_key", key: "unused" }), resolve: async () => ({ auth: { apiKey: "unused" }, source: "config" }) } },
      models: [fakeModel()],
      api: fakeStreams()
    })
  )
  const cloudflare = ai ? createAI({ binding: ai }) : undefined
  if (cloudflare) models.setProvider(cloudflare.provider)
  return {
    models,
    model: (name) => {
      if (name === FAKE) return fakeModel()
      if (name === CLAUDE) return claudeModel(claudeUrl)
      if (!cloudflare) throw new Error(`model ${name} needs the Workers AI binding, which this deployment does not have`)
      // One affinity key per chief: its requests reach the same replica (prefix cache hits across turns).
      const m = cloudflare(name, { sessionAffinity: sessionId }) as unknown as Model<Api>
      return { ...m, provider: CLOUDFLARE_PROVIDER, maxTokens: Math.min(m.maxTokens || 16_384, 16_384) }
    },
    thinking: (name) => (name === FAKE ? "off" : "low")
  }
}
