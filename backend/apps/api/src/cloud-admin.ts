import { authenticate } from "./auth.ts"
import type { Env } from "./env.ts"
import { timingSafeEqual } from "./ingress/verify.ts"

/**
 * Operator route: POST /v1/admin/cloud/abandoned/clear {team, machine, reason}.
 * Two credentials: `authorization: Bearer <CLOUD_ADMIN_KEY>` (the operator tool) AND
 * `x-cmux-person-token: <the person's own session token>`. The token must authenticate as a
 * session, never an install or an agent, so every clear names a person. CloudDO refuses unless a
 * provider lookup of the recorded name finds no VM, and audits who, when and why. Absent (404)
 * without CLOUD_ADMIN_KEY.
 */
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } })
const TEAM = /^team_[a-z0-9]{20}$/
const MACHINE = /^vm_[a-z0-9]{20}$/

export const handleCloudAbandonedClear = async (request: Request, env: Env): Promise<Response> => {
  const key = env.CLOUD_ADMIN_KEY
  if (!key || key.length < 32) return json({ error: "not found" }, 404)
  if (request.method !== "POST") return json({ error: "method not allowed" }, 405)
  const presented = (request.headers.get("authorization") ?? "").replace(/^Bearer /, "")
  if (!timingSafeEqual(presented, key)) return json({ error: "unauthorized" }, 401)
  const person = await authenticate(env, request.headers.get("x-cmux-person-token") ?? undefined).catch(() => undefined)
  if (!person || person.kind !== "session" || person.agent !== undefined || !person.user) return json({ error: "a person's session token is required (never an install or an agent)" }, 403)
  const raw = await request.text()
  if (raw.length > 8 * 1024) return json({ error: "body too large" }, 413)
  const body = (() => {
    try {
      return JSON.parse(raw) as { team?: unknown; machine?: unknown; reason?: unknown } | null
    } catch {
      return null
    }
  })()
  const team = typeof body?.team === "string" && TEAM.test(body.team) ? body.team : null
  const machine = typeof body?.machine === "string" && MACHINE.test(body.machine) ? body.machine : null
  const reason = typeof body?.reason === "string" && body.reason.trim().length >= 8 && body.reason.length <= 500 ? body.reason.trim() : null
  if (!team || !machine || !reason) return json({ error: "team, machine and reason (8 to 500 characters) are required" }, 400)
  const ns = env.CLOUD_DO
  if (!ns) return json({ error: "no CloudDO binding" }, 503)
  const stub = ns.get(ns.idFromName(team)) as unknown as { clearAbandoned(entity: string, machine: string, who: { user: string; email: string | null }, reason: string): Promise<{ ok: boolean; code?: string; message?: string; audit?: unknown }> }
  const r = await stub.clearAbandoned(team, machine, { user: person.user, email: person.email ?? null }, reason)
  if (r.ok) return json({ cleared: true, audit: r.audit })
  const status = r.code === "vm_present" ? 409 : r.code === "provider_unavailable" ? 503 : 404
  return json({ error: r.code, message: r.message }, status)
}
