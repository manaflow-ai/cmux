import type { Env } from "./env.ts"

interface ExportStub {
  exportDownload(entity: string, ticket: string): Promise<Response>
}

/**
 * `GET /v1/team-vm/export/<team>/<ticket>` (cx-lyvg): the team files of a retired team VM as a tar.
 * No bearer: a browser download cannot send one. The ticket (256 random bits, single use, 5
 * minutes) comes from the audited owner/admin op team_vm.retired.export; only that team's
 * TeamVmDO knows it (it stores the SHA-256), so a ticket never opens another team's files.
 */
export const handleTeamVmExport = async (request: Request, env: Env, team: string, ticket: string): Promise<Response> => {
  if (request.method !== "GET") return Response.json({ ok: false, error: { code: "validation.invalid", message: "GET only" } }, { status: 405, headers: { allow: "GET" } })
  const stub = env.TEAM_VM_DO.get(env.TEAM_VM_DO.idFromName(team)) as unknown as ExportStub
  return stub.exportDownload(team, ticket)
}
