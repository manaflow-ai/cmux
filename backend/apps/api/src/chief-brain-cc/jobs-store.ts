import type { ChiefBrainDO } from "../chief-brain/brain-do.ts"
import { brainName } from "../chief-brain/brain-do.ts"
import { sha256Hex } from "../ingress/verify.ts"
import type { ChiefJob, JobDelivery } from "./jobs.ts"

/**
 * The record of every Chief job on the Upstash engine (jobs-upstash.ts), one brain object per owner's
 * personal team named `<team>/chief-jobs`, table cc_jobs. The record is the truth: a QStash schedule only
 * carries `{team, job}` and a fire whose record is gone does nothing (and removes its schedule). So a
 * listing reads this table, never QStash's account-wide schedule list.
 *
 * Runs that start here (a webhook delivery, a provider event, `chief-auto run`) go through the outbox
 * cc_job_runs: the row is written first under a run id derived from the job and the delivery, then sent
 * to Upstash as a workflow run with that id. A failed send retries from this object's own job
 * (`cj-send`, backoff, given up after SEND_ATTEMPTS); a redelivery of the same event finds its row and
 * starts nothing, and Upstash deduplicates the same workflow run id too.
 */

export const jobsStoreName = (team: string) => `${team}/chief-jobs`

export type JobTrigger =
  | { readonly type: "cron"; readonly expr: string; readonly tz: string }
  | { readonly type: "manual" }
  | { readonly type: "webhook" }
  | { readonly type: "event"; readonly provider: string; readonly event: string; readonly filter: Readonly<Record<string, string>> }

export type LastRun = { readonly run: string; readonly trigger: string; readonly at: number; readonly state: "delivered" | "refused" | "failed"; readonly code?: string }

export interface JobRecord {
  readonly id: string
  readonly agent: string
  readonly owner: string
  readonly conversation: string
  readonly name: string
  readonly prompt: string
  readonly trigger: JobTrigger
  readonly paused: boolean
  readonly created_at: number
  readonly last_run: LastRun | null
}

/** What a run sends to the workflow endpoint (a schedule's body is the cron form, with no input). */
export type FireBody = { readonly v: 2; readonly team: string; readonly job: string; readonly trigger: "cron" | "manual" | "webhook" | "event"; readonly input?: unknown }

/** A provider event as ConnectionDO.ingest forwards it. */
export type JobEvent = { readonly connection: string; readonly sharing: "private" | "team"; readonly created_by: string; readonly provider: string; readonly event: string; readonly delivery_id: string; readonly payload: unknown }

export type StoreOp =
  | { readonly op: "list"; readonly agent: string; readonly conversation: string | null }
  | { readonly op: "get"; readonly id: string }
  | { readonly op: "insert"; readonly job: Omit<JobRecord, "paused" | "created_at" | "last_run"> }
  | { readonly op: "remove"; readonly id: string }
  | { readonly op: "pause"; readonly id: string; readonly paused: boolean }
  | { readonly op: "enqueue"; readonly id: string; readonly run: string; readonly trigger: "manual" | "webhook"; readonly input?: unknown }
  | { readonly op: "event"; readonly ev: JobEvent }
  | { readonly op: "fire"; readonly body: FireBody; readonly run: string }
  | { readonly op: "failed"; readonly id: string; readonly run: string; readonly trigger: string; readonly message: string }

export type EnqueueResult = { readonly status: "accepted" | "duplicate" | "unknown" | "paused"; readonly run?: string }
export type FireResult = JobDelivery | { readonly ok: false; readonly code: "job.gone" | "job.paused"; readonly message: string }

/** Sends one workflow run to Upstash; injected by jobs-upstash.ts so this file needs no SDK. */
export type Sender = (run: string, body: FireBody) => Promise<void>

