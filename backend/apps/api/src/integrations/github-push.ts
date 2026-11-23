import type { ProviderEvent } from "./external.ts"

/**
 * GitHub changes pushed to a person's live clients (`github.changed` in the daemon's extension
 * streams, cmux-app-host/schema/v2/events.json). A verified webhook that changes what a pull
 * request list shows (the PR itself, a review, a check, a commit status) becomes a small
 * invalidation `{provider, repo, number?, kind}`: no titles, bodies or check output, the client
 * reads again through its own GitHub access.
 *
 * Who hears it: the users whose feed socket said `integration.watch` (FeedDO) and who may use the
 * connection the delivery came through (its linking user, or the whole team for a shared
 * connection). ConnectionDO keeps those listeners in a side table, so a 10,000-member team pays
 * only for the members who have cmux open, never one call per member.
 *
 * Cost per burst is constant: per listener, the first change goes out at once and the rest of a
 * window go out as one frame at its end (at most two sends per window however many deliveries).
 *
 * The GitHub App must subscribe to these events (App settings, Permissions & events): Pull
 * request, Pull request review, Check run, Check suite, Status. Its permissions already read pull
 * requests, checks and commit statuses; an event the App does not subscribe to never arrives, and
 * the client's slow re-read covers it.
 */

/** The webhook events (before the `.action`) that change a pull request list. */
export const GITHUB_PUSH_EVENTS: ReadonlySet<string> = new Set(["pull_request", "pull_request_review", "pull_request_review_thread", "check_run", "check_suite", "status"])

export type GithubChangeKind = "pull_request" | "pull_request_review" | "pull_request_review_thread" | "check_run" | "check_suite" | "status"

export interface GithubChange {
  readonly repo: string
  readonly number?: number
  readonly kind: GithubChangeKind
}

/** The frame a watching feed socket receives (cmux-feed-core cloud.rs `integration.changed`). */
export interface IntegrationChangedFrame {
  readonly t: "integration.changed"
  readonly provider: "github"
  readonly changes: ReadonlyArray<GithubChange>
  /** More changes came in this window than one frame carries: read everything again. */
  readonly more?: true
}

/** The most changes one frame names; past it the frame says `more`. */
export const MAX_CHANGES_PER_FRAME = 50
/** One window: the first change of a quiet listener goes now, the rest at the window's end. */
export const PUSH_WINDOW_MS = 1_500
/** A listener not heard from in this long is forgotten (its socket re-registers on every connect). */
export const LISTENER_TTL_MS = 24 * 60 * 60_000
/** The most listeners one team's ConnectionDO keeps; the oldest go first. */
export const MAX_LISTENERS = 10_000

const num = (v: unknown): number | undefined => (typeof v === "number" && Number.isSafeInteger(v) && v > 0 ? v : undefined)

/** The invalidation a delivery carries, or null for an event a pull request list does not show. */
export function githubChangeOf(event: ProviderEvent): GithubChange | null {
  if (event.provider !== "github") return null
  const kind = event.event.split(".")[0] ?? ""
  if (!GITHUB_PUSH_EVENTS.has(kind)) return null
  const p = (event.payload ?? {}) as Record<string, any>
  const repo = p.repository?.full_name
  if (typeof repo !== "string" || !/^[a-z\d][a-z\d-]*\/(?!\.\.?$)[\w.-]+$/i.test(repo)) return null
  const number =
    num(p.pull_request?.number) ??
    num(p.number) ??
    num(p.check_run?.pull_requests?.[0]?.number) ??
    num(p.check_suite?.pull_requests?.[0]?.number)
  return { repo: repo.toLowerCase(), ...(number !== undefined ? { number } : {}), kind: kind as GithubChangeKind }
}

const keyOf = (c: GithubChange) => `${c.repo}#${c.number ?? ""}:${c.kind}`

interface Pending {
  changes: Map<string, GithubChange>
  more: boolean
  /** When the last frame went to this listener. */
  sentAt: number
  timer: ReturnType<typeof setTimeout> | null
}

export interface CoalescerDeps {
  readonly send: (user: string, frame: IntegrationChangedFrame) => void
  readonly now?: () => number
  readonly setTimer?: (fn: () => void, ms: number) => ReturnType<typeof setTimeout>
  readonly windowMs?: number
}

/**
 * Per listener: a change to a quiet listener goes now; changes inside the window after a send
 * wait and go together at the window's end. In memory only: a lost window (the object was
 * evicted) costs one late re-read, which the client's slow re-read covers.
 */
export class GithubPushCoalescer {
  private readonly pending = new Map<string, Pending>()
  private readonly now: () => number
  private readonly setTimer: (fn: () => void, ms: number) => ReturnType<typeof setTimeout>
  private readonly windowMs: number

  constructor(private readonly deps: CoalescerDeps) {
    this.now = deps.now ?? Date.now
    this.setTimer = deps.setTimer ?? ((fn, ms) => setTimeout(fn, ms))
    this.windowMs = deps.windowMs ?? PUSH_WINDOW_MS
  }

  add(user: string, change: GithubChange): void {
    let p = this.pending.get(user)
    if (!p) this.pending.set(user, (p = { changes: new Map(), more: false, sentAt: -Infinity, timer: null }))
    if (p.changes.size < MAX_CHANGES_PER_FRAME) p.changes.set(keyOf(change), change)
    else if (!p.changes.has(keyOf(change))) p.more = true
    if (p.timer !== null) return
    const wait = p.sentAt + this.windowMs - this.now()
    if (wait <= 0) return this.flush(user)
    p.timer = this.setTimer(() => this.flush(user), wait)
  }

  private flush(user: string): void {
    const p = this.pending.get(user)
    if (!p) return
    p.timer = null
    if (p.changes.size === 0) {
      this.pending.delete(user)
      return
    }
    const frame: IntegrationChangedFrame = { t: "integration.changed", provider: "github", changes: [...p.changes.values()], ...(p.more ? { more: true as const } : {}) }
    p.changes = new Map()
    p.more = false
    p.sentAt = this.now()
    // The entry stays for one window, so a change right after this one waits for the window's end.
    p.timer = this.setTimer(() => this.flush(user), this.windowMs)
    this.deps.send(user, frame)
  }
}

/** The listener table (ConnectionDO side storage): the users whose live feed socket asked for GitHub changes. */
export const createListenerTable = (sql: SqlStorage) =>
  sql.exec(`CREATE TABLE IF NOT EXISTS integration_listeners (user TEXT PRIMARY KEY, provider TEXT NOT NULL, at INTEGER NOT NULL)`)

export function addListener(sql: SqlStorage, user: string, now: number): void {
  sql.exec(`INSERT INTO integration_listeners (user, provider, at) VALUES (?, 'github', ?) ON CONFLICT (user) DO UPDATE SET at = excluded.at`, user, now)
  sql.exec(`DELETE FROM integration_listeners WHERE at < ?`, now - LISTENER_TTL_MS)
  sql.exec(`DELETE FROM integration_listeners WHERE user IN (SELECT user FROM integration_listeners ORDER BY at DESC LIMIT -1 OFFSET ?)`, MAX_LISTENERS)
}

export const removeListener = (sql: SqlStorage, user: string) => sql.exec(`DELETE FROM integration_listeners WHERE user = ?`, user)

export const listeners = (sql: SqlStorage, now: number): Array<string> =>
  sql.exec<{ user: string }>(`SELECT user FROM integration_listeners WHERE at >= ?`, now - LISTENER_TTL_MS).toArray().map((r) => r.user)
