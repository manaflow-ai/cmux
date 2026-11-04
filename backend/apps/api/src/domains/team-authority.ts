import { createHash } from "node:crypto"
import type { ReduceContext, RowReader, RowWrite } from "@cmux/ownership"
import { ROLE_GRANTS, type Role } from "./team-roles.ts"

/** Private per-member incarnation; only changes of membership or role write it. */
export const TABLE_MEMBER_AUTHORITY = "member_authority"
const GENERATION_KEY = "@generation"

const generationOf = (rows?: RowReader): bigint => {
  const stored = rows?.get<{ generation: string }>(TABLE_MEMBER_AUTHORITY, GENERATION_KEY)
  const value = stored === undefined ? "0" : stored.row.generation
  if (typeof value !== "string" || !/^(0|[1-9][0-9]{0,63})$/.test(value)) throw new Error("invalid member authority generation")
  return BigInt(value)
}

/** One persistent clock survives member deletion and ledger pruning; unrelated members keep their own stamps. */
export const memberAuthorityWrites = (user: string, ctx: ReduceContext): ReadonlyArray<RowWrite> => {
  const generation = (generationOf(ctx.rows) + 1n).toString()
  if (generation.length > 64) throw new Error("member authority generation exhausted")
  return [
    { table: TABLE_MEMBER_AUTHORITY, op: "upsert", key: GENERATION_KEY, row: { generation } },
    // The counter prevents reuse; the owner's transaction tag keeps the
    // underlying counter and policy version from being guessable from a hash.
    { table: TABLE_MEMBER_AUTHORITY, op: "upsert", key: user, row: { incarnation: `generation:${generation}:${ctx.tx}` } }
  ]
}

/** A cache fence, never a credential. A role returning to its old value has a new incarnation. */
export const teamAuthorityVersion = (team: string, user: string, role: string, kind: "personal" | "stack", policyVersion: number, rows?: RowReader): string => {
  // Personal ownership is implicit before its first write; creating that team
  // must not invalidate the operation that bootstraps it. Policy still fences it.
  const stored = kind === "stack" ? rows?.get<{ incarnation: string }>(TABLE_MEMBER_AUTHORITY, user) : undefined
  const incarnation = kind === "personal" ? "personal-owner" : stored === undefined ? "legacy" : stored.row.incarnation
  if (kind === "stack") {
    const generation = generationOf(rows)
    if (typeof incarnation !== "string") throw new Error("invalid member authority incarnation")
    if (stored !== undefined) {
      const version = /^generation:([1-9][0-9]{0,63})(?::[A-Za-z0-9_-]{22})?$/.exec(incarnation)
      const valid = incarnation.startsWith("generation:")
        ? version !== null && BigInt(version[1]!) <= generation
        : /^[A-Za-z0-9_-]{22}$/.test(incarnation)
      if (!valid) throw new Error("invalid member authority incarnation")
    }
  }
  const grants = [...(ROLE_GRANTS[role as Role] ?? [])].sort()
  return createHash("sha256").update(JSON.stringify(["cmux-team-authority-v1", team, user, role, grants, incarnation, policyVersion])).digest("hex")
}
