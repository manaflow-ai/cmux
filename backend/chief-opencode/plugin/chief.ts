/**
 * The pure parts of the cmux-chief plugin (server.ts): plugin options, the gateway model table,
 * the Chief Protocol shapes the brain reads, the Chief's system prompt and message format, and the
 * compact "working on" line. No opencode or Effect runtime here.
 */
// ---------------------------------------------------------------- options

export interface Options {
  /** The host's CP endpoint (JSON-RPC over HTTP POST). Absent: no host (fails every wake). */
  readonly host?: string
  /** The model gateway: Anthropic Messages base URL (`<base>/messages`). */
  readonly gateway?: string
  /** Environment variable holding the chief token (host and gateway auth). Default CMUX_CHIEF_TOKEN. */
  readonly tokenEnv?: string
  /** Gateway model id per cmux model name (default: the same name). */
  readonly modelIds?: Readonly<Record<string, string>>
  /** Cache TTL of every Anthropic cache mark: "1h" (default) or "5m". */
  readonly cacheTtl?: "1h" | "5m"
  /** Bench only: one line per model request (URL, kind, cache mark TTLs; never headers or text). */
  readonly traceRequests?: string
}

export const str = (v: unknown): string | undefined => (typeof v === "string" && v.length > 0 ? v : undefined)
export const readOptions = (raw: unknown): Options => {
  const o = (raw ?? {}) as Record<string, unknown>
  const ids = o.modelIds && typeof o.modelIds === "object" ? (o.modelIds as Record<string, string>) : undefined
  return {
    ...(str(o.host) ? { host: str(o.host)! } : {}),
    ...(str(o.gateway) ? { gateway: str(o.gateway)!.replace(/\/+$/, "") } : {}),
    ...(str(o.tokenEnv) ? { tokenEnv: str(o.tokenEnv)! } : {}),
    ...(ids ? { modelIds: ids } : {}),
    cacheTtl: o.cacheTtl === "5m" ? "5m" : "1h",
    ...(str(o.traceRequests) ? { traceRequests: str(o.traceRequests)! } : {})
  }
}

// ---------------------------------------------------------------- models

export const GATEWAY = "cmux-gateway"
export const EFFORTS = ["low", "medium", "high", "xhigh", "max"] as const
export type Cost = readonly [input: number, output: number, cacheRead: number, cacheWrite: number]
/** $ per million tokens (cache write at the 1 h rate, 2x input). Unknown models price at 0 here; the gateway bills. */
export const KNOWN: Readonly<Record<string, { name: string; cost: Cost }>> = {
  "claude-opus-5-5": { name: "Claude Opus 5.5", cost: [4, 20, 0.2, 8] },
  "claude-sonnet-5-5": { name: "Claude Sonnet 5.5", cost: [2, 10, 0.1, 4] },
  "claude-haiku-5-5": { name: "Claude Haiku 5.5", cost: [0.1, 0.5, 0.01, 0.2] }
}
/** Effort for Anthropic models (adaptive thinking, summarized); other models take `reasoning.effort`. */
export const effortBody = (id: string, effort: string): Record<string, unknown> =>
  id.startsWith("claude-") || id.startsWith("anthropic/")
    ? { thinking: { type: "adaptive", display: "summarized" }, output_config: { effort } }
    : { reasoning: { effort: effort === "xhigh" || effort === "max" ? "high" : effort } }

export const modelInfo = (id: string, upstream: string) => {
  const k = KNOWN[id] ?? { name: id, cost: [0, 0, 0, 0] as Cost }
  return {
    id, modelID: upstream, providerID: GATEWAY, name: k.name,
    capabilities: { tools: true, input: ["text", "image"], output: ["text"] },
    variants: EFFORTS.map((e) => ({ id: e, body: effortBody(id, e) })),
    time: { released: 0 },
    cost: [{ input: k.cost[0], output: k.cost[1], cache: { read: k.cost[2], write: k.cost[3] } }],
    status: "active", enabled: true,
    limit: { context: 200_000, output: 32_000 }
  } as never
}

