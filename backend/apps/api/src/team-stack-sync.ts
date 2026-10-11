import { createHash } from "node:crypto"
import type { OwnerFrame, RowReader } from "@cmux/ownership"
import { listMembers, memberOf, type RowsWithScan } from "./domains/team-members.ts"
import { noOwnerOf } from "./domains/team-stack.ts"
import { stackRole } from "./domains/team-roles.ts"
import type { TeamState } from "./domains/team.ts"
import { userIdFor } from "./domains/user.ts"
import type { StackServer } from "./stack-server.ts"

/**
 * Stack team webhook deliveries in TeamDO (cx-3bi.43). Svix does not keep the order of
 * deliveries and Stack's team events carry no version, so the event only says what to look at:
 * TeamDO asks Stack for the team and the membership as they are now and commits that answer
 * (team.stack_mirror, team.member.provision with the role Stack's team permissions give now,
 * team.member.remove). Deliveries for one team run one
 * at a time, so the last commit always follows the last read, and an add that arrives after its
 * removal finds no membership in Stack and adds nothing.
 *
 * Only a team.deleted delivery that Stack confirms (TEAM_NOT_FOUND) makes the tombstone. Any
 * other delivery that finds no team changes nothing and asks Stack again later (review P2-2), so
 * one wrong 404 never deletes a team. A delivery processed to the end is recorded by its svix-id
 * (stack_webhook_events, 30 days, past Svix's retry schedule): a replay answers `duplicate` and
 * asks Stack nothing. A tombstoned team's members leave through team.member.remove from the
 * alarm, with backoff, and a member whose removal makes no progress is set aside and logged
 * (review P2-3).
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
  readonly state: () => TeamState
  readonly rows: () => (RowReader & RowsWithScan) | undefined
  readonly submitSystem: (op: string, params: unknown, key: string) => { frames: ReadonlyArray<OwnerFrame> }
  /** A deleted team's member whose row removal is stuck: revoke their certificates and close their sockets now (review P3). */
  readonly revokeStuck: (user: string) => void
}

const SEEN_RETENTION_MS = 30 * 24 * 60 * 60_000
/** Svix waits about 15 s for an answer; a delivery queued behind slower ones answers 503 before that (it still runs, so the retry is a duplicate). */
export const DELIVERY_DEADLINE_MS = 10_000
/** When a delivery found no team: ask Stack again after these delays, then stop (a real deletion sends team.deleted). */
const RECHECK_DELAYS_MS = [60_000, 5 * 60_000, 30 * 60_000, 2 * 60 * 60_000, 6 * 60 * 60_000]
/** A member whose removal made no progress this many times is set aside (logged) until the object restarts. */
const DRAIN_MAX_ATTEMPTS = 3

const hash = (v: unknown) => createHash("sha256").update(JSON.stringify(v)).digest("hex").slice(0, 16)

/** Stack's names fit the directory's DisplayName (1 to 80 characters). */
const displayName = (name: string | null | undefined, fallback: string) => ((name ?? "").trim() || fallback).slice(0, 80)

export class StackTeamSync {
  private queue: Promise<unknown> = Promise.resolve()
  private drainRetryAt: number | null = null
  private drainFailures = 0
  private readonly noProgress = new Map<string, number>()
  private readonly setAside = new Set<string>()

  constructor(private readonly deps: () => StackSyncDeps) {}

  /** One delivery, after every earlier one for this team; answers 503 (retry) when it cannot answer within the deadline. */
  deliver(ev: StackEvent, deadlineMs = DELIVERY_DEADLINE_MS): Promise<StackSyncReply> {
    const expires = Date.now() + deadlineMs
    // Past its deadline the caller already answered 503 and Svix retries: drop it, so a Stack outage cannot grow the queue.
    const run = (): Promise<StackSyncReply> => (Date.now() >= expires ? Promise.resolve({ ok: false, reason: "expired" }) : this.process(this.deps(), ev))
    const reply = this.queue.then(run, run)
    this.queue = reply.catch(() => undefined)
    let timer: ReturnType<typeof setTimeout> | undefined
    const late = new Promise<StackSyncReply>((resolve) => (timer = setTimeout(() => resolve({ ok: false, reason: "busy" }), deadlineMs)))
    return Promise.race([reply, late]).finally(() => clearTimeout(timer))
  }