const SCHEMA = [
  `CREATE TABLE IF NOT EXISTS cc_jobs (id TEXT PRIMARY KEY, agent TEXT NOT NULL, owner TEXT NOT NULL, conversation TEXT NOT NULL, name TEXT NOT NULL, prompt TEXT NOT NULL, trigger TEXT NOT NULL, paused INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, last_run TEXT)`,
  `CREATE INDEX IF NOT EXISTS cc_jobs_agent ON cc_jobs (agent, conversation)`,
  `CREATE TABLE IF NOT EXISTS cc_job_runs (run TEXT PRIMARY KEY, job TEXT NOT NULL, body TEXT NOT NULL, state TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, next_at INTEGER NOT NULL, created_at INTEGER NOT NULL)`
]
/** A send that failed retries after 30 s, doubling to an hour; after this many it is given up (about a day). */
export const SEND_ATTEMPTS = 30
const SEND_BACKOFF_MS = 30_000
const SEND_BACKOFF_MAX_MS = 60 * 60_000
/** Sent rows are kept this long, so a provider's redelivery inside it still dedupes here. */
const KEEP_SENT_MS = 14 * 24 * 60 * 60_000
/** A run's input in the Chief's note is capped (jobNote); a bigger payload is reduced to its useful fields. */
export const INPUT_BYTES = 4000
/** Event filters a job may carry. */
export const MAX_FILTERS = 8

