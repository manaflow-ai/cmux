import { createModels, createProvider, type MutableModels } from "@earendil-works/pi-ai/models"
import type { Api, Model, ModelThinkingLevel } from "@earendil-works/pi-ai"
import { createAI } from "agents/models/pi-ai"
import { fakeStreams } from "./fake.ts"

/**
 * The Chief brain's models. A model name is either `fake` (the deterministic in-process model of
 * fake.ts: tests and offline runs) or a Workers AI id `@cf/...`, run through the Worker's own AI
 * binding (no key, no outside route; the coordinator's model decision for the Durable Object
 * Chief, plans/cmux-next/chief.md section 7 item 3). The team subrouter is a tailnet host a
 * deployed Worker cannot reach, so it is not a choice here.
 */
export const FAKE = "fake"
export const FAKE_PROVIDER = "fake"
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
export const validModelName = (v: unknown): v is string => typeof v === "string" && (v === FAKE || /^@cf\/[a-z0-9._-]{1,64}\/[a-z0-9._-]{1,96}$/.test(v))

export const brainModels = (ai: Ai | undefined, sessionId: string): BrainModels => {
  const models = createModels()
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
      if (!cloudflare) throw new Error(`model ${name} needs the Workers AI binding, which this deployment does not have`)
      // One affinity key per chief: its requests reach the same replica (prefix cache hits across turns).
      const m = cloudflare(name, { sessionAffinity: sessionId }) as unknown as Model<Api>
      return { ...m, provider: CLOUDFLARE_PROVIDER, maxTokens: Math.min(m.maxTokens || 16_384, 16_384) }
    },
    thinking: (name) => (name === FAKE ? "off" : "low")
  }
}
