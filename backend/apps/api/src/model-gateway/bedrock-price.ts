import type { Api, AssistantMessage, Model } from "@earendil-works/pi-ai"

/**
 * What the Claude route pays Bedrock, so the credit meter charges that (coordinator, 2026-10-18).
 * USD per million tokens, on-demand, global cross-region profile (routes.ts BEDROCK_IDS are `global.`),
 * from the AWS Price List API: offer AmazonBedrockFoundationModels, us-east-1, version 20261016210806
 * ("... Standard, Global" rows). Haiku 5.5 has a second tier for a prompt above 100,000 tokens
 * ("Long Context"); Opus 5.5 and Sonnet 5.5 have one tier.
 */
export interface Price {
  readonly input: number
  readonly output: number
  readonly cacheRead: number
  readonly write5m: number
  readonly write1h: number
}
interface Tiers {
  readonly base: Price
  /** Prompt tokens (input + cache read + cache write) above which `price` applies to the whole call. */
  readonly long?: { readonly above: number; readonly price: Price }
}

export const BEDROCK_PRICES: Readonly<Record<string, Tiers>> = {
  "claude-opus-5-5": { base: { input: 4, output: 20, cacheRead: 0.2, write5m: 5, write1h: 8 } },
  "claude-sonnet-5-5": { base: { input: 2, output: 10, cacheRead: 0.1, write5m: 2.5, write1h: 4 } },
  "claude-haiku-5-5": {
    base: { input: 0.1, output: 0.5, cacheRead: 0.01, write5m: 0.125, write1h: 0.2 },
    long: { above: 100_000, price: { input: 0.5, output: 2.5, cacheRead: 0.05, write5m: 0.625, write1h: 1 } }
  }
}

/** The cache write rate the route's marks pay: bedrock-stream.ts marks 1-hour entries unless CHIEF_BRAIN_CACHE_TTL is "5m". */
const writeRate = (p: Price, ttl: string | undefined) => (ttl === "5m" ? p.write5m : p.write1h)

/** A pi-ai cost object for the credits hold (the highest tier, so a hold never falls short), or undefined for a model this table lacks. */
export const bedrockCost = (id: string, ttl: string | undefined): Model<Api>["cost"] | undefined => {
  const t = BEDROCK_PRICES[id]
  const p = t?.long?.price ?? t?.base
  return p ? { input: p.input, output: p.output, cacheRead: p.cacheRead, cacheWrite: writeRate(p, ttl) } : undefined
}

export interface Tokens {
  readonly input?: number
  readonly output?: number
  readonly cacheRead?: number
  readonly cacheWrite?: number
  /** The part of cacheWrite written as 1-hour entries (the response's cache_creation.ephemeral_1h_input_tokens), when known. */
  readonly cacheWrite1h?: number
}

/** The USD cost of `u` on `id` (the tier its prompt size picks), split as pi-ai's usage cost; undefined for a model this table lacks. */
export const costOf = (id: string, u: Tokens, ttl: string | undefined) => {
  const t = BEDROCK_PRICES[id]
  if (!t) return undefined
  const n = (v: unknown) => (typeof v === "number" && Number.isFinite(v) && v > 0 ? v : 0)
  const prompt = n(u.input) + n(u.cacheRead) + n(u.cacheWrite)
  const p = t.long && prompt > t.long.above ? t.long.price : t.base
  // The response says how many written tokens are 1-hour entries; else the TTL the route marks decides.
  const w1h = typeof u.cacheWrite1h === "number" ? Math.min(n(u.cacheWrite1h), n(u.cacheWrite)) : undefined
  const write = w1h === undefined ? n(u.cacheWrite) * writeRate(p, ttl) : w1h * p.write1h + (n(u.cacheWrite) - w1h) * p.write5m
  const c = { input: (n(u.input) * p.input) / 1e6, output: (n(u.output) * p.output) / 1e6, cacheRead: (n(u.cacheRead) * p.cacheRead) / 1e6, cacheWrite: write / 1e6 }
  return { ...c, total: c.input + c.output + c.cacheRead + c.cacheWrite }
}

/** `message` with its usage cost set from the Bedrock price of the tokens it reports. */
export const reprice = (message: AssistantMessage, ttl: string | undefined): AssistantMessage => {
  const cost = message.usage ? costOf(message.model, message.usage, ttl) : undefined
  return cost ? { ...message, usage: { ...message.usage, cost } } : message
}
