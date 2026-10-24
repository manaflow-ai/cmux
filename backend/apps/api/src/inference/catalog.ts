/**
 * The model router's catalog (plans/cmux-next/model-router.md, epic cx-dna4): which providers exist,
 * which public model ids we serve, and the ordered provider list per model. Public ids follow the
 * `vendor/model` form; each provider entry names that provider's own id for the model.
 *
 * `card` is our price ceiling per million tokens (USD). It is set at or above every provider's list
 * price, so a projected maximum cost from the card is an upper bound. Actual cost uses the
 * provider-reported cost when the provider sends one, else the card.
 *
 * Open-source models only (Lawrence, 2026-10-10). Provider ids come from each provider's own model
 * list (2026-10-10, read with our keys); a model a provider does not list has no route there.
 */

export const PROVIDERS = ["openrouter", "vercel", "workers-ai", "fireworks", "baseten", "deepinfra"] as const
export type ProviderId = (typeof PROVIDERS)[number]

/** Budget lines of the spend guard: one per provider, plus the free tier's own line. */
export type BudgetLine = ProviderId | "free"
export const BUDGET_LINES: ReadonlyArray<BudgetLine> = [...PROVIDERS, "free"]

export interface ProviderRoute {
  readonly provider: ProviderId
  /** The provider's id for this model. */
  readonly id: string
  /**
   * The provider's list price for this model, USD per million tokens, read from its own model list
   * with our key (2026-10-23). Orders the routes cheapest first (route.ts liveRoutes); a route
   * without one keeps its catalog place after the priced ones. Metering never uses it.
   */
  readonly list?: { readonly input: number; readonly output: number }
}

/** Blended list price of a route: agent turns read about three input tokens per output token. */
export const routeCost = (r: ProviderRoute): number => (r.list ? 3 * r.list.input + r.list.output : Infinity)

export interface ModelEntry {
  readonly id: string
  readonly name: string
  /** USD per million tokens: input, output (ceilings, see the file comment). */
  readonly card: { readonly input: number; readonly output: number }
  readonly context: number
  /** Largest output we ask for; a request without max_tokens gets `defaultMaxTokens`. */
  readonly maxOutput: number
  readonly defaultMaxTokens: number
  readonly tools: boolean
  /** Providers in fallback order. A provider without a key or budget is skipped. */
  readonly routes: ReadonlyArray<ProviderRoute>
  /** The free tier may use this model (S3). */
  readonly free?: true
}