  /** The alarm's work: due re-checks (one at a time with deliveries), then a page of a deleted team's members. */
  async wake(now: number): Promise<void> {
    const deps = this.deps()
    // Personal teams never mirror Stack; a team not mirrored yet may hold a re-check.
    if (deps.state().team?.kind === "personal") return
    ensureTables(deps.sql)
    const due = deps.sql.exec<{ k: string; type: string; stack_team: string; stack_user: string | null; attempts: number }>(`SELECT k, type, stack_team, stack_user, attempts FROM stack_team_recheck WHERE due_at <= ? ORDER BY due_at LIMIT 20`, now).toArray()
    for (const r of due) {
      const ev: StackEvent = { svix_id: `recheck:${r.k}:${r.attempts}`, type: r.type, stack_team: r.stack_team, ...(r.stack_user ? { stack_user: r.stack_user } : {}) }
      const run = async () => {
        deps.sql.exec(`DELETE FROM stack_team_recheck WHERE k = ?`, r.k)
        try {
          await this.reconcile(deps, deps.stack!, ev, r.attempts)
        } catch (e) {
          schedule(deps.sql, ev, r.attempts, now)
          console.error(JSON.stringify({ msg: "stack team recheck failed", team: deps.team, error: String(e).slice(0, 200) }))
        }
      }
      if (deps.stack) await (this.queue = this.queue.then(run, run))
    }
    this.drainDeleted(deps, now)
  }

  /** When the alarm should run next for this work, or null. */
  nextWakeAt(state: TeamState, now: number): number | null {
    if (state.team?.kind === "personal") return null
    const deps = this.deps()
    if (this.pendingRemovals(state, deps.rows(), 1).length > 0) return Math.max(now, this.drainRetryAt ?? now)
    // Without a Stack client a due re-check could not run (no hot alarm loop).
    if (!deps.stack) return null
    ensureTables(deps.sql)
    const next = deps.sql.exec<{ at: number | null }>(`SELECT MIN(due_at) AS at FROM stack_team_recheck`).one().at
    return next === null ? null : Math.max(now, next)
  }

  private pendingRemovals(state: TeamState, rows: RowsWithScan | undefined, limit: number): Array<string> {
    if (state.team?.deleted_at === undefined) return []
    return listMembers(state, rows, undefined, limit + this.setAside.size).items.map((m) => m.user).filter((u) => !this.setAside.has(u)).slice(0, limit)
  }

  private drainDeleted(deps: StackSyncDeps, now: number) {
    if (this.drainRetryAt !== null && now < this.drainRetryAt) return
    const deletedAt = deps.state().team?.deleted_at
    let stalled = false
    for (const user of this.pendingRemovals(deps.state(), deps.rows(), 100)) {
      // A fresh key per attempt: a replayed old result never stands in for this removal.
      deps.submitSystem("team.member.remove", { user, from_stack: true }, `team-deleted:${deletedAt}:${user}:${now}`)
      if (!memberOf(deps.state(), deps.rows(), user)) {
        this.noProgress.delete(user)
        continue
      }
      stalled = true
      const n = (this.noProgress.get(user) ?? 0) + 1
      this.noProgress.set(user, n)
      if (n >= DRAIN_MAX_ATTEMPTS) {
        this.setAside.add(user)
        console.error(JSON.stringify({ msg: "deleted team member removal made no progress; set aside, certificates revoked and sockets closed", team: deps.team, attempts: n }))
        deps.revokeStuck(user)
      }
    }
    this.drainFailures = stalled ? this.drainFailures + 1 : 0
    this.drainRetryAt = stalled ? now + Math.min(5 * 60_000, 1000 * 2 ** this.drainFailures) : null
  }