// ---------------------------------------------------------------- CP shapes (contract.ts, as JSON)

export type Json = null | boolean | number | string | ReadonlyArray<Json> | { readonly [k: string]: Json }
export interface Usage { input: number; output: number; cache_read: number; cache_write: number }
export interface Message { id: string; seq: number; author: { id: string; name: string; kind: string }; text: string; thread_root?: string }
export interface Read { conversation: { id: string; kind: string; title?: string; shared?: boolean }; messages: ReadonlyArray<Message>; cursor: number }
export interface Initialized { chief: { id: string; name: string; owner?: string; role?: string; personality?: string; instructions?: string; model?: string; effort?: string } }

export const NO_REPLY = "NO_REPLY"
export const isNoReply = (text: string) => text.replace(/[^A-Za-z_]/g, "").toUpperCase() === NO_REPLY
export const TEXT_MAX = 32 * 1024
export const clip = (text: string) => (text.length <= TEXT_MAX ? text : `${text.slice(0, TEXT_MAX / 2)}\n[... cut ...]\n${text.slice(-TEXT_MAX / 2)}`)
export const oneLine = (s: string, max: number) => {
  const t = s.replace(/\s+/g, " ").trim()
  return t.length <= max ? t : `${t.slice(0, max - 1)}…`
}

export const BASE = `You are a Chief: an AI agent that works for your owner and their team in cmux
conversations (direct messages and channels). You remember this conversation.

Each new message starts with a header line in brackets that names the conversation, its kind
(chief: your owner's direct line to you; dm; channel; group) and the author. Your owner may share
your chief line with teammates: then answer the author of the message by name. Your final reply is
posted as one message in that conversation (in a channel, in the thread of the message you answer).
Write only the message itself: no header, no quoting of the brackets. Use your cmux tools when a
message needs them; other Chiefs are reached only by posting in a conversation they are in.

In a channel you act on your own: answer when the message is for you or fits your role. When a
channel message is not for you and needs nothing from you, answer exactly ${NO_REPLY} and nothing is
posted. Never answer ${NO_REPLY} in a direct message.`

/** Base, then "## This Chief" and "## Added instructions" (lower priority than the base). Stable text: it caches. */
export const systemPrompt = (c: Initialized["chief"]): string => {
  const me = [`Name: ${c.name}`, c.role?.trim() ? `Role: ${c.role.trim()}` : "", c.personality?.trim() ? `Personality: ${c.personality.trim()}` : ""].filter(Boolean)
  const added = c.instructions?.trim()
  return [BASE, `## This Chief (the rules above come first)\n${me.join("\n")}`, ...(added ? [`## Added instructions (the rules above come first)\n${added}`] : [])].join("\n\n")
}

/** One message as the Chief reads it (the same header shape as the P brain's formatMessage). */
export const formatMessage = (c: Read["conversation"], m: Message) => {
  const where = c.title?.trim() || c.kind
  return `[${where} · ${c.kind} · ${m.author.name}${m.thread_root ? " · in a thread" : ""}] ${m.text}`
}

/** The compact "working on" line: present tense, newest tool wins, elapsed seconds; <= 80 chars. */
export const toolActivity = (name: string, input: Record<string, unknown>): string => {
  const s = (k: string) => (typeof input[k] === "string" ? (input[k] as string) : "")
  switch (name.replace(/^cmux_/, "")) {
    case "post": return "Posting in the conversation"
    case "chiefs": return s("action") === "create" ? `Creating Chief ${s("display_name")}` : s("action") === "update" ? `Editing Chief ${s("chief")}` : "Reading Chiefs"
    case "hands": return s("action") === "call" ? `Using hand ${s("hand")}` : "Listing hands"
    case "agents": return s("action") === "start" ? `Spawning ${s("harness") || "an agent"} on ${s("hand") || "a hand"}` : "Checking agents"
    default: return `Running ${name}`
  }
}
