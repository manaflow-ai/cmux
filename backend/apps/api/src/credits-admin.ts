import { Effect } from "effect"
import { makeCredits } from "./credits.ts"
import { personalTeamIdFor, stackTeamIdFor, userIdFor } from "./domains/user.ts"
import type { Env } from "./env.ts"
import { readRawBody, timingSafeEqual } from "./ingress/verify.ts"

/**
 * Operator credits (prepaid Cloud Chief credits, credits.ts): grants for dogfood and support, and a
 * team's balance read. `POST /v1/internal/credits`, `authorization: Bearer <BILLING_LEVELS_KEY>`:
 *
 *   {"action": "read",    "team" | "stack_team" | "stack_user" | "user": "<id>"}
 *   {"action": "grant",   <one team field>, "usd": <-10000..10000, not 0>, "actor": "<who>", "reason": "<why>", "key": "<unique>"}
 *   {"action": "dogfood", "actor": "<who>"}
 *
 * `grant` counts once per `key` (a repeat answers added: false). A negative amount is a correction.
 * `dogfood` grants CHIEF_CREDITS_DOGFOOD_USD to every entry of CHIEF_CREDITS_DOGFOOD (comma list of
 * `team_...` or `user_...` ids, a user meaning their personal team; config, never names in code),
 * once per entry and CHIEF_CREDITS_DOGFOOD_ROUND (raise the round to grant again). Every grant logs
 * `credits.grant` with the actor. The route is 404 without the key.
 */
export const CREDITS_ADMIN_PATH = "/v1/internal/credits"
const TEAM = /^team_[0-9a-f]{20}$/
const USER = /^user_[0-9a-f]{20}$/
const STACK_ID = /^[A-Za-z0-9._:-]{1,128}$/
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const ACTOR = /^[A-Za-z0-9._@:+-]{1,64}$/
const KEY = /^[A-Za-z0-9._:@+-]{1,128}$/
const MICROS = 1_000_000

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } })

type Body = { action?: unknown; team?: unknown; stack_team?: unknown; stack_user?: unknown; user?: unknown; usd?: unknown; actor?: unknown; reason?: unknown; key?: unknown }

/** The team a body names (exactly one of team, stack_team, stack_user, user). */
const teamOf = (env: Env, b: Body): string | null => {
  const named = [b.team, b.stack_team, b.stack_user, b.user].filter((v) => v !== undefined)
  if (named.length !== 1) return null
  if (typeof b.team === "string") return TEAM.test(b.team) ? b.team : null
  if (typeof b.user === "string") return USER.test(b.user) ? personalTeamIdFor(b.user) : null
  if (typeof b.stack_team === "string" && STACK_ID.test(b.stack_team)) return stackTeamIdFor(env.STACK_PROJECT_ID, UUID.test(b.stack_team) ? b.stack_team.toLowerCase() : b.stack_team)
  if (typeof b.stack_user === "string" && STACK_ID.test(b.stack_user)) return personalTeamIdFor(userIdFor(env.STACK_PROJECT_ID, b.stack_user))
  return null
}

/** CHIEF_CREDITS_DOGFOOD entries as team ids (a user id is their personal team); malformed entries are dropped and logged. */
export const dogfoodTeams = (env: Env): ReadonlyArray<string> => {
  const out = new Set<string>()
  for (const raw of (env.CHIEF_CREDITS_DOGFOOD ?? "").split(",").map((s) => s.trim()).filter(Boolean)) {
    if (TEAM.test(raw)) out.add(raw)
    else if (USER.test(raw)) out.add(personalTeamIdFor(raw))
    else console.warn(JSON.stringify({ msg: "credits.dogfood_entry_invalid" }))
  }
  return [...out]
}

const add = async (env: Env, team: string, key: string, micros: number, actor: string, reason: string | null) => {
  const meter = env.USAGE_METER_DO.get(env.USAGE_METER_DO.idFromName(team))
  const r = await meter.creditAdd(team, key, "grant", micros, actor, reason)
  console.log(JSON.stringify({ msg: r.added ? "credits.grant" : "credits.grant_repeat", team, key, usd: micros / MICROS, actor, reason, balance_usd: r.balance_micros / MICROS }))
  return { team, key, added: r.added, usd: micros / MICROS, balance_usd: r.balance_micros / MICROS }
}

export const handleCreditsAdmin = async (request: Request, env: Env): Promise<Response> => {
  const key = env.BILLING_LEVELS_KEY
  if (!key || key.length < 32) return json({ error: "not found" }, 404)
  if (request.method !== "POST") return json({ error: "method not allowed" }, 405)
  if (!timingSafeEqual((request.headers.get("authorization") ?? "").replace(/^Bearer /, ""), key)) return json({ error: "unauthorized" }, 401)
  const raw = await readRawBody(request, 4 * 1024)
  if (!raw.ok) return json({ error: raw.message }, raw.status)
  let b: Body
  try {
    b = JSON.parse(raw.text) as Body
  } catch {
    return json({ error: "body must be JSON" }, 400)
  }
  if (b.action === "read") {
    const team = teamOf(env, b)
    if (!team) return json({ error: "name exactly one of team, stack_team, stack_user, user" }, 400)
    return json(await Effect.runPromise(makeCredits(env).balance(team)))
  }
  if (typeof b.actor !== "string" || !ACTOR.test(b.actor)) return json({ error: "actor: who makes the call (1-64 of A-Z a-z 0-9 . _ @ : + -)" }, 400)
  if (b.action === "grant") {
    const team = teamOf(env, b)
    if (!team) return json({ error: "name exactly one of team, stack_team, stack_user, user" }, 400)
    if (typeof b.usd !== "number" || !Number.isFinite(b.usd) || b.usd === 0 || Math.abs(b.usd) > 10_000) return json({ error: "usd: a number in -10000..10000, not 0" }, 400)
    if (typeof b.key !== "string" || !KEY.test(b.key)) return json({ error: "key: a unique id for this grant (1-128 of A-Z a-z 0-9 . _ : @ + -)" }, 400)
    if (typeof b.reason !== "string" || b.reason.length < 3 || b.reason.length > 200) return json({ error: "reason: 3-200 characters" }, 400)
    return json(await add(env, team, `grant:${b.key}`, Math.round(b.usd * MICROS), b.actor, b.reason))
  }
  if (b.action === "dogfood") {
    const usd = Number(env.CHIEF_CREDITS_DOGFOOD_USD)
    if (!Number.isFinite(usd) || usd <= 0 || usd > 10_000) return json({ error: "CHIEF_CREDITS_DOGFOOD_USD is not set on this deployment" }, 409)
    const round = /^[A-Za-z0-9._-]{1,32}$/.test(env.CHIEF_CREDITS_DOGFOOD_ROUND ?? "") ? env.CHIEF_CREDITS_DOGFOOD_ROUND! : "1"
    const teams = dogfoodTeams(env)
    const grants = []
    for (const team of teams) grants.push(await add(env, team, `dogfood:${round}:${team}`, Math.round(usd * MICROS), b.actor, `dogfood round ${round}`))
    return json({ round, usd, grants })
  }
  return json({ error: "action: read, grant or dogfood" }, 400)
}
