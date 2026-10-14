import type { Env } from "./env.ts"
import { isIncludedMode } from "./billing-catalog.ts"
import { stackTeamIdFor } from "./domains/user.ts"
import { readRawBody, timingSafeEqual } from "./ingress/verify.ts"

/**
 * The operator's included-mode setting for a Team customer (cx-y79zh.1, Lawrence 2026-10-14): per team
 * (the plan's amount for the team) or per seat (the amount x paid seats). New teams are per team. A
 * change applies from the team's next period start, never inside a running period
 * (usage-billing-store.ts teamModeAt). Operator only: team admins never see or set it.
 *
 *   POST /v1/internal/billing/team-mode   authorization: Bearer <BILLING_LEVELS_KEY>
 *   {"stack_team": "<sign-in service team id>", "actor": "<operator>", "reason"?: "<why>"}            read
 *   {"stack_team": "<id>", "mode": "per_team" | "per_seat", "actor": "<operator>", "reason"?: "..."} set
 *
 * Every call logs `billing.team_mode.*` with the team, the modes before and after and the actor; every
 * change is also kept in the team's UsageMeterDO (usage_mode_setting). The route is 404 without the key.
 */
export const BILLING_TEAM_MODE_PATH = "/v1/internal/billing/team-mode"
const MAX_BODY = 4 * 1024
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const STACK_ID = /^[A-Za-z0-9._:-]{1,128}$/
const ACTOR = /^[A-Za-z0-9._@:+-]{1,64}$/

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } })

export const handleBillingTeamMode = async (request: Request, env: Env): Promise<Response> => {
  const key = env.BILLING_LEVELS_KEY
  if (!key || key.length < 32) return json({ error: "not found" }, 404)
  if (request.method !== "POST") return json({ error: "method not allowed" }, 405)
  const presented = (request.headers.get("authorization") ?? "").replace(/^Bearer /, "")
  if (!timingSafeEqual(presented, key)) return json({ error: "unauthorized" }, 401)
  const raw = await readRawBody(request, MAX_BODY)
  if (!raw.ok) return json({ error: raw.message }, raw.status)
  let body: { stack_team?: unknown; mode?: unknown; actor?: unknown; reason?: unknown }
  try {
    body = JSON.parse(raw.text) as typeof body
  } catch {
    return json({ error: "body must be JSON" }, 400)
  }
  if (typeof body?.stack_team !== "string" || !STACK_ID.test(body.stack_team)) return json({ error: "stack_team: the team's sign-in service id" }, 400)
  if (typeof body.actor !== "string" || !ACTOR.test(body.actor)) return json({ error: "actor: who makes the call (1-64 of A-Z a-z 0-9 . _ @ : + -)" }, 400)
  if (body.reason !== undefined && (typeof body.reason !== "string" || body.reason.length > 200)) return json({ error: "reason: at most 200 characters" }, 400)
  if (body.mode !== undefined && !isIncludedMode(body.mode)) return json({ error: "mode: per_team or per_seat" }, 400)
  const stackTeam = UUID.test(body.stack_team) ? body.stack_team.toLowerCase() : body.stack_team
  const team = stackTeamIdFor(env.STACK_PROJECT_ID, stackTeam)
  const meter = env.USAGE_METER_DO.get(env.USAGE_METER_DO.idFromName(team))
  const fields = { team, stack_team: stackTeam, actor: body.actor }
  if (body.mode === undefined) {
    const modes = await meter.includedModes(team)
    console.log(JSON.stringify({ msg: "billing.team_mode.read", ...fields }))
    return json({ team, stack_team: stackTeam, ...modes })
  }
  const reason = typeof body.reason === "string" ? body.reason : null
  const r = await meter.setIncludedMode(team, body.mode, body.actor, reason)
  // The change log line (Lawrence: log every change); an unchanged request is logged too.
  console.log(JSON.stringify({ msg: r.changed ? "billing.team_mode.set" : "billing.team_mode.unchanged", ...fields, before: r.before, after: body.mode, reason, applies: "next_period_start" }))
  return json({ team, stack_team: stackTeam, before: r.before, mode: body.mode, changed: r.changed, applies: "next_period_start", ...(await meter.includedModes(team)) })
}
