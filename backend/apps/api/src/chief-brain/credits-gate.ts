import type { Api, AssistantMessage, Model } from "@earendil-works/pi-ai"
import { Effect } from "effect"
import { Credits, CreditsLive, creditsMinReserveUsd, creditsRequired, maxCallCostUsd, type Reservation } from "../credits.ts"
import { topupLink } from "../credits-checkout.ts"
import type { Env } from "../env.ts"

/**
 * The hosted Chief's credits gate (credits.ts) for the brain's pi-durable GenerationTask hooks:
 *
 *   beforeRequest: const g = await gate.before(String(api.taskId), model, modelName, messages)
 *                  if (!g.ok) throw new CreditsRefusedError(g)      // stops the turn, no provider call
 *   afterResponse: await gate.after(String(api.taskId), message)    // charges usage.cost.total x margin
 *   aborted BEFORE the request was sent: await gate.release(String(api.taskId))   (after the send, never
 *                  release: keep the hold, the meter charges it in full after an hour)
 *   turn failed with CreditsRefusedError: const text = await gate.notice(conversation); if (text) post it once
 *
 * Request ids are `<scope>:<taskId>:<attempt>`, so every provider attempt (pi-durable retries call
 * beforeRequest again) is held and charged once. An attempt that was sent but got no afterResponse
 * (a stream error, an eviction) keeps its hold, which the meter charges in full after an hour; the
 * next attempt holds a new id. That can charge a lost attempt above its real cost, never below. `scope` must be unique per brain object (its DO id):
 * pi-durable task ids are unique only inside one harness. A hold the brain never settles (eviction
 * mid-call) is charged in full by the team meter after one hour.
 */
export class CreditsRefusedError extends Error {
  readonly code = "credits.exhausted"
  constructor(readonly detail: { readonly available_usd: number; readonly needed_usd: number }) {
    super(`out of Cloud credits (available ${detail.available_usd} USD, this call needs up to ${detail.needed_usd} USD)`)
  }
}

/**
 * Not ok: out of credits (`available_usd` < `needed_usd`), or `refused` names another reason the
 * meter gave no hold (the per-chief call cap, credits.ts CreditsRateLimited); send nothing either way.
 */
export type GateResult = { readonly ok: true; readonly skipped?: true } | { readonly ok: false; readonly available_usd: number; readonly needed_usd: number; readonly refused?: string }

const MAX_ATTEMPT_IDS = 20

export class CreditsGate {
  private readonly open = new Map<string, Reservation>()
  private readonly attempt = new Map<string, number>()

  constructor(
    private readonly env: Env,
    private readonly scope: string,
    /** Who pays and for which chief and conversation, read at call time (payerTeam(owner, team) in credits.ts). */
    private readonly who: () => { readonly team: string; readonly chief: string | null; readonly conversation: string | null }
  ) {}

  private run<A, E>(program: Effect.Effect<A, E, Credits>): Promise<A> {
    return Effect.runPromise(program.pipe(Effect.provide(CreditsLive(this.env))))
  }

  /** Before one provider request: hold its maximum price. Not ok = out of credits (send nothing). */
  async before(taskId: string, model: Model<Api>, modelName: string, messages: ReadonlyArray<unknown>): Promise<GateResult> {
    if (!creditsRequired(this.env, modelName)) return { ok: true, skipped: true }
    if (this.open.has(taskId)) {
      // The previous attempt was sent and never answered: its hold stays (charged in full by expiry).
      this.open.delete(taskId)
      this.attempt.set(taskId, (this.attempt.get(taskId) ?? 0) + 1)
    }
    const { team, chief, conversation } = this.who()
    const maxCostUsd = maxCallCostUsd(model.cost, JSON.stringify(messages).length, model.maxTokens || 16_384)
    for (let i = 0; i < MAX_ATTEMPT_IDS; i++) {
      const n = this.attempt.get(taskId) ?? 0
      const request = `${this.scope}:${taskId}:${n}`
      const r = await this.run(
        Credits.use((c) => c.reserve({ team, request, chief, conversation, maxCostUsd })).pipe(
          Effect.map((res) => ({ ok: true as const, res })),
          Effect.catchTag("CreditsExhausted", (e) => Effect.succeed({ ok: false as const, available_usd: e.available_usd, needed_usd: e.needed_usd })),
          Effect.catchTag("CreditsRateLimited", (e) => Effect.succeed({ ok: false as const, available_usd: 0, needed_usd: 0, refused: e.text })),
          Effect.catchTag("CreditsAlreadySettled", () => Effect.succeed(null))
        )
      )
      // Already charged, or held by an attempt from before this object restarted: use the next id.
      if (r === null || (r.ok && r.res.replayed)) {
        this.attempt.set(taskId, n + 1)
        continue
      }
      if (!r.ok) return r
      this.open.set(taskId, r.res)
      return { ok: true }
    }
    throw new Error("credits: no free request id for this task")
  }

  /** After the provider's terminal message: charge its real cost (pi-ai usage.cost.total) x margin. */
  async after(taskId: string, message: AssistantMessage): Promise<void> {
    const res = this.open.get(taskId)
    if (!res) return
    const cost = Number(message.usage?.cost?.total ?? 0)
    await this.run(Credits.use((c) => c.settle(res, Number.isFinite(cost) && cost > 0 ? cost : 0)))
    this.open.delete(taskId)
    this.attempt.set(taskId, (this.attempt.get(taskId) ?? 0) + 1)
  }

  /** The request never reached a provider (aborted before sending): drop the hold, charge nothing. */
  async release(taskId: string): Promise<void> {
    const res = this.open.get(taskId)
    if (!res) return
    await this.run(Credits.use((c) => c.release(res)))
    this.open.delete(taskId)
  }

  /**
   * The one out-of-credits notice for `conversation`: the text to post, or null when this
   * conversation was already told since the team last had credits.
   */
  async notice(conversation: string): Promise<string | null> {
    const { team } = this.who()
    const first = await this.run(Credits.use((c) => c.noticeOnce(team, conversation)))
    if (!first) return null
    return creditsNotice(await topupLink(this.env, this.env.CLOUD_API_ORIGIN ?? "", team))
  }

  /** Before a turn starts: does the team have at least the minimum hold? (A cheap early stop; `before` still holds per call.) */
  async canStart(modelName: string): Promise<boolean> {
    if (!creditsRequired(this.env, modelName)) return true
    const { team } = this.who()
    const b = await this.run(Credits.use((c) => c.balance(team, 1)))
    return b.available_usd > 0 && b.available_usd >= creditsMinReserveUsd(this.env)
  }
}

/** The notice text (no vendor names). */
export const creditsNotice = (link: string | null): string =>
  link
    ? `This team is out of Cloud credits, so I stopped here. Add credits to continue: ${link}`
    : "This team is out of Cloud credits, so I stopped here. Ask a team admin to add credits in billing."
