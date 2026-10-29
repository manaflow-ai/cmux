import { Context, Effect, Layer, Schema } from "effect"
import { personalTeamIdFor } from "./domains/user.ts"
import type { Env } from "./env.ts"
import type { ChiefCallCap, CreditReserve } from "./usage-credits.ts"

/**
 * Prepaid credits for hosted Cloud Chief model spend (Lawrence 2026-10-15: the hosted Chief is
 * team-first and "people must load credits to use it"). The balance lives on the team's
 * UsageMeterDO (usage-credits.ts); this module is the Worker-side service the brain calls around
 * every model call:
 *
 *   reserve({team, request, chief, conversation, maxCostUsd}) -> Reservation   (refused below the max)
 *   settle(reservation, actualCostUsd)                        -> charged once per request id
 *   release(reservation)                                      -> the call never reached a provider
 *
 * Price = provider cost (pi-ai's model cost table: AssistantMessage.usage.cost.total) x margin
 * (CHIEF_CREDITS_MARGIN, default 1 = pass-through like the usage bill). Idempotent by request id:
 * the same id reserves once and is charged once; an unsettled hold is charged in full after one hour.
 */

const MICROS = 1_000_000

/** The team a hosted Chief bills: its team when it has one, else its owner's personal team. */
export const payerTeam = (owner: string, team?: string | null): string => team ?? personalTeamIdFor(owner)

/** CHIEF_CREDITS_MARGIN: a finite number >= 1 (a price below our cost is refused as a misconfiguration). */
export const creditsMargin = (env: Pick<Env, "CHIEF_CREDITS_MARGIN">): number => {
  const n = Number(env.CHIEF_CREDITS_MARGIN ?? "1")
  return Number.isFinite(n) && n >= 1 && n <= 10 ? n : 1
}

/** The least a call reserves (USD), so a model whose table price is 0 still needs a positive balance. */
export const creditsMinReserveUsd = (env: Pick<Env, "CHIEF_CREDITS_MIN_RESERVE_USD">): number => {
  const n = Number(env.CHIEF_CREDITS_MIN_RESERVE_USD ?? "0.01")
  return Number.isFinite(n) && n >= 0 ? n : 0.01
}

/**
 * Credits gate every model call except the in-process test model (it never costs anything).
 * CHIEF_CREDITS_ENFORCE="0" turns the gate off on development and staging only: production always
 * enforces, whatever the var says (hq-1f 2026-10-15, the precondition for Chief brains in production).
 */
export const creditsRequired = (env: Pick<Env, "CHIEF_CREDITS_ENFORCE" | "ENVIRONMENT">, modelName: string): boolean =>
  modelName !== "fake" && (env.ENVIRONMENT === "production" || env.CHIEF_CREDITS_ENFORCE !== "0")

/** pi-ai prices are USD per million tokens. */
export interface ModelCost {
  readonly input: number
  readonly output: number
  readonly cacheRead: number
  readonly cacheWrite: number
}

/**
 * A call's maximum provider cost (USD) before it is sent: every input token at the dearest input
 * rate (a cache write) and the full output budget. Input tokens are estimated as one per 3 bytes of
 * the request text (conservative for English and code), so the hold is above the real price.
 */
export const maxCallCostUsd = (cost: ModelCost, inputChars: number, maxOutputTokens: number): number => {
  const inputTokens = Math.ceil(Math.max(0, inputChars) / 3)
  const inRate = Math.max(cost.input, cost.cacheWrite, cost.cacheRead)
  return (inputTokens * inRate + Math.max(0, maxOutputTokens) * cost.output) / MICROS
}

export interface Reservation {
  readonly team: string
  readonly request: string
  readonly chief: string | null
  readonly conversation: string | null
  readonly held_usd: number
  readonly margin: number
  /** The id already had an open hold (a repeated reserve of the same request). */
  readonly replayed: boolean
}

export interface Balance {
  readonly team: string
  readonly balance_usd: number
  readonly held_usd: number
  readonly available_usd: number
  readonly chiefs: ReadonlyArray<{ readonly chief: string; readonly spent_usd: number; readonly calls: number; readonly last_at: number }>
  readonly entries: ReadonlyArray<{ readonly id: string; readonly kind: string; readonly usd: number; readonly chief: string | null; readonly at: number; readonly reason: string | null }>
  readonly window_days: number
}

/** The team has too little credit for this call (`available_usd` < `needed_usd`, or nothing left). */
export class CreditsExhausted extends Schema.TaggedError<CreditsExhausted>()("CreditsExhausted", {
  team: Schema.String,
  balance_usd: Schema.Number,
  available_usd: Schema.Number,
  needed_usd: Schema.Number
}) {}

/** This chief started too many paid model calls in a window (usage-credits.ts ChiefCallCap): no hold, no call. */
export class CreditsRateLimited extends Schema.TaggedError<CreditsRateLimited>()("CreditsRateLimited", {
  chief: Schema.String,
  calls: Schema.Number,
  limit: Schema.Number,
  window_s: Schema.Number,
  retry_after_s: Schema.Number
}) {
  /** The refusal as the caller sees it; the compactor reads "retry after N s" as its wait (compactor.ts retryAfterMs). */
  get text(): string {
    return `rate_limited: chief ${this.chief} made ${this.calls} paid model calls in the last ${this.window_s} s (cap ${this.limit}); retry after ${this.retry_after_s} s`
  }
}