const ready = (b: ChiefBrainDO) => {
  for (const s of SCHEMA) b.sql.exec(s)
}
/** Does this object keep jobs? (An event for a team with no Chief jobs writes nothing.) */
const exists = (b: ChiefBrainDO) => b.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'table' AND name = 'cc_jobs'`).one().n > 0

type Row = { id: string; agent: string; owner: string; conversation: string; name: string; prompt: string; trigger: string; paused: number; created_at: number; last_run: string | null }
const record = (r: Row): JobRecord => ({
  id: r.id,
  agent: r.agent,
  owner: r.owner,
  conversation: r.conversation,
  name: r.name,
  prompt: r.prompt,
  trigger: JSON.parse(r.trigger) as JobTrigger,
  paused: r.paused === 1,
  created_at: r.created_at,
  last_run: r.last_run ? (JSON.parse(r.last_run) as LastRun) : null
})
const getJob = (b: ChiefBrainDO, id: string): JobRecord | null => {
  const r = b.sql.exec<Row>(`SELECT * FROM cc_jobs WHERE id = ?`, id).toArray()[0]
  return r ? record(r) : null
}
const setLastRun = (b: ChiefBrainDO, id: string, last: LastRun) => b.sql.exec(`UPDATE cc_jobs SET last_run = ? WHERE id = ?`, JSON.stringify(last), id)

/** Dot path lookup in a provider payload (filters compare the value as a string), as scheduler-events.ts does. */
const pathValue = (payload: unknown, path: string): unknown => {
  let v: unknown = payload
  for (const k of path.split(".")) {
    if (v === null || typeof v !== "object") return undefined
    v = (v as Record<string, unknown>)[k]
  }
  return v
}

/** Does an event trigger take this event? Same rules as the SchedulerDO's event triggers, by provider. */
export const eventMatches = (t: Extract<JobTrigger, { type: "event" }>, owner: string, ev: JobEvent): boolean => {
  if (t.provider !== ev.provider) return false
  // A private connection's events start only its creator's jobs.
  if (ev.sharing !== "team" && ev.created_by !== owner) return false
  const eventOk = t.event === "*" || t.event === ev.event || (t.event.endsWith(".*") && ev.event.startsWith(t.event.slice(0, -1)))
  return eventOk && Object.entries(t.filter).every(([k, v]) => String(pathValue(ev.payload, k)) === v)
}

/** Fields worth keeping when a payload is too big for the note (GitHub, Linear, Slack, Gmail shapes). */
const SUMMARY_PATHS = [
  "action",
  "repository.full_name",
  "sender.login",
  "workflow_run.name",
  "workflow_run.conclusion",
  "workflow_run.status",
  "workflow_run.event",
  "workflow_run.head_branch",
  "workflow_run.head_sha",
  "workflow_run.html_url",
  "workflow_run.run_attempt",
  "check_run.name",
  "check_run.conclusion",
  "check_run.html_url",
  "pull_request.number",
  "pull_request.title",
  "pull_request.html_url",
  "issue.number",
  "issue.title",
  "issue.html_url",
  "comment.html_url",
  "type",
  "data.identifier",
  "data.title",
  "data.url",
  "event.type",
  "event.channel",
  "subject",
  "from"
]
/** The run input of an event: the whole payload when it fits, else its useful fields. */
export const eventInput = (ev: JobEvent): unknown => {
  const whole = { provider: ev.provider, event: ev.event, delivery_id: ev.delivery_id, body: ev.payload }
  if (new TextEncoder().encode(JSON.stringify(whole)).byteLength <= INPUT_BYTES) return whole
  const summary: Record<string, unknown> = {}
  for (const p of SUMMARY_PATHS) {
    const v = pathValue(ev.payload, p)
    if (v !== undefined && v !== null && typeof v !== "object") summary[p] = typeof v === "string" ? v.slice(0, 300) : v
  }
  return { provider: ev.provider, event: ev.event, delivery_id: ev.delivery_id, truncated: true, summary }
}

/** A run id from what started it: the same delivery of the same job is the same run, here and at Upstash. */
export const runIdOf = async (job: string, delivery: string) => `cj_${(await sha256Hex(`${job}\n${delivery}`)).slice(0, 40)}`

/** Writes the outbox row (unless this run is known) and sends it now; a failed send waits for `cj-send`. */
const enqueue = async (b: ChiefBrainDO, send: Sender, run: string, body: FireBody): Promise<"accepted" | "duplicate"> => {
  const now = Date.now()
  const known = b.sql.exec(`SELECT run FROM cc_job_runs WHERE run = ?`, run).toArray().length > 0
  if (known) return "duplicate"
  // Old outcomes go here too, not only in `cj-send`, which runs only after a failed send.
  b.sql.exec(`DELETE FROM cc_job_runs WHERE state != 'pending' AND created_at < ?`, now - KEEP_SENT_MS)
  b.sql.exec(`INSERT INTO cc_job_runs (run, job, body, state, attempts, next_at, created_at) VALUES (?, ?, ?, 'pending', 0, ?, ?)`, run, body.job, JSON.stringify(body), now, now)
  await sendOne(b, send, run)
  return "accepted"
}

const sendOne = async (b: ChiefBrainDO, send: Sender, run: string): Promise<void> => {
  const r = b.sql.exec<{ body: string; attempts: number; state: string }>(`SELECT body, attempts, state FROM cc_job_runs WHERE run = ?`, run).toArray()[0]
  if (!r || r.state !== "pending") return
  const body = JSON.parse(r.body) as FireBody
  try {
    await send(run, body)
    b.sql.exec(`UPDATE cc_job_runs SET state = 'sent', attempts = attempts + 1 WHERE run = ?`, run)
  } catch (e) {
    const attempts = r.attempts + 1
    if (attempts >= SEND_ATTEMPTS) {
      b.sql.exec(`UPDATE cc_job_runs SET state = 'dropped', attempts = ? WHERE run = ?`, attempts, run)
      setLastRun(b, body.job, { run, trigger: body.trigger, at: Date.now(), state: "failed", code: `jobs.unavailable: ${String(e instanceof Error ? e.message : e).slice(0, 200)}` })
      return
    }
    const at = Date.now() + Math.min(SEND_BACKOFF_MS * 2 ** (attempts - 1), SEND_BACKOFF_MAX_MS)
    b.sql.exec(`UPDATE cc_job_runs SET attempts = ?, next_at = ? WHERE run = ?`, attempts, at, run)
    await b.schedule(`cj-send:${run}`, "cj-send", at)
  }
}

/** The `cj-send:<run>` job: send that run again (each run has its own job, so two never send the same row), prune old rows. */
export const jobsSendDue = async (b: ChiefBrainDO, send: Sender | null, run: string): Promise<void> => {
  if (!exists(b) || !send) return
  const now = Date.now()
  if (b.sql.exec(`SELECT run FROM cc_job_runs WHERE run = ? AND state = 'pending' AND next_at <= ?`, run, now).toArray().length > 0) await sendOne(b, send, run)
  b.sql.exec(`DELETE FROM cc_job_runs WHERE state != 'pending' AND created_at < ?`, now - KEEP_SENT_MS)
}

/** One store call. `send` is null when the engine is off: then nothing starts; reads and removes still work. */
export const jobsStore = async (b: ChiefBrainDO, team: string, o: StoreOp, send: Sender | null): Promise<unknown> => {
  if (o.op === "event") {
    if (!exists(b) || !send) return { runs: 0 }
    const sends: Array<Promise<"accepted" | "duplicate">> = []
    for (const r of b.sql.exec<Row>(`SELECT * FROM cc_jobs WHERE paused = 0`).toArray()) {
      const job = record(r)
      if (job.trigger.type !== "event" || !eventMatches(job.trigger, job.owner, o.ev)) continue
      // By delivery alone: two linked connections that see the same delivery start one run.
      const run = await runIdOf(job.id, `${o.ev.provider}:${o.ev.delivery_id}`)
      sends.push(enqueue(b, send, run, { v: 2, team, job: job.id, trigger: "event", input: eventInput(o.ev) }))
    }
    // The provider's webhook waits on this: the sends run together, and a failed one waits in the outbox.
    return { runs: (await Promise.all(sends)).filter((x) => x === "accepted").length }
  }
  ready(b)
  switch (o.op) {
    case "list": {
      const rows = o.conversation === null ? b.sql.exec<Row>(`SELECT * FROM cc_jobs WHERE agent = ? ORDER BY created_at`, o.agent) : b.sql.exec<Row>(`SELECT * FROM cc_jobs WHERE agent = ? AND conversation = ? ORDER BY created_at`, o.agent, o.conversation)
      return rows.toArray().map(record)
    }
    case "get":
      return getJob(b, o.id)
    case "insert": {
      const j = o.job
      b.sql.exec(`INSERT INTO cc_jobs (id, agent, owner, conversation, name, prompt, trigger, paused, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?)`, j.id, j.agent, j.owner, j.conversation, j.name, j.prompt, JSON.stringify(j.trigger), Date.now())
      return getJob(b, j.id)
    }
    case "remove":
      b.sql.exec(`DELETE FROM cc_jobs WHERE id = ?`, o.id)
      // Runs not sent yet are dropped with it; sent ones find no record and do nothing.
      b.sql.exec(`UPDATE cc_job_runs SET state = 'dropped' WHERE job = ? AND state = 'pending'`, o.id)
      return { removed: o.id }
    case "pause":
      b.sql.exec(`UPDATE cc_jobs SET paused = ? WHERE id = ?`, o.paused ? 1 : 0, o.id)
      return getJob(b, o.id)
    case "enqueue": {
      const job = getJob(b, o.id)
      // A webhook delivery reaches only a webhook job (the URL's secret is only ever given for one).
      if (!job || (o.trigger === "webhook" && job.trigger.type !== "webhook")) return { status: "unknown" } satisfies EnqueueResult
      // A paused job still runs when asked by name (`chief-auto run`); its triggers wait.
      if (job.paused && o.trigger !== "manual") return { status: "paused" } satisfies EnqueueResult
      if (!send) return { status: "unknown" } satisfies EnqueueResult
      const status = await enqueue(b, send, o.run, { v: 2, team, job: job.id, trigger: o.trigger, ...(o.input === undefined ? {} : { input: o.input }) })
      // Upstash names the run `wfr_<our id>` (its run id prefix); that is the id the step and `ls` see.
      return { status, run: `wfr_${o.run}` } satisfies EnqueueResult
    }
    case "fire":
      return fire(b, o.body, o.run)
    case "failed":
      if (getJob(b, o.id)) setLastRun(b, o.id, { run: o.run, trigger: o.trigger, at: Date.now(), state: "failed", code: o.message.slice(0, 300) })
      return { ok: true }
  }
}

/** The workflow's step: the record decides, then the Chief's conversation brain gets the note (once per run). */
const fire = async (b: ChiefBrainDO, body: FireBody, run: string): Promise<FireResult> => {
  const job = getJob(b, body.job)
  if (!job) return { ok: false, code: "job.gone", message: "the job was removed" }
  if (job.paused && body.trigger !== "manual") return { ok: false, code: "job.paused", message: "the job is paused" }
  const brain = b.doEnv.CHIEF_BRAIN_DO.get(b.doEnv.CHIEF_BRAIN_DO.idFromName(brainName(job.agent, job.conversation))) as unknown as { chiefJob(j: ChiefJob): Promise<JobDelivery> }
  const out = await brain.chiefJob({
    run: `upstash:${run}`,
    automation: job.id,
    chief: job.agent,
    conversation: job.conversation,
    prompt: job.prompt,
    trigger: body.trigger,
    ...(body.input === undefined ? {} : { input: body.input }),
    // Charged to the owner the job was made for; the brain refuses it unless that is the Chief's owner.
    charged_user: job.owner
  })
  // A transient refusal (the Chief's record could not be read) throws, so Upstash retries the step.
  if (!out.ok && out.retry) throw new Error(`${out.code}: ${out.message}`)
  setLastRun(b, job.id, out.ok ? { run, trigger: body.trigger, at: Date.now(), state: "delivered" } : { run, trigger: body.trigger, at: Date.now(), state: "refused", code: out.code })
  return out
}
