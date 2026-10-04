import type { Env } from "./env.ts"

/** The reserved TeamVmDO instance that holds the team VM registry (never a team id). */
export const TEAM_VM_REGISTRY = "registry:team-vm"

/** Operator routes for the team VM registry (not built yet). */
export const handleTeamVmAdmin = async (_request: Request, _env: Env): Promise<Response> => new Response(JSON.stringify({ error: "not found" }), { status: 404 })
