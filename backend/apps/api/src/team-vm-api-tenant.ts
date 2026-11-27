import type { TeamState } from "./domains/team.ts"
import { stackTeamIdFor } from "./domains/user.ts"

/** Private owner-to-service routing metadata; never an authorization grant. */
export interface VmApiTenant {
  readonly team: string
  readonly tenant: string
  readonly project: string
}
export type VmApiTenantPurpose = "operate" | "cleanup"

/**
 * Reads only a canonical Stack mirror. Personal teams currently have no Stack tenant.
 * Deletion keeps the immutable routing identity for cleanup of existing resources,
 * while new spend and execution must ask with operate and are refused.
 */
export const vmApiTenantOf = (state: TeamState | undefined, entity: string, project: string, purpose: VmApiTenantPurpose): VmApiTenant | null => {
  if (purpose !== "operate" && purpose !== "cleanup") return null
  const team = state?.team
  if (!team || team.id !== entity || team.kind !== "stack" || !team.stack_team) return null
  if (team.deleted_at !== undefined && purpose !== "cleanup") return null
  if (!project || project.length > 128 || project.trim() !== project || /[\r\n]/.test(project)) return null
  if (!/^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/.test(team.stack_team) || team.stack_team.trim() !== team.stack_team) return null
  if (stackTeamIdFor(project, team.stack_team) !== entity) return null
  return Object.freeze({ team: entity, tenant: team.stack_team, project })
}
