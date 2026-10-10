/**
 * The model router's catalog (plans/cmux-next/model-router.md, epic cx-dna4): which providers exist,
 * which public model ids we serve, and the ordered provider list per model. Public ids follow the
 * `vendor/model` form; each provider entry names that provider's own id for the model.
 *
 * `card` is our price ceiling per million tokens (USD). It is set at or above every provider's list
 * price, so a projected maximum cost from the card is an upper bound. Actual cost uses the
 * provider-reported cost when the provider sends one, else the card.
 */

export const PROVIDERS = ["openrouter", "vercel", "workers-ai", "deepseek", "deepinfra", "bedrock"] as const
export type ProviderId = (typeof PROVIDERS)[number]

/** Budget lines of the spend guard: one per provider, plus the free tier's own line. */
export type BudgetLine = ProviderId | "free"
export const BUDGET_LINES: ReadonlyArray<BudgetLine> = [...PROVIDERS, "free"]

export interface ProviderRoute {
  readonly provider: ProviderId
  /** The provider's id for this model. */
  readonly id: string
}

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
      { provider: "openrouter", id: "qwen/qwen3.7-flash" },
      { provider: "vercel", id: "alibaba/qwen3.7-flash" }
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
      { provider: "openrouter", id: "openai/gpt-oss-120b" },
      { provider: "vercel", id: "openai/gpt-oss-120b" },
      { provider: "workers-ai", id: "@cf/openai/gpt-oss-120b" },
      { provider: "bedrock", id: "openai.gpt-oss-120b-1:0" }
    ]
  },
  {
    id: "deepseek/deepseek-v4-pro",
    name: "DeepSeek V4 Pro",
    card: { input: 1.0, output: 2.0 },
    context: 1_000_000,
    maxOutput: 65_536,
    defaultMaxTokens: 16_384,
    tools: true,
    routes: [
      { provider: "openrouter", id: "deepseek/deepseek-v4-pro" },
      { provider: "vercel", id: "deepseek/deepseek-v4-pro" }
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
      { provider: "vercel", id: "deepseek/deepseek-v4-flash" },
      { provider: "openrouter", id: "deepseek/deepseek-v4-flash" }
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
      { provider: "openrouter", id: "moonshotai/kimi-k2.7-code" },
      { provider: "vercel", id: "moonshotai/kimi-k2.7-code" }
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
      { provider: "vercel", id: "zai/glm-5.3" },
      { provider: "openrouter", id: "z-ai/glm-5.3" }
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
      { provider: "openrouter", id: "minimax/minimax-m3" },
      { provider: "vercel", id: "minimax/minimax-m3" }
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
      { provider: "vercel", id: "meta/llama-4-scout" },
      { provider: "openrouter", id: "meta-llama/llama-4-scout" }
    ]
  }
]

const BY_ID = new Map(MODELS.map((m) => [m.id, m]))
export const modelById = (id: string): ModelEntry | undefined => BY_ID.get(id)

/** USD for a token count at the card. */
export const cardCost = (m: ModelEntry, input: number, output: number) => (input * m.card.input + output * m.card.output) / 1_000_000
