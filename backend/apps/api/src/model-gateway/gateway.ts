import type { Api, AssistantMessage, AssistantMessageEvent, AssistantMessageEventStream, Context, Model } from "@earendil-works/pi-ai"
import type { MutableModels } from "@earendil-works/pi-ai/models"
import { createAssistantMessageEventStream } from "@earendil-works/pi-ai/utils/event-stream"
import { CACHE_BLOCKS_HEADER } from "../chief-brain/cache-prefix.ts"
import { CreditsGate } from "../chief-brain/credits-gate.ts"
import { reprice } from "./bedrock-price.ts"
import { creditsRequired, payerTeam } from "../credits.ts"
import type { Env } from "../env.ts"

/**
 * The model gateway (hq-1f PROTOCOL.md `model/stream`, Lawrence 2026-10-15: Cloud brains call models
 * through the host): one place that owns the routes (routes.ts), the keys, the paid-model gate and
 * prepaid credits, so no brain implementation can skip billing. In the Worker, ChiefBrainDO uses it
 * in process: models.ts hands pi-durable a models object whose `streamSimple` (the turn loop) and
 * `completeSimple` (the compactor) go through here.
 *
 * Per turn call (1f-C's rules, credits.ts / credits-gate.ts):
 * - Before the upstream request: reserve the call's maximum price under a request id unique per
 *   attempt (`<brain object>:<run>:<generation>:<n>`). Refused (out of credits, meter unreachable):
 *   nothing is sent; the stream ends in an error the turn reports, and the conversation gets the one
 *   out-of-credits notice (`notice`).
 * - After every sent response, also a failed one: settle the real provider cost (the Claude route: the
 *   Bedrock price, bedrock-price.ts; other routes: pi-ai usage cost).
 *   A request that was sent but never answered keeps its hold (the meter charges it after an hour).
 * - A reservation is released only when the upstream request was never sent.
 * Compactor calls are charged after the fact (settle without reserve: charged once).
 *
 * Every terminal message's usage goes to `usage` (the run's input, output and cache tokens + cost).
 */
export interface GatewayWho {
  /** The running turn's run id and model request (pi-durable generation task) id. */
  readonly run: string | undefined
  readonly generation: string | undefined
  readonly conversation: string | undefined
  readonly agent: string | null
  readonly owner: string | null
  /** The running turn's cache mark indices for its first user message (chief-brain/cache-prefix.ts), "" or undefined: none. */
  readonly cache_blocks?: string | undefined
}
export interface GatewayUsage {
  readonly input: number
  readonly output: number
  readonly cache_read: number
  readonly cache_write: number
  readonly cost_usd: number
}
export interface GatewayHooks {
  /** Every event of a turn call (the live frames, brain-stream.ts). */
  readonly event?: (e: AssistantMessageEvent) => void
  /** A terminal turn message's usage, for its run. */
  readonly usage?: (run: string, u: GatewayUsage) => void
  /** A turn call that ended in an error: the provider's message (no secret), for the run's error. */
  readonly failed?: (run: string, message: string) => void
  /** The upstream region that answered a turn call (the Claude route's x-bedrock-region), for its run. */
  readonly region?: (run: string, region: string) => void
  /** A step of a run's first turn call (first write per run wins, as request_at and first_token_at): reserved (credits held), upstream (request sent), headers (the route answered). */
  readonly mark?: (run: string, name: "reserved" | "upstream" | "headers") => void
  /** Post the out-of-credits notice once in the conversation (the team was told only once). */
  readonly notice?: (conversation: string, text: string) => Promise<void>
}

/** The pi-ai provider name of the in-process test model: never charged. */
const FAKE_PROVIDER = "fake"
/** models.ts's provider id of the Claude route. */
const CLAUDE_ROUTE_PROVIDER = "claude-david"
const nameOf = (m: Model<Api>) => (m.provider === FAKE_PROVIDER ? "fake" : `${m.provider}/${m.id}`)
const safeId = (s: string) => s.replace(/[^A-Za-z0-9._:-]/g, "_").slice(0, 128)

