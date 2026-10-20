import { conversation as homeConversation } from "@cmux/home-core"
import type { OwnerFrame, Principal } from "@cmux/ownership"
import type { Env } from "./env.ts"
import type { ReadResult, SubmitResult } from "./owner-do.ts"

/**
 * Cloud Home health (plans/cmux-next/home-messaging-invites/DESIGN.md section 3, H1).
 *
 * Every five minutes (wrangler cron HOME_HEALTH_CRON) the Worker sends one message between two
 * probe users through the real owners: dm.open and message.send on the pair's ConversationDO,
 * then the message must show in the peer's UserDO inbox. No HTTP auth, no email, no push device:
 * the probe ids are not Stack-derived (`user_` + 20 hex characters), so they never collide with a
 * person. The DM is opened by id every run (idempotent) and keeps 30 days of history (the shortest
 * retention a conversation allows), so it stays bounded.
 *
 * Alerting is a Sentry Cron check-in per run (secret SENTRY_DSN): Sentry opens one issue after
 * two failed check-ins in a row, also when check-ins stop (the Worker or its cron is down, which
 * no in-Worker counter can report), and resolves it on the next good one. Without SENTRY_DSN the
 * run only logs.
 */

export const HOME_HEALTH_CRON = "*/5 * * * *"
export const PROBE_SENDER = "user_homeprobesender"
export const PROBE_PEER = "user_homeprobepeer"
/** Poll the peer's inbox until the fanout lands, at most this long (the cron run's own deadline). */
const READ_DEADLINE_MS = 20_000
const READ_POLL_MS = 250
const RETENTION_DAYS = 30

export type ProbeStep = "open" | "send" | "read" | "done"
export interface ProbeResult {
  readonly ok: boolean
  /** The step that failed, or `done`. */
  readonly step: ProbeStep
  readonly latency_ms: number
  readonly code?: string
}

export type HealthFetch = (url: string, init: { method: string; headers: Record<string, string>; body: string }) => Promise<{ readonly status: number }>
export interface HomeHealthDeps {
  readonly fetcher: HealthFetch
  readonly readDeadlineMs?: number
}

interface ConversationProbeStub {
  submit(entity: string, principal: Principal, frame: unknown): Promise<SubmitResult>
}
interface InboxProbeStub {
  readInbox(entity: string, principal: Principal, op: string, params: unknown): Promise<ReadResult>
}

const sender: Principal = {
  identity: `system:home-health:${PROBE_SENDER}`,
  user: PROBE_SENDER,
  kind: "session",
  display_name: "Cloud Home probe",
  // The Worker's reach facts for the peer (home-reach.ts would resolve them from a shared team).
  home_reach: [{ user: PROBE_PEER, display_name: "Cloud Home probe peer", shared_team: true, connected: true, allow_requests_from: "teams" }]
}
const peer: Principal = { identity: `system:home-health:${PROBE_PEER}`, user: PROBE_PEER, kind: "session" }

const replyOf = (r: SubmitResult): OwnerFrame | undefined => r.frames.find((f) => f.t === "result" || f.t === "reject")
const codeOf = (f: OwnerFrame | undefined) => (f?.t === "reject" ? f.code : "no_reply")
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

