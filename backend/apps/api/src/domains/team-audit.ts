import { createHash } from "node:crypto"
import { canonicalJson, type OutboxItem, type Principal, type ReduceContext } from "@cmux/ownership"
import { pgSafe } from "../text-safe.ts"

/**
 * Tamper-evident audit chain (spec/enterprise.md section 6). TeamDO appends
 * one record per admin action in the same commit as the change; each record
 * hashes the previous one, so a removed or edited projection row breaks the
 * chain. Pure: the hash depends only on state and the op (mirror replay
 * reproduces it). The projection is `audit_events` (0005_audit_events.sql).
 */
export interface AuditState {
  readonly audit_head?: string
  readonly audit_count?: number
}

export interface AuditRecord {
  readonly team: string
  readonly n: number
  readonly op: string
  /** Public ids only: user, install, or `system:...`; never email or Stack ids. */
  readonly actor: string
  readonly on_behalf_of: string | null
  readonly tx: string
  readonly at: number
  readonly summary: string
  readonly detail: unknown
  readonly prev_hash: string
  readonly hash: string
}

export const GENESIS = "0".repeat(43)

export const publicActor = (p: Principal): string => (p.kind === "system" ? p.identity : (p.install ?? (p.user ? p.user : p.identity)))

/** Appends one record: returns the new chain fields and the outbox row. */
export const appendAudit = <S extends AuditState>(
  state: S,
  team: string,
  ctx: ReduceContext,
  op: string,
  summary: string,
  detail: unknown
): { state: S; outbox: OutboxItem } => {
  const prev = state.audit_head ?? GENESIS
  const n = (state.audit_count ?? 0) + 1
  const body = {
    team,
    n,
    op,
    actor: publicActor(ctx.principal),
    on_behalf_of: ctx.principal.agent ? (ctx.principal.user ?? null) : null,
    tx: ctx.tx,
    at: ctx.now,
    // Cleaned before hashing: the projection stores exactly this record (review P3).
    summary: pgSafe(summary) as string,
    detail: pgSafe(detail),
    prev_hash: prev
  }
  const hash = createHash("sha256").update(prev).update(canonicalJson(body)).digest("base64url")
  const record: AuditRecord = { ...body, hash }
  return { state: { ...state, audit_head: hash, audit_count: n }, outbox: { kind: "audit.append", entity: `${team}:${n}`, payload: record } }
}

/** Recomputes a chain (for tests and the audit verifier): true when every link holds. */
export const verifyChain = (records: ReadonlyArray<AuditRecord>): boolean => {
  let prev = GENESIS
  for (const r of records) {
    const { hash, ...body } = r
    if (body.prev_hash !== prev) return false
    if (createHash("sha256").update(prev).update(canonicalJson(body)).digest("base64url") !== hash) return false
    prev = hash
  }
  return true
}