/** Default per-chief caps: far above a busy Chief (a turn's tool steps plus its compaction), far below a loop. */
export const CHIEF_CALLS_PER_MINUTE = 120
export const CHIEF_CALLS_PER_HOUR = 2400

/** CHIEF_MODEL_CALLS_PER_MINUTE / _PER_HOUR: positive integers; anything else is the default (the cap is never off). */
export const chiefCallCap = (env: Pick<Env, "CHIEF_MODEL_CALLS_PER_MINUTE" | "CHIEF_MODEL_CALLS_PER_HOUR">): ChiefCallCap => {
  const pick = (v: string | undefined, d: number) => {
    const n = Number(v)
    return Number.isInteger(n) && n > 0 ? n : d
  }
  return { perMinute: pick(env.CHIEF_MODEL_CALLS_PER_MINUTE, CHIEF_CALLS_PER_MINUTE), perHour: pick(env.CHIEF_MODEL_CALLS_PER_HOUR, CHIEF_CALLS_PER_HOUR) }
}

/** This request id was already charged: a new attempt needs a new id. */
export class CreditsAlreadySettled extends Schema.TaggedError<CreditsAlreadySettled>()("CreditsAlreadySettled", { request: Schema.String }) {}

/** The team's meter did not answer (retryable; never treated as "has credit"). */
export class CreditsUnavailable extends Schema.TaggedError<CreditsUnavailable>()("CreditsUnavailable", { message: Schema.String }) {}

export interface CreditsShape {
  readonly reserve: (input: { readonly team: string; readonly request: string; readonly chief?: string | null; readonly conversation?: string | null; readonly maxCostUsd: number }) => Effect.Effect<Reservation, CreditsExhausted | CreditsAlreadySettled | CreditsRateLimited | CreditsUnavailable>
  readonly settle: (reservation: Reservation, actualCostUsd: number) => Effect.Effect<{ readonly charged: boolean; readonly balance_usd: number }, CreditsUnavailable>
  readonly release: (reservation: Reservation) => Effect.Effect<void, CreditsUnavailable>
  readonly balance: (team: string, windowDays?: number) => Effect.Effect<Balance, CreditsUnavailable>
  /** True the first time this conversation is told the team is out of credits, until money comes in. */
  readonly noticeOnce: (team: string, conversation: string) => Effect.Effect<boolean, CreditsUnavailable>
}

export class Credits extends Context.Service<Credits, CreditsShape>()("cmux/Credits") {}

const toMicros = (usd: number) => Math.round(Math.max(0, usd) * MICROS)
const toUsd = (micros: number) => Math.round(micros) / MICROS

/** The service over the Worker's UsageMeterDO namespace. */
export const makeCredits = (env: Env): CreditsShape => {
  const meter = (team: string) => env.USAGE_METER_DO.get(env.USAGE_METER_DO.idFromName(team))
  const call = <A>(f: () => Promise<A>) => Effect.tryPromise({ try: f, catch: (e) => new CreditsUnavailable({ message: String(e).slice(0, 200) }) })
  const margin = creditsMargin(env)
  const floor = creditsMinReserveUsd(env)
  const cap = chiefCallCap(env)
  return {
    reserve: ({ team, request, chief = null, conversation = null, maxCostUsd }) =>
      Effect.gen(function* () {
        const held = Math.max(maxCostUsd * margin, floor)
        const r = yield* call(() => meter(team).creditReserve(team, request, toMicros(held), chief, conversation, cap) as unknown as Promise<CreditReserve>)
        if (r.ok) return { team, request, chief, conversation, held_usd: toUsd(r.held_micros), margin, replayed: r.replayed } satisfies Reservation
        if (r.code === "credits.settled") return yield* Effect.fail(new CreditsAlreadySettled({ request }))
        if (r.code === "credits.rate_limited") return yield* Effect.fail(new CreditsRateLimited({ chief: chief ?? "", calls: r.calls, limit: r.limit, window_s: r.window_s, retry_after_s: r.retry_after_s }))
        return yield* Effect.fail(new CreditsExhausted({ team, balance_usd: toUsd(r.balance_micros), available_usd: toUsd(r.available_micros), needed_usd: toUsd(r.needed_micros) }))
      }),
    settle: (res, actualCostUsd) =>
      call(() => meter(res.team).creditSettle(res.team, res.request, toMicros(actualCostUsd * res.margin), toMicros(actualCostUsd), res.chief, res.conversation)).pipe(
        Effect.map((r) => ({ charged: r.charged, balance_usd: toUsd(r.balance_micros) }))
      ),
    release: (res) => call(() => meter(res.team).creditRelease(res.team, res.request)).pipe(Effect.asVoid),
    balance: (team, windowDays = 30) =>
      call(() => meter(team).creditBalance(team, Date.now() - windowDays * 24 * 3600_000, 20)).pipe(
        Effect.map((b) => ({
          team,
          balance_usd: toUsd(b.balance_micros),
          held_usd: toUsd(b.held_micros),
          available_usd: toUsd(b.available_micros),
          chiefs: b.chiefs.map((c) => ({ chief: c.chief, spent_usd: toUsd(c.micros), calls: c.calls, last_at: c.last_at })),
          entries: b.entries.map((e) => ({ id: e.key, kind: e.kind, usd: toUsd(e.micros), chief: e.chief, at: e.at, reason: e.reason })),
          window_days: windowDays
        }))
      ),
    noticeOnce: (team, conversation) => call(() => meter(team).creditNoticeOnce(team, conversation))
  }
}

export const CreditsLive = (env: Env) => Layer.succeed(Credits)(makeCredits(env))