  private async process(deps: StackSyncDeps, ev: StackEvent): Promise<StackSyncReply> {
    ensureTables(deps.sql)
    if (deps.sql.exec(`SELECT 1 FROM stack_webhook_events WHERE svix_id = ?`, ev.svix_id).toArray().length > 0) return { ok: true, outcome: "duplicate", duplicate: true }
    if (!deps.stack) return { ok: false, reason: "stack_server_not_configured" }
    let outcome: string
    try {
      outcome = await this.reconcile(deps, deps.stack, ev, -1)
    } catch (e) {
      // A Stack failure (never its body): Svix retries the delivery.
      console.error(JSON.stringify({ msg: "stack webhook lookup failed", svix_id: ev.svix_id, error: String(e).slice(0, 200) }))
      return { ok: false, reason: "stack_lookup" }
    }
    if (outcome.startsWith("reject:")) return { ok: false, reason: outcome }
    // A team.deleted that Stack does not confirm yet stays unrecorded; its re-check (type team.deleted) finishes it (review P2).
    if (outcome === "team_delete_pending") return { ok: true, outcome }
    const now = Date.now()
    deps.sql.exec(`INSERT OR REPLACE INTO stack_webhook_events (svix_id, at, outcome) VALUES (?, ?, ?)`, ev.svix_id, now, outcome)
    deps.sql.exec(`DELETE FROM stack_webhook_events WHERE at < ?`, now - SEEN_RETENTION_MS)
    return { ok: true, outcome }
  }

  /** Stack's current answer committed, then the owner count of an older head set once; `attempt` is the re-check number (-1 for a delivery). */
  private async reconcile(deps: StackSyncDeps, stack: StackServer, ev: StackEvent, attempt: number): Promise<string> {
    const out = await this.reconcileOnce(deps, stack, ev, attempt)
    if (!out.startsWith("reject:")) this.ensureOwnerCount(deps, ev.svix_id)
    return out
  }

  private async reconcileOnce(deps: StackSyncDeps, stack: StackServer, ev: StackEvent, attempt: number): Promise<string> {
    const commit = (op: string, params: Record<string, unknown>) => {
      const before = noOwnerOf(deps.state())
      const res = deps.submitSystem(op, params, `stack-webhook:${ev.svix_id}:${op}:${hash(params)}`)
      const rej = res.frames.find((f) => f.t === "reject")
      if (rej && rej.t === "reject") return `reject:${rej.code}`
      if (!before && noOwnerOf(deps.state())) logNoOwner(deps.team)
      return undefined
    }
    const team = await stack.getTeam(ev.stack_team)
    // Stack still lists a team that a team.deleted named: change nothing now and ask again later, keeping the delete.
    if (team !== null && ev.type === "team.deleted") return schedule(deps.sql, ev, attempt, Date.now()) ? "team_delete_pending" : "team_delete_unconfirmed"
    if (team === null) {
      // Only Stack's own team.deleted, confirmed by this read, deletes the team.
      if (ev.type === "team.deleted") return commit("team.stack_mirror", { team: deps.team, stack_team: ev.stack_team, deleted: true }) ?? "team_deleted"
      return schedule(deps.sql, ev, attempt, Date.now()) ? "team_missing_recheck" : "team_missing_dropped"
    }
    const mirrored = commit("team.stack_mirror", { team: deps.team, stack_team: ev.stack_team, display_name: displayName(team.display_name, "Team") })
    if (mirrored) return mirrored
    // Stack sends no membership event for a team's creator or a sign-up personal team: a team event mirrors Stack's member list.
    if (ev.stack_user === undefined) return (await this.syncMembers(deps, stack, ev, attempt, commit)) ?? "team_mirrored"
    const member = await stack.getTeamMember(ev.stack_team, ev.stack_user)
    // The team was there a moment ago: never a tombstone from this read, only a later re-check.
    if (member === "team_gone") return schedule(deps.sql, ev, attempt, Date.now()) ? "team_missing_recheck" : "team_missing_dropped"
    const user = userIdFor(deps.stackProjectId, ev.stack_user)
    // Stack removed them: an owner of this Stack team is demoted and removed in one commit (review P2-1).
    if (member === null) return commit("team.member.remove", { user, from_stack: true }) ?? "member_absent"
    // The role is read from Stack's permissions on every delivery: a change in Stack changes it here (cx-3bi.4).
    return commit("team.member.provision", { user, role: stackRole(member.permissions), source: "stack", display_name: displayName(member.display_name, "Member") }) ?? "member_present"
  }