export const usageOf = (m: AssistantMessage): GatewayUsage => {
  const u = (m.usage ?? {}) as { input?: number; output?: number; cacheRead?: number; cacheWrite?: number; cost?: { total?: number } }
  const n = (v: unknown) => (typeof v === "number" && Number.isFinite(v) && v > 0 ? v : 0)
  return { input: n(u.input), output: n(u.output), cache_read: n(u.cacheRead), cache_write: n(u.cacheWrite), cost_usd: n(u.cost?.total) }
}

const failed = (model: Model<Api>, text: string): AssistantMessage =>
  ({ role: "assistant", content: [], api: model.api, provider: model.provider, model: model.id, stopReason: "error", errorMessage: text, timestamp: Date.now(), usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } }) as unknown as AssistantMessage

export class ModelGatewayLive {
  private readonly gate: CreditsGate
  /** Each call gets its own credits key, so a retry never settles or reuses another call's hold. */
  private calls = 0

  constructor(
    private readonly env: Env,
    /** Unique per brain object (its Durable Object id): pi-durable task ids are unique only inside one harness. */
    private readonly scope: string,
    private readonly upstream: MutableModels,
    private readonly who: () => GatewayWho,
    private readonly hooks: GatewayHooks = {}
  ) {
    this.gate = new CreditsGate(env, safeId(scope), () => {
      const w = this.who()
      return { team: payerTeam(w.owner ?? ""), chief: w.agent, conversation: w.conversation ?? null }
    })
  }

  /** The turn loop's call: credits around the upstream request, usage and live events out. */
  streamSimple(model: Model<Api>, context: Context, options?: Parameters<MutableModels["streamSimple"]>[2]): AssistantMessageEventStream {
    const out = createAssistantMessageEventStream()
    const w = this.who()
    const key = safeId(`${w.run ?? "norun"}:${w.generation ?? "nogen"}:${++this.calls}`)
    const name = nameOf(model)
    const priced = creditsRequired(this.env, name)
    void (async () => {
      let sent = false
      try {
        if (priced && !w.owner) return this.finish(out, failed(model, "credits: this chief has no owner to bill"))
        if (priced) {
          const g = await this.gate.before(key, model, name, context.messages)
          if (!g.ok) {
            if (g.refused) return this.finish(out, failed(model, g.refused))
            const text = `credits.exhausted: available ${g.available_usd} USD, this call needs up to ${g.needed_usd} USD`
            if (w.conversation) await this.noticeOnce(w.conversation)
            return this.finish(out, failed(model, text))
          }
          if (w.run) this.hooks.mark?.(w.run, "reserved")
        }
        // Only the Claude route takes the payer team, chief and call id (its service key needs them); no other provider sees them.
        const routed = model.provider === CLAUDE_ROUTE_PROVIDER
        const headers = routed ? { ...(options?.headers ?? {}), "x-cmux-team-id": payerTeam(w.owner ?? ""), ...(w.agent ? { "x-cmux-chief-id": w.agent } : {}), "x-request-id": safeId(`${this.scope}:${key}`), ...(w.cache_blocks ? { [CACHE_BLOCKS_HEADER]: w.cache_blocks } : {}) } : options?.headers
        const onResponse = (r: { headers?: Record<string, string> }, m: Model<Api>) => {
          if (w.run) this.hooks.mark?.(w.run, "headers")
          const region = r.headers?.["x-bedrock-region"]
          if (region && w.run) this.hooks.region?.(w.run, region.slice(0, 32))
          return (options as { onResponse?: (r: unknown, m: Model<Api>) => unknown } | undefined)?.onResponse?.(r, m)
        }
        if (w.run) this.hooks.mark?.(w.run, "upstream")
        const src = this.upstream.streamSimple(model, context, { ...options, ...(headers ? { headers } : {}), onResponse } as typeof options)
        sent = true
        // The terminal event goes out after the charge: pi-durable may retry as soon as it sees it.
        let terminal: AssistantMessageEvent | undefined
        for await (const e of src) {
          try {
            this.hooks.event?.(e)
          } catch {}
          if (e.type === "done" || e.type === "error") terminal = e
          else out.push(e)
        }
        // The Claude route's cost is what Bedrock charges (bedrock-price.ts), not the catalog's first-party price.
        const got = await src.result()
        const final = routed ? reprice(got, this.env.CHIEF_BRAIN_CACHE_TTL) : got
        if ((final.stopReason === "error" || terminal?.type === "error") && w.run) this.hooks.failed?.(w.run, String(final.errorMessage ?? "model error").replace(/\s+/g, " ").slice(0, 400))
        if (priced) await this.gate.after(key, final).catch((e: unknown) => console.warn(JSON.stringify({ msg: "model_gateway.settle_failed", call: key, error: String(e).slice(0, 200) })))
        if (w.run) this.hooks.usage?.(w.run, usageOf(final))
        // The terminal event carries the repriced message: pi-ai resolves result() from it.
        if (terminal?.type === "done") out.push({ ...terminal, message: final })
        else if (terminal?.type === "error") out.push({ ...terminal, error: final })
        out.end(final)
      } catch (e) {
        if (priced && !sent) await this.gate.release(key).catch(() => undefined)
        const text = e instanceof Error ? e.message.slice(0, 300) : String(e).slice(0, 300)
        if (w.run) this.hooks.failed?.(w.run, text)
        this.finish(out, failed(model, text))
      }
    })()
    return out
  }

