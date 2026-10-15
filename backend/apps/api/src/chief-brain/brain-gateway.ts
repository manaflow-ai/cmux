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
  return {
    who: () => {
      const n = now()
      return { run: n.run, generation: live.generationId, conversation: n.conversation, agent: n.config.agent, owner: n.config.owner }
    },
    hooks: {
      event: (e) => live.event(e),
      usage: (run, u) => addUsage(ctx.storage.sql, run, u),
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
