import { createHash } from "node:crypto"
import type { OwnerFrame } from "@cmux/ownership"
import { listMembers, type RowsWithScan } from "./domains/team-members.ts"
import type { TeamState } from "./domains/team.ts"
import { userIdFor } from "./domains/user.ts"
import type { StackServer } from "./stack-server.ts"

/**
 * One Stack team webhook delivery in TeamDO (cx-3bi.43). Svix does not keep the order of
 * deliveries and Stack's team events carry no version, so the event only says what to look at:
 * TeamDO asks Stack for the team and the membership as they are now and commits that answer
 * (team.stack_mirror, team.member.provision, team.member.remove). Deliveries for one team run one
 * at a time (the caller serializes them), so the last commit always follows the last read, and an
 * add that arrives after its removal finds no membership in Stack and adds nothing.
 *
 * A delivery processed to the end is recorded by its svix-id (stack_webhook_events, 30 days, past
 * Svix's retry schedule): a replay answers `duplicate` and asks Stack nothing.
 */
export interface StackEvent {
  readonly svix_id: string
  readonly type: string
  readonly stack_team: string
  readonly stack_user?: string
}

export type StackSyncReply = { readonly ok: true; readonly outcome: string; readonly duplicate?: true } | { readonly ok: false; readonly reason: string }

export interface StackSyncDeps {
  readonly team: string
  readonly stackProjectId: string
  readonly stack: StackServer | undefined
  readonly sql: SqlStorage
  readonly now: () => number
  readonly submitSystem: (op: string, params: unknown, key: string) => { frames: ReadonlyArray<OwnerFrame> }
}

const SEEN_RETENTION_MS = 30 * 24 * 60 * 60_000

const ensureTable = (sql: SqlStorage) => {
  sql.exec(`CREATE TABLE IF NOT EXISTS stack_webhook_events (svix_id TEXT PRIMARY KEY, at INTEGER NOT NULL, outcome TEXT NOT NULL)`)
  sql.exec(`CREATE INDEX IF NOT EXISTS stack_webhook_events_at ON stack_webhook_events (at)`)
}

/** Stack's names fit the directory's DisplayName (1 to 80 characters). */
const displayName = (name: string | null | undefined, fallback: string) => {
  const n = (name ?? "").trim()
  return (n || fallback).slice(0, 80)
}

const hash = (v: unknown) => createHash("sha256").update(JSON.stringify(v)).digest("hex").slice(0, 16)

/** Commits one system op; the key names the delivery and the exact params, so a retry with Stack's same answer replays. */
const commit = (deps: StackSyncDeps, svixId: string, op: string, params: Record<string, unknown>) => {
  const res = deps.submitSystem(op, params, `stack-webhook:${svixId}:${op}:${hash(params)}`)
  const rej = res.frames.find((f) => f.t === "reject")
  return rej && rej.t === "reject" ? { code: rej.code, message: rej.message } : undefined
}

export const stackSync = async (deps: StackSyncDeps, ev: StackEvent): Promise<StackSyncReply> => {
  ensureTable(deps.sql)
  if (deps.sql.exec(`SELECT 1 FROM stack_webhook_events WHERE svix_id = ?`, ev.svix_id).toArray().length > 0) return { ok: true, outcome: "duplicate", duplicate: true }
  if (!deps.stack) return { ok: false, reason: "stack_server_not_configured" }
  let outcome: string
  try {
    outcome = await reconcile(deps, deps.stack, ev)
  } catch (e) {
    // A Stack failure (never its body): Svix retries the delivery.
    console.error(JSON.stringify({ msg: "stack webhook lookup failed", svix_id: ev.svix_id, error: String(e).slice(0, 200) }))
    return { ok: false, reason: "stack_lookup" }
  }
  if (outcome.startsWith("reject:")) return { ok: false, reason: outcome }
  const now = deps.now()
  deps.sql.exec(`INSERT OR REPLACE INTO stack_webhook_events (svix_id, at, outcome) VALUES (?, ?, ?)`, ev.svix_id, now, outcome)
  deps.sql.exec(`DELETE FROM stack_webhook_events WHERE at < ?`, now - SEEN_RETENTION_MS)
  return { ok: true, outcome }
}

const reconcile = async (deps: StackSyncDeps, stack: StackServer, ev: StackEvent): Promise<string> => {
  const team = await stack.getTeam(ev.stack_team)
  const mirror = (deleted: boolean, name?: string) =>
    commit(deps, ev.svix_id, "team.stack_mirror", { team: deps.team, stack_team: ev.stack_team, ...(deleted ? { deleted: true } : { display_name: displayName(name, "Team") }) })
  if (team === null) {
    const r = mirror(true)
    return r ? `reject:${r.code}` : "team_deleted"
  }
  const mirrored = mirror(false, team.display_name)
  if (mirrored) return `reject:${mirrored.code}`
  if (ev.stack_user === undefined) return "team_mirrored"
  const member = await stack.getTeamMember(ev.stack_team, ev.stack_user)
  if (member === "team_gone") {
    const r = mirror(true)
    return r ? `reject:${r.code}` : "team_deleted"
  }
  const user = userIdFor(deps.stackProjectId, ev.stack_user)
  if (member === null) {
    const r = commit(deps, ev.svix_id, "team.member.remove", { user })
    // An owner stays until team roles demote them (cx-3bi.4); recorded, so Stack does not retry forever.
    if (r?.code === "auth.forbidden" && /owner/.test(r.message)) return "owner_kept"
    return r ? `reject:${r.code}` : "member_absent"
  }
  const r = commit(deps, ev.svix_id, "team.member.provision", { user, role: "member", source: "stack", display_name: displayName(member.display_name, "Member") })
  return r ? `reject:${r.code}` : "member_present"
}

/** Members a deleted Stack team still has; TeamDO's alarm removes them a page at a time. */
export const deletedTeamMembers = (state: TeamState, rows: RowsWithScan | undefined, limit = 100): Array<string> =>
  state.team?.deleted_at === undefined ? [] : listMembers(state, rows, undefined, limit).items.map((m) => m.user)
