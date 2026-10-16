import { payerTeam } from "../credits.ts"
import type { Env } from "../env.ts"
import { CreditsGate } from "./credits-gate.ts"
import type { GatewayHooks, GatewayWho } from "../model-gateway/gateway.ts"
import { chiefPrincipal, postText } from "./brain-io.ts"
import { addUsage } from "./brain-runs.ts"
import { liveOf } from "./brain-stream.ts"
import type { BrainConfig } from "./brain-store.ts"

/**
 * How a ChiefBrainDO plugs into the model gateway (model-gateway/gateway.ts): who calls (the running
 * turn, its model request, the chief and owner), and the gateway's hooks: model events become live
 * frames (brain-stream.ts), usage is summed on the run (cb_usage), and the out-of-credits notice is
 * posted once as the chief.
 */
export interface BrainNow {
  readonly run: string | undefined
  readonly conversation: string | undefined
  readonly config: BrainConfig
}

export const gatewayOptions = (ctx: DurableObjectState, env: Env, now: () => BrainNow): { who: () => GatewayWho; hooks: GatewayHooks } => {
  const live = liveOf(ctx, env, () => {
    const n = now()
    return { run: n.run, conversation: n.conversation, agent: n.config.agent }
  })
  // First request and first token of each run (the first write of each mark wins): Run.timing.
  live.onMark = (run, mark, at) => void ctx.storage.sql.exec(`INSERT INTO cb_timing (turn, ${mark === "request" ? "request_at" : "first_token_at"}) VALUES (?, ?) ON CONFLICT (turn) DO UPDATE SET ${mark === "request" ? "request_at = COALESCE(request_at, excluded.request_at)" : "first_token_at = COALESCE(first_token_at, excluded.first_token_at)"}`, run, at)
  return {
    who: () => {
      const n = now()
      return { run: n.run, generation: live.generationId, conversation: n.conversation, agent: n.config.agent, owner: n.config.owner }
    },
    hooks: {
      event: (e) => live.event(e),
      usage: (run, u) => addUsage(ctx.storage.sql, run, u),
      // The newest model error of the run (Run.error names it when the run fails).
      failed: (run, message) => void ctx.storage.sql.exec(`INSERT INTO cb_run_error (turn, text) VALUES (?, ?) ON CONFLICT (turn) DO UPDATE SET text = excluded.text`, run, message),
      region: (run, region) => void ctx.storage.sql.exec(`INSERT INTO cb_marks (turn, mark, at) VALUES (?, ?, ?) ON CONFLICT DO NOTHING`, run, `region:${region}`, Date.now()),
      notice: async (conversation, text) => {
        const { agent, owner } = now().config
        if (agent && owner) await postText(env, chiefPrincipal(agent, owner), conversation, text, `credits-notice:${agent}:${conversation}:${new Date().toISOString().slice(0, 13)}`)
      }
    }
  }
}

const gateOf = (env: Env, config: BrainConfig) => new CreditsGate(env, `admit:${config.agent ?? ""}`, () => ({ team: payerTeam(config.owner ?? ""), chief: config.agent, conversation: null }))

/**
 * Before a turn starts (the settings object's admit): the team has at least the minimum hold for its
 * model (credits.ts). "unavailable" (the meter did not answer) is not "no credits": the turn waits.
 */
export const creditsCanStart = (env: Env, config: BrainConfig): Promise<"ok" | "exhausted" | "unavailable"> =>
  !config.owner ? Promise.resolve("exhausted") : gateOf(env, config).canStart(config.model).then((ok) => (ok ? "ok" : "exhausted"), () => "unavailable")

/** A turn refused for credits: the one out-of-credits notice in `conversation`, as the chief. */
export const creditsNotice = async (env: Env, config: BrainConfig, conversation: string): Promise<void> => {
  const text = await gateOf(env, config).notice(conversation).catch(() => null)
  if (text && config.agent && config.owner) await postText(env, chiefPrincipal(config.agent, config.owner), conversation, text, `credits-notice:${config.agent}:${conversation}:${new Date().toISOString().slice(0, 13)}`).catch(() => undefined)
}

/** The notice a person sees when a turn failed after its retries (no vendor names, no detail). */
export const TURN_FAILED_NOTICE = "I could not reach the model, so I stopped here. Please try again."

/**
 * A failed turn is never silent: one short notice as the chief in the turn's conversation (once per
 * run, by its idempotency key). Not for a credits refusal: that has its own notice (the gateway's).
 */
export const turnFailedNotice = async (env: Env, config: BrainConfig, conversation: string, run: string, reason: string, error: string | undefined): Promise<void> => {
  if (/credits/i.test(`${reason} ${error ?? ""}`) || !config.agent || !config.owner) return
  const principal = chiefPrincipal(config.agent, config.owner)
  // Over today's model limit: say why, once per conversation per UTC day; later refused turns stay quiet.
  if (/daily_cap/.test(reason)) {
    const day = new Date().toISOString().slice(0, 10)
    return void (await postText(env, principal, conversation, DAILY_CAP_NOTICE, `daily-cap:${config.agent}:${conversation}:${day}`).catch(() => undefined))
  }
  await postText(env, principal, conversation, TURN_FAILED_NOTICE, `turn-failed:${config.agent}:${run}`).catch(() => undefined)
}

/** The notice for a Chief over today's model limit (no vendor names). */
export const DAILY_CAP_NOTICE = "I reached today's model limit for this account, so I cannot answer until 00:00 UTC. Ask an admin to raise it if you need more today."
