import { createHash } from "node:crypto"
import type { ReduceContext, RowReader, RowWrite } from "@cmux/ownership"
import { ROLE_GRANTS, type Role } from "./team-roles.ts"

/** Private per-member incarnation; only changes of membership or role write it. */
export const TABLE_MEMBER_AUTHORITY = "member_authority"

export const memberAuthorityWrite = (user: string, ctx: ReduceContext): RowWrite => ({
  table: TABLE_MEMBER_AUTHORITY, op: "upsert", key: user, row: { incarnation: ctx.tx }
})

/** A cache fence, never a credential. A role returning to its old value has a new incarnation. */
export const teamAuthorityVersion = (team: string, user: string, role: string, kind: "personal" | "stack", policyVersion: number, rows?: RowReader): string => {
  // Personal ownership is implicit before its first write; creating that team
  // must not invalidate the operation that bootstraps it. Policy still fences it.
  const incarnation = kind === "personal" ? "personal-owner" : rows?.get<{ incarnation: string }>(TABLE_MEMBER_AUTHORITY, user)?.row.incarnation ?? "legacy"
  const grants = [...(ROLE_GRANTS[role as Role] ?? [])].sort()
  return createHash("sha256").update(JSON.stringify(["cmux-team-authority-v1", team, user, role, grants, incarnation, policyVersion])).digest("hex")
}