  /** The compactor's (and the hand classifier's) call: the same credits gate as a turn (reserve, then settle), so a team with no credits gets no paid call. */
  async completeSimple(model: Model<Api>, context: Context, options?: Parameters<MutableModels["completeSimple"]>[2]): Promise<AssistantMessage> {
    const name = nameOf(model)
    const priced = creditsRequired(this.env, name)
    const w = this.who()
    if (priced && !w.owner) return failed(model, "credits: this chief has no owner to bill")
    const key = safeId(`compact:${crypto.randomUUID()}`)
    if (priced) {
      const g = await this.gate.before(key, model, name, context.messages)
      if (!g.ok) return failed(model, g.refused ?? `credits.exhausted: available ${g.available_usd} USD, this call needs up to ${g.needed_usd} USD`)
    }
    // The service-key route needs the payer team, chief and call id on every call, the compactor's too (claude-auth.ts signedFetch).
    const routed = model.provider === CLAUDE_ROUTE_PROVIDER
    // The cache mark indices (the compactor's) are for the Claude route's body conversion only.
    const { [CACHE_BLOCKS_HEADER]: _marks, ...rest } = (options?.headers ?? {}) as Record<string, string>
    const headers = routed ? { ...(options?.headers ?? {}), "x-cmux-team-id": payerTeam(w.owner ?? ""), ...(w.agent ? { "x-cmux-chief-id": w.agent } : {}), "x-request-id": safeId(`${this.scope}:${key}`) } : options?.headers ? rest : undefined
    let reply: AssistantMessage
    try {
      const got = await this.upstream.completeSimple(model, context, { ...options, ...(headers ? { headers } : {}) } as typeof options)
      reply = routed ? reprice(got, this.env.CHIEF_BRAIN_CACHE_TTL) : got
    } catch (e) {
      if (priced) await this.gate.release(key).catch(() => undefined)
      throw e
    }
    if (priced) await this.gate.after(key, reply).catch((e: unknown) => console.warn(JSON.stringify({ msg: "model_gateway.compactor_settle_failed", call: key, error: String(e).slice(0, 200) })))
    return reply
  }

  private async noticeOnce(conversation: string): Promise<void> {
    const text = await this.gate.notice(conversation).catch(() => null)
    if (text) await this.hooks.notice?.(conversation, text).catch(() => undefined)
  }

  private finish(out: AssistantMessageEventStream, message: AssistantMessage): void {
    out.push({ type: "error", reason: "error", error: message })
    out.end(message)
  }

  /** A models object for pi-durable: turn and compactor calls through the gateway, every other read on the upstream. */
  models(): MutableModels {
    return new Proxy(this.upstream, {
      get: (target, key) => {
        if (key === "streamSimple") return (m: Model<Api>, c: Context, o?: Parameters<MutableModels["streamSimple"]>[2]) => this.streamSimple(m, c, o)
        if (key === "completeSimple") return (m: Model<Api>, c: Context, o?: Parameters<MutableModels["completeSimple"]>[2]) => this.completeSimple(m, c, o)
        const v = Reflect.get(target, key, target) as unknown
        return typeof v === "function" ? (v as (...a: Array<unknown>) => unknown).bind(target) : v
      }
    }) as MutableModels
  }
}