export const MODELS: ReadonlyArray<ModelEntry> = [
  {
    id: "qwen/qwen3.7-flash",
    name: "Qwen3.7 Flash",
    card: { input: 0.05, output: 0.2 },
    context: 1_000_000,
    maxOutput: 32_768,
    defaultMaxTokens: 8_192,
    tools: true,
    free: true,
    routes: [
      { provider: "openrouter", id: "qwen/qwen3.7-flash", list: { input: 0.03, output: 0.13 } },
      { provider: "vercel", id: "alibaba/qwen3.7-flash", list: { input: 0.03, output: 0.13 } }
    ]
  },
  {
    id: "openai/gpt-oss-120b",
    name: "gpt-oss-120b",
    card: { input: 0.4, output: 0.8 },
    context: 131_072,
    maxOutput: 32_768,
    defaultMaxTokens: 8_192,
    tools: true,
    free: true,
    routes: [
      { provider: "openrouter", id: "openai/gpt-oss-120b", list: { input: 0.15, output: 0.6 } },
      { provider: "vercel", id: "openai/gpt-oss-120b", list: { input: 0.1, output: 0.5 } },
      { provider: "deepinfra", id: "openai/gpt-oss-120b", list: { input: 0.037, output: 0.17 } },
      { provider: "fireworks", id: "accounts/fireworks/models/gpt-oss-120b" },
      { provider: "baseten", id: "openai/gpt-oss-120b" },
      { provider: "workers-ai", id: "@cf/openai/gpt-oss-120b" }
    ]
  },
  {
    id: "deepseek/deepseek-v4-pro",
    name: "DeepSeek V4 Pro",
    card: { input: 1.5, output: 3.0 },
    context: 1_000_000,
    maxOutput: 65_536,
    defaultMaxTokens: 16_384,
    tools: true,
    routes: [
      { provider: "openrouter", id: "deepseek/deepseek-v4-pro", list: { input: 0.561, output: 1.122 } },
      { provider: "vercel", id: "deepseek/deepseek-v4-pro", list: { input: 0.66, output: 1.98 } },
      { provider: "deepinfra", id: "deepseek-ai/DeepSeek-V4-Pro", list: { input: 1.3, output: 2.6 } }
    ]
  },
  {
    id: "deepseek/deepseek-v4-flash",
    name: "DeepSeek V4 Flash",
    card: { input: 0.3, output: 1.3 },
    context: 1_000_000,
    maxOutput: 65_536,
    defaultMaxTokens: 16_384,
    tools: true,
    routes: [
      { provider: "vercel", id: "deepseek/deepseek-v4-flash", list: { input: 0.13, output: 0.26 } },
      { provider: "deepinfra", id: "deepseek-ai/DeepSeek-V4-Flash", list: { input: 0.09, output: 0.18 } },
      { provider: "openrouter", id: "deepseek/deepseek-v4-flash", list: { input: 0.091, output: 0.182 } }
    ]
  },
  {
    id: "moonshotai/kimi-k2.7-code",
    name: "Kimi K2.7 Code",
    card: { input: 1.0, output: 4.0 },
    context: 262_144,
    maxOutput: 65_536,
    defaultMaxTokens: 16_384,
    tools: true,
    routes: [
      { provider: "openrouter", id: "moonshotai/kimi-k2.7-code", list: { input: 0.671, output: 3.35 } },
      { provider: "vercel", id: "moonshotai/kimi-k2.7-code", list: { input: 0.95, output: 4 } }
    ]
  },
  {
    id: "z-ai/glm-5.3",
    name: "GLM-5.3",
    card: { input: 1.5, output: 5.0 },
    context: 1_000_000,
    maxOutput: 65_536,
    defaultMaxTokens: 16_384,
    tools: true,
    routes: [
      { provider: "fireworks", id: "accounts/fireworks/models/glm-5p3" },
      { provider: "baseten", id: "zai-org/GLM-5.3" },
      { provider: "deepinfra", id: "zai-org/GLM-5.3", list: { input: 0.9, output: 4 } },
      { provider: "vercel", id: "zai/glm-5.3", list: { input: 1.2, output: 4 } },
      { provider: "openrouter", id: "z-ai/glm-5.3", list: { input: 0.079, output: 1.4 } }
    ]
  },
  {
    id: "minimax/minimax-m3",
    name: "MiniMax M3",
    card: { input: 0.35, output: 1.3 },
    context: 1_000_000,
    maxOutput: 65_536,
    defaultMaxTokens: 16_384,
    tools: true,
    routes: [
      { provider: "fireworks", id: "accounts/fireworks/models/minimax-m3" },
      { provider: "deepinfra", id: "MiniMaxAI/MiniMax-M3", list: { input: 0.28, output: 1.1 } },
      { provider: "openrouter", id: "minimax/minimax-m3", list: { input: 0.3, output: 1.2 } },
      { provider: "vercel", id: "minimax/minimax-m3", list: { input: 0.3, output: 1.2 } }
    ]
  },
  {
    id: "deepseek/deepseek-v4.1-flash",
    name: "DeepSeek V4.1 Flash",
    card: { input: 0.4, output: 1.5 },
    context: 1_000_000,
    maxOutput: 65_536,
    defaultMaxTokens: 16_384,
    tools: true,
    routes: [
      { provider: "fireworks", id: "accounts/fireworks/models/deepseek-v4p1-flash" },
      { provider: "baseten", id: "deepseek-ai/DeepSeek-V4.1-Flash" },
      { provider: "deepinfra", id: "deepseek-ai/DeepSeek-V4.1-Flash", list: { input: 0.2, output: 0.6 } },
      { provider: "openrouter", id: "deepseek/deepseek-v4.1-flash", list: { input: 0.02, output: 1 } },
      { provider: "vercel", id: "deepseek/deepseek-v4.1-flash", list: { input: 0.075, output: 0.3 } }
    ]
  },
  {
    id: "moonshotai/kimi-k3",
    name: "Kimi K3",
    card: { input: 3.5, output: 16.0 },
    context: 1_000_000,
    maxOutput: 65_536,
    defaultMaxTokens: 16_384,
    tools: true,
    routes: [
      { provider: "fireworks", id: "accounts/fireworks/models/kimi-k3" },
      { provider: "baseten", id: "moonshotai/Kimi-K3" },
      { provider: "deepinfra", id: "moonshotai/Kimi-K3", list: { input: 2.85, output: 14.25 } },
      { provider: "openrouter", id: "moonshotai/kimi-k3", list: { input: 0.239, output: 10.8 } },
      { provider: "vercel", id: "moonshotai/kimi-k3", list: { input: 3, output: 15 } }
    ]
  },
  {
    id: "z-ai/glm-5.3-flash",
    name: "GLM-5.3 Flash",
    card: { input: 0.25, output: 0.8 },
    context: 1_000_000,
    maxOutput: 65_536,
    defaultMaxTokens: 16_384,
    tools: true,
    routes: [
      { provider: "fireworks", id: "accounts/fireworks/models/glm-5p3-flash" },
      { provider: "baseten", id: "zai-org/GLM-5.3-Flash" },
      { provider: "deepinfra", id: "zai-org/GLM-5.3-Flash", list: { input: 0.15, output: 0.5 } },
      { provider: "openrouter", id: "z-ai/glm-5.3-flash", list: { input: 0.15, output: 0.5 } },
      { provider: "vercel", id: "zai/glm-5.3-flash", list: { input: 0.15, output: 0.5 } }
    ]
  },
  {
    id: "meta/llama-4-scout",
    name: "Llama 4 Scout",
    card: { input: 0.3, output: 0.9 },
    context: 131_072,
    maxOutput: 16_384,
    defaultMaxTokens: 4_096,
    tools: true,
    routes: [
      { provider: "workers-ai", id: "@cf/meta/llama-4-scout-17b-16e-instruct" },
      { provider: "vercel", id: "meta/llama-4-scout", list: { input: 0.17, output: 0.66 } },
      { provider: "deepinfra", id: "meta-llama/Llama-4-Scout-17B-16E-Instruct", list: { input: 0.1, output: 0.3 } },
      { provider: "openrouter", id: "meta-llama/llama-4-scout", list: { input: 0.1, output: 0.3 } }
    ]
  }
]

const BY_ID = new Map(MODELS.map((m) => [m.id, m]))
export const modelById = (id: string): ModelEntry | undefined => BY_ID.get(id)

/** USD for a token count at the card. */
export const cardCost = (m: ModelEntry, input: number, output: number) => (input * m.card.input + output * m.card.output) / 1_000_000
