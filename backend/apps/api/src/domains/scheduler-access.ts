import type { Principal, Reject } from "@cmux/ownership"
import type { Automation } from "@cmux/protocol"
import { personalTeamIdFor } from "./user.ts"

/**
 * Who may do what with one automation inside its team (docs/automations-teleport-teams.md
 * section 4). The team boundary itself is the SchedulerDO (one per team) and its authorize
 * check; this module is the boundary inside the team. Pure.
 *
 * - view (list, get, runs, run now): a `team` automation, every member; a `private` one, its
 *   creator, its editors, and the team's admins and owners.
 * - edit (update, pause, delete, deploy, teleport, webhook secret): creator, editors, admins, owners.
 * - share (change `sharing` or `editors`): creator, admins, owners.
 *
 * The role comes from `principal.team_role`, which only the Worker sets (TeamDO's answer); a
 * principal without one is a member. In a personal team the user is its owner.
 */
type Scoped = Pick<Automation, "created_by"> & { readonly sharing?: "team" | "private"; readonly editors?: ReadonlyArray<string> }

const ADMIN_ROLES: ReadonlySet<string> = new Set(["owner", "admin"])

/** Owner or admin of the team, or the user of a personal team; the SchedulerDO's own system ops pass. */
export const isTeamAdmin = (p: Principal, owner: string | null): boolean =>
  p.kind === "system" || ADMIN_ROLES.has(p.team_role ?? "") || (p.user !== undefined && personalTeamIdFor(p.user) === (owner ?? p.team))

const isEditor = (p: Principal, a: Scoped) => p.user !== undefined && (a.created_by === p.user || (a.editors ?? []).includes(p.user))

export const mayView = (p: Principal, owner: string | null, a: Scoped): boolean => (a.sharing ?? "team") === "team" || isEditor(p, a) || isTeamAdmin(p, owner)
export const mayEdit = (p: Principal, owner: string | null, a: Scoped): boolean => isEditor(p, a) || isTeamAdmin(p, owner)
export const mayShare = (p: Principal, owner: string | null, a: Scoped): boolean => (p.user !== undefined && a.created_by === p.user) || isTeamAdmin(p, owner)

export type Need = "view" | "edit" | "share"

/**
 * The refusal for `need` on `a`, or undefined. An automation the caller may not view answers
 * `selector.not_found`, exactly like one that does not exist, so its existence does not leak.
 */
export const refusal = (p: Principal, owner: string | null, a: Scoped | undefined, need: Need): Reject | undefined => {
  if (!a || !mayView(p, owner, a)) return { code: "selector.not_found", message: "automation not found" }
  if (need === "edit" && !mayEdit(p, owner, a)) return { code: "auth.forbidden", message: "only its creator, its editors and team admins change this automation" }
  if (need === "share" && !mayShare(p, owner, a)) return { code: "auth.forbidden", message: "only its creator and team admins change who sees or edits this automation" }
  return undefined
}