/** One synthetic round trip; never throws. */
export const probeHome = async (env: Env, readDeadlineMs = READ_DEADLINE_MS): Promise<ProbeResult> => {
  const started = Date.now()
  const done = (ok: boolean, step: ProbeStep, code?: string): ProbeResult => ({ ok, step, latency_ms: Date.now() - started, ...(code ? { code } : {}) })
  const run = crypto.randomUUID()
  const id = homeConversation.dmConversationId(PROBE_SENDER, PROBE_PEER)
  let step: ProbeStep = "open"
  try {
    const conversation = env.CONVERSATION_DO.get(env.CONVERSATION_DO.idFromName(id)) as unknown as ConversationProbeStub
    const participants = [{ id: PROBE_SENDER, kind: "human" }, { id: PROBE_PEER, kind: "human" }]
    const opened = replyOf(await conversation.submit(id, sender, { t: "op", op: "dm.open", params: { id, participants, retention_days: RETENTION_DAYS }, idempotency_key: `home-health:open:${run}`, origin: "script" }))
    if (opened?.t !== "result") return done(false, step, codeOf(opened))
    step = "send"
    const text = `Cloud Home probe ${run}`
    // message.send: the client message id is the idempotency key (home-core apply.ts).
    const sent = replyOf(await conversation.submit(id, sender, { t: "op", op: "message.send", params: { client_msg_id: run, parts: [{ type: "text", text }] }, idempotency_key: run, origin: "script" }))
    if (sent?.t !== "result") return done(false, step, codeOf(sent))
    step = "read"
    const inbox = env.USER_DO.get(env.USER_DO.idFromName(PROBE_PEER)) as unknown as InboxProbeStub
    const deadline = Date.now() + readDeadlineMs
    for (;;) {
      const read = await inbox.readInbox(PROBE_PEER, peer, "inbox.list", { limit: 10 })
      if (!read.ok) return done(false, step, read.code)
      const entries = (read.value as { entries?: ReadonlyArray<{ conversation: string; preview: string }> }).entries ?? []
      // The preview is `Author: text` (home-core fanout.ts previewOf).
      if (entries.some((e) => e.conversation === id && e.preview.endsWith(text))) return done(true, "done")
      if (Date.now() >= deadline) return done(false, step, "inbox_timeout")
      await sleep(READ_POLL_MS)
    }
  } catch (e) {
    return done(false, step, e instanceof Error ? e.name : "error")
  }
}

/** A DSN `https://<public key>@<host>/<project>` as the envelope URL and key, or null. */
const parseDsn = (dsn: string | undefined): { url: string; key: string } | null => {
  if (!dsn) return null
  try {
    const u = new URL(dsn)
    const project = u.pathname.replace(/^\/+|\/+$/g, "")
    if (!u.username || !/^\d+$/.test(project)) return null
    return { url: `${u.protocol}//${u.host}/api/${project}/envelope/`, key: u.username }
  } catch {
    return null
  }
}

/** The cron run: probe, log, and one Sentry Cron check-in. Never throws. */
export const runHomeHealth = async (env: Env, deps: HomeHealthDeps): Promise<{ probe: ProbeResult; check_in: "sent" | "skipped" | "failed" }> => {
  const probe = await probeHome(env, deps.readDeadlineMs)
  console.log(JSON.stringify({ msg: probe.ok ? "home.health.ok" : "home.health.failed", ...probe }))
  const target = parseDsn(env.SENTRY_DSN)
  if (!target) return { probe, check_in: "skipped" }
  const environment = env.ENVIRONMENT
  const checkIn = {
    check_in_id: crypto.randomUUID().replace(/-/g, ""),
    monitor_slug: `cloud-home-${environment}`,
    status: probe.ok ? "ok" : "error",
    duration: probe.latency_ms / 1000,
    environment,
    monitor_config: { schedule: { type: "crontab", value: HOME_HEALTH_CRON }, checkin_margin: 5, max_runtime: 2, timezone: "UTC", failure_issue_threshold: 2, recovery_threshold: 1 }
  }
  const body = [JSON.stringify({ sent_at: new Date().toISOString() }), JSON.stringify({ type: "check_in" }), JSON.stringify(checkIn)].join("\n") + "\n"
  try {
    const res = await deps.fetcher(target.url, {
      method: "POST",
      headers: { "content-type": "application/x-sentry-envelope", "x-sentry-auth": `Sentry sentry_version=7, sentry_key=${target.key}, sentry_client=cmux-api-home-health/1` },
      body
    })
    if (res.status >= 200 && res.status < 300) return { probe, check_in: "sent" }
    console.error(JSON.stringify({ msg: "home.health.check_in_failed", status: res.status }))
  } catch (e) {
    console.error(JSON.stringify({ msg: "home.health.check_in_failed", reason: e instanceof Error ? e.name : "error" }))
  }
  return { probe, check_in: "failed" }
}

/** The production fetcher (tests pass their own). */
export const sentryFetch: HealthFetch = (url, init) => fetch(url, init)
