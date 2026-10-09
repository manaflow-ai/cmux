import type { TeamRole } from "@cmux/protocol"

/**
 * Team roles (cx-3bi.4; spec H5, H12; plans/cmux-next/enterprise.md "Backend lead review"): a
 * role is a named bundle of default grants. TeamDO checks grants, never role names, so a later
 * custom role or a per-resource grant changes one table, not every op.
 */
export type Role = typeof TeamRole.Type
export const ROLES: ReadonlyArray<Role> = ["owner", "admin", "member", "billing", "guest"]

export type TeamGrant =
  /** Use the team's resources: the directory, hosts, devices, team VM certificates, Cloud machines. */
  | "team.resources"
  /** Change the team: policy, enrollment, SSO, domains, integration locks, team VM admin actions, the SSH CA. */
  | "team.manage"
  /** Remove a member, guest or billing member. */
  | "members.remove"
  /** Remove an admin (spec H12: owners only). */
  | "members.remove_admin"
  /** Read every audit record. */
  | "audit.read"
  /** Read the billing audit records only. */
  | "audit.read_billing"
  /** Billing and invoices (no billing op exists in TeamDO yet). */
  | "billing.manage"
  /** Owner transfer and team deletion (owners only; the ops come later). */
  | "team.owner"

const ALL: ReadonlyArray<TeamGrant> = ["team.resources", "team.manage", "members.remove", "members.remove_admin", "audit.read", "audit.read_billing", "billing.manage", "team.owner"]

/** The default bundles. An admin has every grant but owner rights and removing admins; a guest has none. */
export const ROLE_GRANTS: Readonly<Record<Role, ReadonlySet<TeamGrant>>> = {
  owner: new Set(ALL),
  admin: new Set(ALL.filter((g) => g !== "team.owner" && g !== "members.remove_admin")),
  member: new Set(["team.resources"]),
  billing: new Set(["audit.read_billing", "billing.manage"]),
  guest: new Set()
}

/** Whether `role` (undefined: not a member) holds `grant`. */
export const roleHas = (role: string | undefined, grant: TeamGrant): boolean => role !== undefined && (ROLE_GRANTS[role as Role]?.has(grant) ?? false)

/** Guests never use a paid seat (spec H12 a). */
export const usesSeat = (role: string | undefined): boolean => role !== undefined && role !== "guest"

/** The grant that removing a member of `target` role needs; null when nobody may (an owner is demoted first). */
export const removeGrantFor = (target: string): TeamGrant | null => (target === "owner" ? null : target === "admin" ? "members.remove_admin" : "members.remove")

/**
 * Stack team permissions to a cmux role (cx-3bi.4), read with `recursive=true` so contained
 * permissions count. Stack's own `$` permissions decide owner and admin, so Stack's defaults work
 * unchanged: its team creator gets `team_admin`, which contains `$delete_team`. The `cmux:`
 * permissions are custom team permissions a project may define to give the other roles.
 * The first match wins: owner, admin, billing, guest, then member.
 */
export const STACK_ROLE_PERMISSIONS: ReadonlyArray<readonly [Role, ReadonlyArray<string>]> = [
  ["owner", ["$delete_team", "cmux:owner"]],
  ["admin", ["$remove_members", "cmux:admin"]],
  ["billing", ["cmux:billing"]],
  ["guest", ["cmux:guest"]]
]

export const stackRole = (permissions: ReadonlyArray<string>): Role => {
  const held = new Set(permissions)
  return STACK_ROLE_PERMISSIONS.find(([, ids]) => ids.some((id) => held.has(id)))?.[0] ?? "member"
}
