import { verifySvixSignature } from "../../../../libs/svix-webhook/src/svix.ts"
import { stackTeamIdFor } from "./domains/user.ts"
import type { Env } from "./env.ts"
import type { StackSyncReply } from "./team-stack-sync.ts"

/**
 * The Stack team webhook (cx-3bi.43): `POST /v1/hooks/stack`. No bearer credential; the Svix
 * signature with the Worker secret STACK_WEBHOOK_SECRET is the credential (libs/svix-webhook, the
 * same check as the cmux VM Worker's). Stack's team.created, team.updated, team.deleted,
 * team_membership.created and team_membership.deleted go to the team's TeamDO, which reads the
 * team and membership from Stack as they are now and commits that (team-stack-sync.ts); every
 * other event is a 200 no-op.
 *
 * Answers: 503 while the secret is not configured, TeamDO or Stack fails (Svix retries), 401 for a
 * bad, stale or missing signature, 400 for a signed body of the wrong shape, 200 otherwise (a
 * replayed svix-id answers `duplicate`). Every answer logs its reason and the svix-id, never the
 * secret, a signature, a user id or the body.
 */
export const STACK_WEBHOOK_PATH = "/v1/hooks/stack"
const MAX_BODY_BYTES = 64 * 1024
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const TEAM_EVENTS = new Set(["team.created", "team.updated", "team.deleted"])
const MEMBERSHIP_EVENTS = new Set(["team_membership.created", "team_membership.deleted"])

type Fields = Readonly<Record<string, string | number | boolean>>

const finish = (status: number, reason: string, body: Record<string, unknown>, fields: Fields) => {
  const line = JSON.stringify({ msg: "stack webhook", status, reason, ...fields })
  if (status === 200) console.log(line)
  else console.warn(line)
  return Response.json(body, { status })
}

const failure = (code: string, message: string, retryable: boolean) => ({ error: { code, message, retryable } })

interface TeamWebhookStub {
  stackWebhook(entity: string, event: { svix_id: string; type: string; stack_team: string; stack_user?: string }): Promise<StackSyncReply>
}

export const handleStackWebhook = async (request: Request, env: Env, nowMs: number = Date.now()): Promise<Response> => {
  // The svix-id as logged (the delivery's id in the Svix dashboard, not a secret), cut to 64 characters.
  const svix_id = (request.headers.get("svix-id") ?? "").slice(0, 64)
  const notConfigured = failure("webhook.not_configured", "Stack webhooks are not configured", true)
  const secret = env.STACK_WEBHOOK_SECRET
  if (!secret) return finish(503, "not_configured", notConfigured, { svix_id })
  if (request.method !== "POST") return finish(405, "method", failure("validation.invalid", "use POST", false), { svix_id })
  const declared = Number(request.headers.get("content-length") ?? "0")
  const tooLarge = failure("validation.invalid", "webhook body too large", false)
  if (declared > MAX_BODY_BYTES) return finish(413, "too_large", tooLarge, { svix_id, bytes: declared })
  const body = await request.text()
  if (body.length > MAX_BODY_BYTES) return finish(413, "too_large", tooLarge, { svix_id, bytes: body.length })
  const check = await verifySvixSignature(secret, request.headers, body, nowMs)
  if (!check.ok) {
    // "secret": STACK_WEBHOOK_SECRET is not a valid whsec_ key; the rest are the sender's fault.
    if (check.reason === "secret") return finish(503, "secret_invalid", notConfigured, { svix_id })
    const signatures = (request.headers.get("svix-signature") ?? "").split(" ").filter((s) => s.length > 0).length
    const ts = Number(request.headers.get("svix-timestamp") ?? "")
    const skewSeconds = Number.isFinite(ts) && ts > 0 ? Math.round(nowMs / 1000 - ts) : -1
    return finish(401, check.reason, failure("auth.unauthenticated", "invalid webhook signature", false), { svix_id, signatures, skewSeconds })
  }
  let envelope: { type?: unknown; data?: unknown }
  try {
    envelope = JSON.parse(body) as typeof envelope
  } catch {
    return finish(400, "body_shape", failure("validation.invalid", "malformed webhook body", false), { svix_id })
  }
  if (typeof envelope?.type !== "string" || typeof envelope.data !== "object" || envelope.data === null) return finish(400, "body_shape", failure("validation.invalid", "malformed webhook body", false), { svix_id })
  const type = envelope.type
  const event_type = type.slice(0, 64)
  if (!TEAM_EVENTS.has(type) && !MEMBERSHIP_EVENTS.has(type)) return finish(200, "ignored", { ok: true, ignored: type }, { svix_id, event_type })
  const data = envelope.data as { id?: unknown; team_id?: unknown; user_id?: unknown }
  const stackTeam = TEAM_EVENTS.has(type) ? data.id : data.team_id
  const stackUser = MEMBERSHIP_EVENTS.has(type) ? data.user_id : undefined
  if (typeof stackTeam !== "string" || !UUID.test(stackTeam) || (MEMBERSHIP_EVENTS.has(type) && (typeof stackUser !== "string" || !UUID.test(stackUser)))) {
    return finish(400, "data_shape", failure("validation.invalid", `malformed ${type} data`, false), { svix_id, event_type })
  }
  const team = stackTeamIdFor(env.STACK_PROJECT_ID, stackTeam.toLowerCase())
  const stub = env.TEAM_DO.get(env.TEAM_DO.idFromName(team)) as unknown as TeamWebhookStub
  let reply: StackSyncReply
  try {
    reply = await stub.stackWebhook(team, { svix_id: check.messageId, type, stack_team: stackTeam.toLowerCase(), ...(typeof stackUser === "string" ? { stack_user: stackUser.toLowerCase() } : {}) })
  } catch (e) {
    return finish(503, "owner_unreachable", failure("owner.unreachable", "TeamDO did not answer; retry", true), { svix_id, event_type, team, error: String(e).slice(0, 120) })
  }
  if (!reply.ok) return finish(503, reply.reason, failure(reply.reason === "stack_server_not_configured" ? "webhook.not_configured" : "owner.unreachable", "the delivery did not finish; retry", true), { svix_id, event_type, team })
  if (reply.duplicate) return finish(200, "duplicate", { ok: true, duplicate: true }, { svix_id, event_type, team })
  return finish(200, "processed", { ok: true, outcome: reply.outcome }, { svix_id, event_type, team, outcome: reply.outcome })
}
