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
  /** False: no live frames (a subagent's run; its parent shows "N subagents"). */
  readonly live?: boolean
}

export const gatewayOptions = (ctx: DurableObjectState, env: Env, now: () => BrainNow): { who: () => GatewayWho; hooks: GatewayHooks } => {
  const live = liveOf(ctx, env, () => {
    const n = now()
    return { run: n.run, conversation: n.live === false ? undefined : n.conversation, agent: n.config.agent }
  })
  // First request and first token of each run (the first write of each mark wins): Run.timing.
  live.onMark = (run, mark, at) => {
    // The first output of a generation after the run's hands continuation started (brain-turn.ts mark "continuation").
    if (mark === "generation_first_token") return void ctx.storage.sql.exec(`INSERT INTO cb_marks (turn, mark, at) SELECT ?, 'continuation_first_token', ? WHERE EXISTS (SELECT 1 FROM cb_marks WHERE turn = ? AND mark = 'continuation') ON CONFLICT DO NOTHING`, run, at, run)
    ctx.storage.sql.exec(`INSERT INTO cb_timing (turn, ${mark === "request" ? "request_at" : "first_token_at"}) VALUES (?, ?) ON CONFLICT (turn) DO UPDATE SET ${mark === "request" ? "request_at = COALESCE(request_at, excluded.request_at)" : "first_token_at = COALESCE(first_token_at, excluded.first_token_at)"}`, run, at)
  }
  return {
    who: () => {
      const n = now()
      const marks = n.run ? ctx.storage.sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = ?`, `marks:${n.run}`).toArray()[0]?.value : undefined
      return { run: n.run, generation: live.generationId, conversation: n.conversation, agent: n.config.agent, owner: n.config.owner, cache_blocks: marks }
    },
    hooks: {
      event: (e) => live.event(e),
      usage: (run, u) => addUsage(ctx.storage.sql, run, u),
      // The newest model error of the run (Run.error names it when the run fails).
      failed: (run, message) => void ctx.storage.sql.exec(`INSERT INTO cb_run_error (turn, text) VALUES (?, ?) ON CONFLICT (turn) DO UPDATE SET text = excluded.text`, run, message),
      mark: (run, name) => void ctx.storage.sql.exec(`INSERT INTO cb_marks (turn, mark, at) VALUES (?, ?, ?) ON CONFLICT DO NOTHING`, run, name, Date.now()),
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
 * A Cloud Chief turn (chief-brain-cc/turn.ts) that failed, by what happened (its reason `cc_<kind>: ...`): plain
 * words, no vendor names, and "send it again" only when nothing ran.
 */
export const CC_NOTICES = {
  timeout: "This turn ran out of time before I wrote a reply. Steps I started may have finished; ask me for the status.",
  model: "The model stopped with an error partway through this turn. Steps I started may have finished; ask me for the status.",
  stopped: "My turn machine stopped partway through this turn. Steps I started may have finished; ask me for the status.",
  model_before: "The model returned an error twice before I did anything, so nothing ran on this turn. Send it again in a minute.",
  machine: "My turn machine did not start after three tries, so nothing ran on this turn. Send it again in a minute."
} as const
/** The line before what a Cloud Chief turn that ended early had written, posted as its reply. */
export const CC_PARTIAL = {
  timeout: "I ran out of time on this turn; here is where I got to.",
  model: "The model stopped with an error partway through this turn; here is where I got to.",
  stopped: "My turn machine stopped partway through this turn; here is where I got to."
} as const

/**
 * A failed turn is never silent: one short notice as the chief in the turn's conversation (once per
 * run, by its idempotency key). Not for a credits refusal: that has its own notice (the gateway's).
 */
export const turnFailedNotice = async (env: Env, sql: SqlStorage, config: BrainConfig, conversation: string, run: string, reason: string, error: string | undefined): Promise<void> => {
  if (/credits/i.test(`${reason} ${error ?? ""}`) || !config.agent || !config.owner) return
  const principal = chiefPrincipal(config.agent, config.owner)
  // Over today's model limit: say why, once per conversation per UTC day (a marker in this brain object,
  // since a retry after the loop guard posts under another key); later refused turns stay quiet.
  if (/daily_cap/.test(reason)) {
    const marker = `notice.daily-cap:${conversation}:${new Date().toISOString().slice(0, 10)}`
    if (sql.exec(`SELECT 1 FROM cb_config WHERE name = ?`, marker).toArray().length > 0) return
    sql.exec(`INSERT INTO cb_config (name, value) VALUES (?, '1') ON CONFLICT (name) DO NOTHING`, marker)
    return void (await postNotice(env, principal, conversation, DAILY_CAP_NOTICE, marker).catch(() => undefined))
  }
  // A paid model this owner may not use here (claude-auth.ts ownerTurn): say so, not "could not reach".
  if (/owner_not_allowed|model_not_offered/.test(reason)) return void (await postNotice(env, principal, conversation, MODEL_UNAVAILABLE_NOTICE, `turn-failed:${config.agent}:${run}`).catch(() => undefined))
  // A Cloud Chief turn (chief-brain-cc/turn.ts): what happened, not "could not reach".
  const cc = /^cc_(timeout|model_before|model|stopped|machine):/.exec(reason)?.[1] as keyof typeof CC_NOTICES | undefined
  if (cc) return void (await postNotice(env, principal, conversation, CC_NOTICES[cc], `turn-failed:${config.agent}:${run}`).catch(() => undefined))
  await postNotice(env, principal, conversation, TURN_FAILED_NOTICE, `turn-failed:${config.agent}:${run}`).catch(() => undefined)
}

/** The notice for a turn whose paid model this owner may not use on this deployment (no vendor names). */
export const MODEL_UNAVAILABLE_NOTICE = "This model is not available for your team, so I stopped here."

/** The loop guard refuses a Chief that spoke under 2 s ago (agent_rate): a notice right after a reply waits that gap, twice at most. */
const NOTICE_GAP_MS = 2_500
const postNotice = async (env: Env, principal: ReturnType<typeof chiefPrincipal>, conversation: string, text: string, key: string, tries = 3): Promise<void> => {
  for (let i = 0; i < tries; i++) {
    const r = await postText(env, principal, conversation, text, i === 0 ? key : `${key}:r${i}`)
    if (r.ok || r.code !== "agent_rate") return
    await new Promise((resolve) => setTimeout(resolve, NOTICE_GAP_MS))
  }
}

/** The notice for a Chief over today's model limit (no vendor names). */
export const DAILY_CAP_NOTICE = "I reached today's model limit for this account, so I cannot answer until 00:00 UTC. Ask an admin to raise it if you need more today."
