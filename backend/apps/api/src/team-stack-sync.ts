import { createHash } from "node:crypto"
import type { OwnerFrame, RowReader } from "@cmux/ownership"
import { listMembers, memberOf, type RowsWithScan } from "./domains/team-members.ts"
import { noOwnerOf } from "./domains/team-stack.ts"
import { stackRole } from "./domains/team-roles.ts"
import type { TeamState } from "./domains/team.ts"
import { userIdFor } from "./domains/user.ts"
import { storePlan } from "./inference/plan.ts"
import type { StackMember, StackServer } from "./stack-server.ts"

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
 * (stack_webhook_events, 30 days, past Svix's retry schedule) when it arrives: a replay answers
 * `duplicate` and asks Stack nothing. Since cx-f5tk4 every delivery is kept as a pending row and read
 * from Stack only with a token of the shared pace; see deliver(). A tombstoned team's members leave through team.member.remove from the
 * alarm, with backoff, and a member whose removal makes no progress is set aside and logged
 * (review P2-3).
 */
export interface StackEvent {
  readonly svix_id: string
  readonly type: string
  readonly stack_team: string
  readonly stack_user?: string
  /** A person waits on this sync (user.teams.list found the team in Stack): it never takes the low lane. */
  readonly urgent?: true
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
  /** The shared pace of sign-in reads (STACK_READ_LIMIT): one token before each sync's reads; false = not now (cx-f5tk4). */
  readonly pace?: () => Promise<boolean>
  /**
   * The low lane (stackLowReadPace): a sync of a team not mirrored here whose deliveries carry no membership and
   * no urgent flag takes a token here first, then one of `pace`. Absent: no low cap.
   */
  readonly lowPace?: () => Promise<boolean>
}

const SEEN_RETENTION_MS = 30 * 24 * 60 * 60_000
/** Svix waits about 15 s for an answer; a delivery still waiting behind slower ones answers 200 `queued` before that (its row stays). */
export const DELIVERY_DEADLINE_MS = 10_000
/** When a delivery found no team: ask Stack again after these delays, then stop (a real deletion sends team.deleted). */
const RECHECK_DELAYS_MS = [60_000, 5 * 60_000, 30 * 60_000, 2 * 60 * 60_000, 6 * 60 * 60_000]
/** A member whose removal made no progress this many times is set aside (logged) until the object restarts. */
const DRAIN_MAX_ATTEMPTS = 3
/**
 * A sync that could not read Stack (a 429 or another read failure) waits 1 min doubling to 1 h with ±20 %
 * jitter (cx-f5tk4; one without a pace token waits less first, pacedBackoffMs), then tries again from the alarm; after SYNC_MAX_FAILS (about two
 * days) it ends, logged. The delivery itself was already answered 200 `queued`.
 */
export const SYNC_BACKOFF_MS = { first: 60_000, max: 60 * 60_000 } as const
export const SYNC_MAX_FAILS = 50
export const syncBackoffMs = (fails: number, random: () => number = Math.random) =>
  Math.round(Math.min(SYNC_BACKOFF_MS.max, SYNC_BACKOFF_MS.first * 2 ** Math.max(0, fails - 1)) * (0.8 + 0.4 * random()))
/**
 * A sync that found the shared pace full (no token; Stack was not asked) waits 5, 10, 20 and 40 s first, ±20 %:
 * the pace frees a token within its 60 s window and a person waits on a join (prod 2026-10-29: a new team listed
 * after 67 s). After PACED_QUICK_TRIES it follows syncBackoffMs, so a pace that stays full still ends in about two days.
 */
export const PACED_QUICK_TRIES = 4
const PACED_FIRST_MS = 5_000
export const pacedBackoffMs = (fails: number, random: () => number = Math.random) =>
  fails <= PACED_QUICK_TRIES ? Math.round(PACED_FIRST_MS * 2 ** Math.max(0, fails - 1) * (0.8 + 0.4 * random())) : syncBackoffMs(fails - PACED_QUICK_TRIES, random)

type QueueRow = { k: string; type: string; stack_team: string; stack_user: string | null; due_at: number; attempts: number; fails: number; gen: number; merged: number; urgent: number }
/** While a row's Stack read runs, the row waits this long (a lease): a restart mid-read leaves it for the alarm. */
export const SYNC_LEASE_MS = 5 * 60_000

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

  /**
   * One delivery (cx-f5tk4). It is first recorded durably: its svix-id (dedupe) and a pending row of its team
   * in stack_team_recheck, so the 200 that follows never loses it. Then, one at a time per team and only with
   * a pace token, it is reconciled at once and answers its outcome. Without a token, on a Stack failure (429
   * included), past the deadline, or while the row waits (backoff or a re-check), it answers 200 `queued` and
   * the alarm syncs the team later. Deliveries of one team share the row: once a second one merged in, the
   * row runs as one full team sync (the team and its whole member list as Stack has them now).
   */
  deliver(ev: StackEvent, deadlineMs = DELIVERY_DEADLINE_MS): Promise<StackSyncReply> {
    const deps = this.deps()
    ensureTables(deps.sql)
    if (deps.sql.exec(`SELECT 1 FROM stack_webhook_events WHERE svix_id = ?`, ev.svix_id).toArray().length > 0) return Promise.resolve({ ok: true, outcome: "duplicate", duplicate: true })
    if (!deps.stack) return Promise.resolve({ ok: false, reason: "stack_server_not_configured" })
    const now = Date.now()
    const k = enqueue(deps.sql, ev, now)
    deps.sql.exec(`INSERT OR REPLACE INTO stack_webhook_events (svix_id, at, outcome) VALUES (?, ?, ?)`, ev.svix_id, now, "queued")
    deps.sql.exec(`DELETE FROM stack_webhook_events WHERE at < ?`, now - SEEN_RETENTION_MS)
    const expires = now + deadlineMs
    const queued: StackSyncReply = { ok: true, outcome: "queued" }
    const run = async (): Promise<StackSyncReply> => {
      // Past its deadline the caller already answered: the row stays for the alarm.
      if (Date.now() >= expires) return queued
      const row = readRow(deps.sql, k)
      // A row that waits (backoff, a re-check, a lease) keeps its time; another run may have synced the team.
      if (!row || row.due_at > Date.now()) return queued
      const out = await this.runRow(deps, row.k, ev)
      if (out === undefined) return queued
      deps.sql.exec(`INSERT OR REPLACE INTO stack_webhook_events (svix_id, at, outcome) VALUES (?, ?, ?)`, ev.svix_id, Date.now(), out)
      return { ok: true, outcome: out }
    }
    const reply = this.queue.then(run, run)
    this.queue = reply.catch(() => undefined)
    let timer: ReturnType<typeof setTimeout> | undefined
    const late = new Promise<StackSyncReply>((resolve) => (timer = setTimeout(() => resolve(queued), deadlineMs)))
    return Promise.race([reply, late]).finally(() => clearTimeout(timer))
  }

  /**
   * One pending row: a pace token, then Stack read as it is now and committed. Returns the outcome, or
   * undefined when it could not read now (back with backoff, or abandoned after SYNC_MAX_FAILS). The row is
   * leased, never deleted, while Stack is read: a restart mid-read leaves it for the alarm after the lease.
   * `ev` is the delivery that runs it at once; it runs as itself only while no other delivery merged in.
   */
  private async runRow(deps: StackSyncDeps, k: string, ev: StackEvent | undefined, clock?: number): Promise<string | undefined> {
    // The alarm's time (tests inject it) or now, whichever is later: a long alarm batch never backs off into the past.
    const at = () => Math.max(clock ?? 0, Date.now())
    const before = readRow(deps.sql, k)
    if (!before) return undefined
    // A team never mirrored here whose deliveries name no member and no waiting person (cmux.com visitors'
    // sign-up teams, in production) takes the low lane first, so it never uses the whole pace.
    const low = deps.state().team == null && before.urgent === 0 && deps.lowPace !== undefined
    const take = () => (deps.pace ? deps.pace().catch(() => false) : Promise.resolve(true))
    const paced = low ? (await deps.lowPace!().catch(() => false)) && (await take()) : await take()
    // Read again after the await: a delivery may have merged in, or another run synced it.
    const row = readRow(deps.sql, k)
    if (!row) return undefined
    if (!paced) return void backoff(deps, row, "paced", at())
    const own = ev !== undefined && row.merged === 0
    const event: StackEvent = own
      ? ev
      : {
          svix_id: `${row.type}:${row.k}:${row.attempts}:${at()}`,
          // A merged sync reads the whole team and its member list (a team event); a re-check keeps its shape.
          type: row.type === "sync" ? "team.updated" : row.type,
          stack_team: row.stack_team,
          ...(row.stack_user ? { stack_user: row.stack_user } : {})
        }
    deps.sql.exec(`UPDATE stack_team_recheck SET due_at = ? WHERE k = ?`, at() + SYNC_LEASE_MS, k)
    let out: string
    try {
      out = await this.reconcile(deps, deps.stack!, event, row.type === "sync" ? -1 : row.attempts)
    } catch (e) {
      // A Stack failure (never its body, never a user id): the row waits and tries again.
      console.error(JSON.stringify({ msg: "stack webhook lookup failed", team: deps.team, type: row.type, error: String(e).slice(0, 200) }))
      const current = readRow(deps.sql, k)
      if (current) backoff(deps, current, "lookup", at())
      return undefined
    }
    // A reject ends this sync (logged with its code); a later delivery syncs the team again.
    if (out.startsWith("reject:")) console.error(JSON.stringify({ msg: "stack team sync rejected; ended", team: deps.team, code: out.slice("reject:".length) }))
    // Done: remove the row unless something changed it meanwhile (a merged delivery or a re-check that
    // reconcile scheduled bumps gen). A merged delivery's row runs again at once, as a full sync.
    const changed = deps.sql.exec(`DELETE FROM stack_team_recheck WHERE k = ? AND gen = ?`, k, row.gen).rowsWritten === 0
    if (changed) deps.sql.exec(`UPDATE stack_team_recheck SET due_at = ? WHERE k = ? AND merged = 1 AND type = 'sync'`, at(), k)
    // A confirmed delete is final: a team.deleted that merged meanwhile has nothing left to do (review P3).
    if (changed && out === "team_deleted") deps.sql.exec(`DELETE FROM stack_team_recheck WHERE k = ? AND type = 'team.deleted'`, k)
    return out
  }

  /** The alarm's work: due pending syncs and re-checks (one at a time with deliveries), then a page of a deleted team's members. */
  async wake(now: number): Promise<void> {
    const deps = this.deps()
    // Personal teams never mirror Stack; a team not mirrored yet may hold a re-check.
    if (deps.state().team?.kind === "personal") return
    ensureTables(deps.sql)
    const due = deps.sql.exec<{ k: string }>(`SELECT k FROM stack_team_recheck WHERE due_at <= ? ORDER BY due_at LIMIT 20`, now).toArray()
    for (const r of due) {
      const run = async () => {
        // Run only if it is still there and still due (another run may have synced or rescheduled it).
        if (deps.sql.exec(`SELECT 1 FROM stack_team_recheck WHERE k = ? AND due_at <= ?`, r.k, now).toArray().length > 0) await this.runRow(deps, r.k, undefined, now)
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
    // The plan copy is dated before the read (review P3): a slower read never looks newer than it is.
    const readAt = Date.now()
    const team = await stack.getTeam(ev.stack_team)
    // Stack still lists a team that a team.deleted named: change nothing now and ask again later, keeping the delete.
    if (team !== null && ev.type === "team.deleted") return schedule(deps.sql, ev, attempt, Date.now()) ? "team_delete_pending" : "team_delete_unconfirmed"
    if (team === null) {
      // Only Stack's own team.deleted, confirmed by this read, deletes the team.
      if (ev.type === "team.deleted") return commit("team.stack_mirror", { team: deps.team, stack_team: ev.stack_team, deleted: true }) ?? "team_deleted"
      return schedule(deps.sql, ev, attempt, Date.now()) ? "team_missing_recheck" : "team_missing_dropped"
    }
    // A cmux VM personal tenant is a private Stack team behind one personal owner: never a cmux team (team-vm-api-personal.ts).
    if (team.vm_personal_tenant === true) return "vm_personal_tenant_ignored"
    const missing = () => (schedule(deps.sql, ev, attempt, Date.now()) ? "team_missing_recheck" : "team_missing_dropped")
    // Members are read before the mirror commit: a team not mirrored here yet whose Stack members are all
    // anonymous is a cmux.com visitor's sign-up personal team (StackMember.anonymous) and is never mirrored.
    const fresh = deps.state().team == null
    let listed: ReadonlyArray<StackMember & { user_id: string }> | undefined
    let member: StackMember | null | undefined
    if (ev.stack_user === undefined) {
      const r = await stack.listTeamMembers(ev.stack_team)
      // The team was there a moment ago: never a tombstone from this read, only a later re-check.
      if (r === "team_gone") return missing()
      if (fresh && r.length > 0 && r.every((m) => m.anonymous === true)) return "anonymous_team_ignored"
      listed = r
    } else {
      const r = await stack.getTeamMember(ev.stack_team, ev.stack_user)
      if (r === "team_gone") return missing()
      // Only the named member was read: the team itself is mirrored by its team event if it has a signed-in member.
      if (fresh && r?.anonymous === true) return "member_anonymous"
      member = r
    }
    const mirrored = commit("team.stack_mirror", { team: deps.team, stack_team: ev.stack_team, display_name: displayName(team.display_name, "Team") })
    if (mirrored) return mirrored
    // The team's paid plan for the model router (inference/plan.ts): web billing's write to the
    // team metadata sends team.updated, so this copy follows a purchase or a lapse at once.
    storePlan(deps.sql, team.plan, readAt)
    // Stack sends no membership event for a team's creator or a sign-up personal team: a team event mirrors Stack's member list.
    if (listed !== undefined) return this.syncMembers(deps, listed, commit) ?? "team_mirrored"
    const user = userIdFor(deps.stackProjectId, ev.stack_user!)
    // An anonymous Stack user is never a member here: one already provisioned (before this rule) is removed.
    if (member?.anonymous === true) return memberOf(deps.state(), deps.rows(), user) ? (commit("team.member.remove", { user, from_stack: true }) ?? "member_anonymous_removed") : "member_anonymous"
    // Stack removed them: an owner of this Stack team is demoted and removed in one commit (review P2-1).
    if (member == null) return commit("team.member.remove", { user, from_stack: true }) ?? "member_absent"
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
  private syncMembers(deps: StackSyncDeps, listed: ReadonlyArray<StackMember & { user_id: string }>, commit: (op: string, params: Record<string, unknown>) => string | undefined): string | undefined {
    // Anonymous Stack users are left out, so one provisioned before this rule is removed below.
    const want = new Map(listed.filter((m) => m.anonymous !== true).map((m) => [userIdFor(deps.stackProjectId, UUIDISH.test(m.user_id) ? m.user_id.toLowerCase() : m.user_id), m] as const))
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
  // Pending syncs (cx-f5tk4): read failures (backoff), a generation bumped by every change, and whether a
  // second delivery merged in. `attempts` stays the team-missing re-check count. Checked once per instance.
  if (!migrated.has(sql)) {
    const have = new Set(sql.exec<{ name: string }>(`PRAGMA table_info(stack_team_recheck)`).toArray().map((c) => c.name))
    for (const c of ["fails", "gen", "merged", "urgent"]) if (!have.has(c)) sql.exec(`ALTER TABLE stack_team_recheck ADD COLUMN ${c} INTEGER NOT NULL DEFAULT 0`)
    migrated.add(sql)
  }
}
const migrated = new WeakSet<SqlStorage>()

const syncKey = (stackTeam: string) => `sync|${stackTeam}|`

const readRow = (sql: SqlStorage, k: string): QueueRow | undefined =>
  sql.exec<QueueRow>(`SELECT k, type, stack_team, stack_user, due_at, attempts, fails, gen, merged, urgent FROM stack_team_recheck WHERE k = ?`, k).toArray()[0]

/**
 * Records a delivery's pending sync, durably, before any Stack read (cx-f5tk4). A team.deleted keeps its own
 * row (only a confirmed delete deletes); every other event shares the team's sync row. A delivery that finds
 * the row there marks it merged (it runs as a full team sync) and bumps its generation; the row keeps its
 * time, so a new delivery never bypasses a backoff or a re-check wait.
 */
const enqueue = (sql: SqlStorage, ev: StackEvent, now: number): string => {
  const [k, type] = ev.type === "team.deleted" ? [`team.deleted|${ev.stack_team}|`, "team.deleted"] : [syncKey(ev.stack_team), "sync"]
  // A membership event or a waiting person marks the row urgent for good: it never takes the low lane.
  const urgent = ev.urgent === true || ev.type.startsWith("team_membership") ? 1 : 0
  sql.exec(`INSERT INTO stack_team_recheck (k, type, stack_team, stack_user, due_at, attempts, fails, gen, merged, urgent) VALUES (?, ?, ?, NULL, ?, -1, 0, 0, 0, ?) ON CONFLICT(k) DO UPDATE SET gen = gen + 1, merged = 1, urgent = MAX(urgent, excluded.urgent)`, k, type, ev.stack_team, now, urgent)
  return k
}

/** A pending row that could not read Stack now: back with backoff, or abandoned (logged) after SYNC_MAX_FAILS. */
const backoff = (deps: StackSyncDeps, row: QueueRow, why: "paced" | "lookup", at: number) => {
  const fails = row.fails + 1
  if (fails > SYNC_MAX_FAILS) {
    deps.sql.exec(`DELETE FROM stack_team_recheck WHERE k = ?`, row.k)
    // A stable alert key (cx-f5tk4): Axiom cmux-api-prod-logs, body contains "stack team sync abandoned".
    console.error(JSON.stringify({ msg: "stack team sync abandoned", team: deps.team, type: row.type, code: why, fails: row.fails }))
    return
  }
  deps.sql.exec(`UPDATE stack_team_recheck SET due_at = ?, fails = ? WHERE k = ?`, at + (why === "paced" ? pacedBackoffMs(fails) : syncBackoffMs(fails)), fails, row.k)
}

/** Asks Stack again later (attempt+1); false once the schedule is spent (logged). */
const schedule = (sql: SqlStorage, ev: StackEvent, attempt: number, now: number): boolean => {
  ensureTables(sql)
  const next = attempt + 1
  if (next >= RECHECK_DELAYS_MS.length) {
    console.error(JSON.stringify({ msg: "stack team still missing after re-checks; dropped", type: ev.type }))
    return false
  }
  // A pending delete and a membership re-check of the same team are separate rows.
  const type = ev.type === "team.deleted" ? "team.deleted" : "recheck"
  const k = `${type}|${ev.stack_team}|${ev.stack_user ?? ""}`
  // A re-check bumps the row's generation, so a sync that holds this key never removes it (cx-f5tk4).
  sql.exec(`INSERT INTO stack_team_recheck (k, type, stack_team, stack_user, due_at, attempts, fails, gen, merged) VALUES (?, ?, ?, ?, ?, ?, 0, 0, 0) ON CONFLICT(k) DO UPDATE SET type = excluded.type, stack_user = excluded.stack_user, due_at = excluded.due_at, attempts = excluded.attempts, fails = 0, gen = gen + 1, merged = 0`, k, type, ev.stack_team, ev.stack_user ?? null, now + RECHECK_DELAYS_MS[next]!, next)
  return true
}

export { noOwnerOf }
