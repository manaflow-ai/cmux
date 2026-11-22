import type { Env } from "./env.ts"
import { timingSafeEqual } from "./ingress/verify.ts"

/** The reserved TeamVmDO instance that holds the team VM registry (never a team id, which starts with `team_`). */
export const TEAM_VM_REGISTRY = "registry:team-vm"

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } })

interface RegistryStub {
  registryCounts(): Promise<unknown>
  prefixReport(): Promise<unknown>
}

/**
 * Operator routes for the team VM registry, read-only, absent (404) without TEAM_VM_ADMIN_KEY:
 * `GET /v1/admin/team-vm/registry` answers the counts; `POST /v1/admin/team-vm/prefix-report` runs
 * the on-demand prefix report (one provider list pass; it never adopts, deletes or writes).
 */
export const handleTeamVmAdmin = async (request: Request, env: Env): Promise<Response> => {
  const key = env.TEAM_VM_ADMIN_KEY
  if (!key || key.length < 32) return json({ error: "not found" }, 404)
  const presented = (request.headers.get("authorization") ?? "").replace(/^Bearer /, "")
  if (!timingSafeEqual(presented, key)) return json({ error: "unauthorized" }, 401)
  const path = new URL(request.url).pathname
  const stub = env.TEAM_VM_DO.get(env.TEAM_VM_DO.idFromName(TEAM_VM_REGISTRY)) as unknown as RegistryStub
  if (path === "/v1/admin/team-vm/registry" && request.method === "GET") return json({ counts: await stub.registryCounts() })
  if (path === "/v1/admin/team-vm/prefix-report" && request.method === "POST") {
    const report = await stub.prefixReport().catch((e: unknown) => ({ error: String(e instanceof Error ? e.message : e).slice(0, 100) }))
    if ("error" in (report as object)) return json(report, 409)
    console.warn(JSON.stringify({ msg: "team vm prefix report (operator)" }))
    return json({ report })
  }
  return json({ error: "not found" }, 404)
}