  /**
   * The reducers keep owner_count from here on (re-review P3); a head from before it is counted once, in
   * full (no page cap), after this delivery's commits. A count of 0 shows no_owner (review P2-3).
   */
  private ensureOwnerCount(deps: StackSyncDeps, key: string) {
    const state = deps.state()
    if (state.team?.kind !== "stack" || state.team.deleted_at !== undefined || state.owner_count !== undefined) return
    let count = 0
    let after: string | undefined
    for (;;) {
      const page = listMembers(deps.state(), deps.rows(), after, 200)
      count += page.items.filter((m) => m.role === "owner").length
      if (!page.next) break
      after = page.next
    }
    deps.submitSystem("team.owner_count.init", { count }, `owner-count-init:${key}`)
    if (noOwnerOf(deps.state())) logNoOwner(deps.team)
  }

  /** Adds every member Stack lists and removes every member it no longer lists; a reject or a missing team is the outcome, else undefined. */
  private async syncMembers(deps: StackSyncDeps, stack: StackServer, ev: StackEvent, attempt: number, commit: (op: string, params: Record<string, unknown>) => string | undefined): Promise<string | undefined> {
    const listed = await stack.listTeamMembers(ev.stack_team)
    if (listed === "team_gone") return schedule(deps.sql, ev, attempt, Date.now()) ? "team_missing_recheck" : "team_missing_dropped"
    const want = new Map(listed.map((m) => [userIdFor(deps.stackProjectId, UUIDISH.test(m.user_id) ? m.user_id.toLowerCase() : m.user_id), m] as const))
    // Owners first: a handover in one sync (A demoted, B promoted) never passes through "no owner" (re-review P3).
    for (const [user, m] of [...want].sort(([, a], [, b]) => Number(stackRole(b.permissions) === "owner") - Number(stackRole(a.permissions) === "owner"))) {
      const r = commit("team.member.provision", { user, role: stackRole(m.permissions), source: "stack", display_name: displayName(m.display_name, "Member") })
      if (r) return r
    }
    const gone: Array<string> = []
    let after: string | undefined
    for (;;) {
      const page = listMembers(deps.state(), deps.rows(), after, 200)
      for (const m of page.items) if (!want.has(m.user)) gone.push(m.user)
      if (!page.next) break
      after = page.next
    }
    for (const user of gone) {
      const r = commit("team.member.remove", { user, from_stack: true })
      if (r) return r
    }
    return undefined
  }
}

const logNoOwner = (team: string) => console.error(JSON.stringify({ msg: "stack team has no owner; a Stack team admin must promote one", team }))

const UUIDISH = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

const ensureTables = (sql: SqlStorage) => {
  sql.exec(`CREATE TABLE IF NOT EXISTS stack_webhook_events (svix_id TEXT PRIMARY KEY, at INTEGER NOT NULL, outcome TEXT NOT NULL)`)
  sql.exec(`CREATE INDEX IF NOT EXISTS stack_webhook_events_at ON stack_webhook_events (at)`)
  sql.exec(`CREATE TABLE IF NOT EXISTS stack_team_recheck (k TEXT PRIMARY KEY, type TEXT NOT NULL, stack_team TEXT NOT NULL, stack_user TEXT, due_at INTEGER NOT NULL, attempts INTEGER NOT NULL)`)
}

/** Asks Stack again later (attempt+1); false once the schedule is spent (logged). */
const schedule = (sql: SqlStorage, ev: StackEvent, attempt: number, now: number): boolean => {
  ensureTables(sql)
  const next = attempt + 1
  if (next >= RECHECK_DELAYS_MS.length) {
    console.error(JSON.stringify({ msg: "stack team still missing after re-checks; dropped", svix_id: ev.svix_id }))
    return false
  }
  // A pending delete and a membership re-check of the same team are separate rows.
  const type = ev.type === "team.deleted" ? "team.deleted" : "recheck"
  const k = `${type}|${ev.stack_team}|${ev.stack_user ?? ""}`
  sql.exec(`INSERT OR REPLACE INTO stack_team_recheck (k, type, stack_team, stack_user, due_at, attempts) VALUES (?, ?, ?, ?, ?, ?)`, k, type, ev.stack_team, ev.stack_user ?? null, now + RECHECK_DELAYS_MS[next]!, next)
  return true
}

export { noOwnerOf }
