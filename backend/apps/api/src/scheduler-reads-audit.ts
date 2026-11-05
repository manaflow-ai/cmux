import type { Principal } from "@cmux/ownership"
import { isTeamAdmin } from "./domains/scheduler-access.ts"

/** Read-side helpers of the automation audit log (domains/scheduler-audit.ts). */
export { allAudit } from "./domains/scheduler-audit.ts"

/** Whether `p` administers the team that owns this scheduler. */
export const isTeamAdminOf = (p: Principal, owner: string | null | undefined): boolean => isTeamAdmin(p, owner ?? null)
