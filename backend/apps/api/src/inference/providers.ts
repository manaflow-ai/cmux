import type { Env } from "../env.ts"
import type { ProviderId } from "./catalog.ts"

/**
 * Provider adapters of the model router (open-source models only). Five providers speak OpenAI chat/completions, so their
 * adapter is a base URL, a key and a few body fields. Workers AI is reached through the Worker's
 * AI binding (no key) and is translated in workers-ai.ts.
 *
 * Keys come only from Worker secrets. A provider without its key is not configured and is skipped.
 */

export interface OpenAiCompatible {
  readonly kind: "openai"
  readonly url: string
  readonly key: string
  /** Fields this provider needs on every request (privacy and cost reporting). */
  readonly extraBody: Readonly<Record<string, unknown>>
  readonly extraHeaders: Readonly<Record<string, string>>
}

export interface WorkersAi {
  readonly kind: "workers-ai"
  readonly ai: Ai
}

export type ProviderTarget = OpenAiCompatible | WorkersAi

const openai = (url: string, key: string | undefined, extraBody: Record<string, unknown> = {}, extraHeaders: Record<string, string> = {}): OpenAiCompatible | undefined =>
  key ? { kind: "openai", url, key, extraBody, extraHeaders } : undefined

/** The configured target of a provider, or undefined (no key or binding on this deployment). */
export const providerTarget = (env: Env, provider: ProviderId): ProviderTarget | undefined => {
  switch (provider) {
    case "openrouter":
      // usage.include: the response carries the request's real cost. upstream.ts adds the provider
      // preferences per request: data_collection deny (no upstream that keeps or trains on prompts)
      // and max_price at our card, so no sub-provider costs more than the reservation assumed.
      return openai("https://openrouter.ai/api/v1/chat/completions", env.INFERENCE_OPENROUTER_KEY, { usage: { include: true } }, { "X-Title": "cmux" })
    case "vercel":
      return openai("https://ai-gateway.vercel.sh/v1/chat/completions", env.INFERENCE_VERCEL_GATEWAY_KEY)
    case "fireworks":
      return openai("https://api.fireworks.ai/inference/v1/chat/completions", env.INFERENCE_FIREWORKS_KEY)
    case "baseten":
      return openai("https://inference.baseten.co/v1/chat/completions", env.INFERENCE_BASETEN_KEY)
    case "deepinfra":
      return openai("https://api.deepinfra.com/v1/openai/chat/completions", env.INFERENCE_DEEPINFRA_KEY)
    case "workers-ai":
      return env.AI ? { kind: "workers-ai", ai: env.AI } : undefined
  }
}

/** Upstream usage, in tokens, with the provider's own USD cost when it reports one. */
export interface UpstreamUsage {
  readonly input: number
  readonly output: number
  readonly costUsd?: number
}

const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) && v >= 0 ? v : undefined)

/** Reads an OpenAI-style `usage` object (plus OpenRouter `cost` and DeepInfra `estimated_cost`). */
export const parseUsage = (usage: unknown): UpstreamUsage | undefined => {
  if (!usage || typeof usage !== "object") return undefined
  const u = usage as Record<string, unknown>
  const input = num(u.prompt_tokens)
  const output = num(u.completion_tokens)
  if (input === undefined || output === undefined) return undefined
  const cost = num(u.cost) ?? num(u.estimated_cost)
  return cost === undefined ? { input, output } : { input, output, costUsd: cost }
}
