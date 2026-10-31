import { Client as QStash, QstashError, Receiver } from "@upstash/qstash"
import { Client as WorkflowClient } from "@upstash/workflow"
import { serve } from "@upstash/workflow/cloudflare"
import type { Principal } from "@cmux/ownership"
import { checkCron, nextFire } from "../cron.ts"
import type { Env } from "../env.ts"
import { automationHookSecret, TEAM, verifyCmuxHook } from "../ingress/automation-hook.ts"
import { type EnqueueResult, type FireBody, type FireResult, type JobEvent, type JobRecord, type JobTrigger, jobsStoreName, MAX_FILTERS, runIdOf, type Sender, type StoreOp } from "./jobs-store.ts"

/**
 * Chief jobs on Upstash Workflow (issue 25573; on with CHIEF_JOBS_ENGINE=upstash and the QStash settings).
 *
 * Upstash keeps the clock and runs each fire durably; we keep the records. A job is a row of the owner's
 * `<team>/chief-jobs` store (jobs-store.ts). Triggers:
 * - cron: a QStash schedule (`CRON_TZ=<tz> <cron>`, schedule id = job id) whose body is `{team, job}`;
 * - webhook: `POST /v1/hooks/chief-job/<team>/<job>`, signed like automation webhooks (x-cmux-signature);
 * - event: a provider event of the team's connections (ConnectionDO.ingest), for example GitHub's
 *   `workflow_run.completed` with `workflow_run.conclusion=failure`: CI went red, pushed by GitHub;
 * - manual: only `chief-auto run`.
 * Every fire is one workflow run on the endpoint below. Its step reads the record (removed: nothing runs and
 * the schedule goes; paused: nothing runs) and hands the prompt to the Chief's conversation brain
 * (`chiefJob`, the delivery the SchedulerDO path uses), keyed by the run id, so a retried step queues the
 * note once. Upstash retries the step; when retries run out the failure lands on the record (`ls`). Nothing
 * here polls or keeps a timer.
 *
 * Every request to the workflow endpoint must carry a valid QStash signature: its body names the job, and
 * the job's prompt becomes the Chief's own note. With the engine off, jobs stay on the SchedulerDO (jobs.ts).
 */

export const UPSTASH_WORKFLOW_PATH = "/v1/hooks/upstash/chief-job"
export const CHIEF_JOB_HOOK = /^\/v1\/hooks\/chief-job\/([^/]+)\/([^/]+)$/
const chiefJobHookPath = (team: string, job: string) => `/v1/hooks/chief-job/${team}/${job}`
const JOB = /^cj-[A-Za-z0-9]{1,64}-[0-9a-f]{20}$/
/** A run's delivery retries (QStash retries the step that threw). */
const RETRIES = 5
/** Providers a job can listen to (the team's connections deliver their events). */
export const EVENT_PROVIDERS = ["github", "linear", "slack", "gmail"] as const
const EVENT_NAME = /^(\*|[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*(\.\*)?)$/
const FILTER_KEY = /^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+){0,7}$/

type Out = { status: number; json: unknown }
type Config = { readonly token: string; readonly url: string; readonly baseUrl?: string; readonly current: string; readonly next: string }

/** The engine's settings, or null when Chief jobs run on the SchedulerDO (the default). */
export const upstashConfig = (env: Env): Config | null => {
  if (env.CHIEF_JOBS_ENGINE !== "upstash") return null
  const token = env.QSTASH_TOKEN
  const url = env.CHIEF_JOBS_WORKFLOW_URL
  const current = env.QSTASH_CURRENT_SIGNING_KEY
  const next = env.QSTASH_NEXT_SIGNING_KEY
  // Half-configured is off, never unsigned: every setting or none.
  if (!token || !url || !current || !next) return null
  return { token, url, current, next, ...(env.QSTASH_URL ? { baseUrl: env.QSTASH_URL } : {}) }
}

// Two network retries in the SDK, then the error: the outbox (jobs-store.ts) retries a run that did not start.
const clientOf = (c: Config) => ({ token: c.token, retry: { retries: 2 }, ...(c.baseUrl ? { baseUrl: c.baseUrl } : {}) })
const qstash = (c: Config) => new QStash(clientOf(c))
const workflows = (c: Config) => new WorkflowClient(clientOf(c))

/** Starts one workflow run with our run id (Upstash deduplicates a run id it has seen). */
const senderOf =
  (c: Config): Sender =>
  async (run, body) => {
    await workflows(c).trigger({ url: c.url, body: JSON.stringify(body), workflowRunId: run, retries: RETRIES })
  }
export const upstashSender = (env: Env): Sender | null => {
  const c = upstashConfig(env)
  return c ? senderOf(c) : null
}

type Store = { cjStore(team: string, o: StoreOp): Promise<unknown> }
const storeOf = (env: Env, team: string) => env.CHIEF_BRAIN_DO.get(env.CHIEF_BRAIN_DO.idFromName(jobsStoreName(team))) as unknown as Store
const store = <T>(env: Env, team: string, o: StoreOp) => storeOf(env, team).cjStore(team, o) as Promise<T>

/** Removes a schedule; one QStash no longer has is already removed. */
const unschedule = async (c: Config, id: string) => {
  try {
    await qstash(c).schedules.delete(id)
  } catch (e) {
    if (!(e instanceof QstashError && e.status === 404)) throw e
  }
}

/** Pause or resume a cron job's schedule; a schedule already gone is fine (its next fire would remove it anyway). */
const flipSchedule = async (c: Config, id: string, paused: boolean) => {
  try {
    await (paused ? qstash(c).schedules.pause({ schedule: id }) : qstash(c).schedules.resume({ schedule: id }))
  } catch (e) {
    if (!(e instanceof QstashError && e.status === 404)) throw e
  }
}

const newId = (agent: string) => `cj-${agent.replace(/[^A-Za-z0-9]/g, "").slice(0, 64)}-${crypto.randomUUID().replace(/-/g, "").slice(0, 20)}`

/**
 * WHEN as `chief-auto add` takes it: `manual`, `webhook`, a 5-field cron, or an event:
 * `PROVIDER EVENT [PATH=VALUE ...]`, e.g. `github workflow_run.completed workflow_run.conclusion=failure`.
 */
export const parseWhen = (when: string | null, tz: string): { ok: true; trigger: JobTrigger } | { ok: false; error: string } => {
  if (!when || when === "manual") return { ok: true, trigger: { type: "manual" } }
  if (when === "webhook") return { ok: true, trigger: { type: "webhook" } }
  const words = when.trim().split(/\s+/)
  if ((EVENT_PROVIDERS as ReadonlyArray<string>).includes(words[0]!)) {
    const [provider, event, ...pairs] = words
    if (!event || !EVENT_NAME.test(event)) return { ok: false, error: `an event job's WHEN is "${provider} EVENT [PATH=VALUE ...]", e.g. "github workflow_run.completed workflow_run.conclusion=failure"` }
    if (pairs.length > MAX_FILTERS) return { ok: false, error: `at most ${MAX_FILTERS} PATH=VALUE filters` }
    const filter: Record<string, string> = {}
    for (const p of pairs) {
      const at = p.indexOf("=")
      const key = at > 0 ? p.slice(0, at) : ""
      const value = p.slice(at + 1)
      if (!FILTER_KEY.test(key) || !value || value.length > 200) return { ok: false, error: `filter "${p.slice(0, 80)}" is not PATH=VALUE (PATH like workflow_run.conclusion, VALUE without spaces)` }
      filter[key] = value
    }
    return { ok: true, trigger: { type: "event", provider: provider!, event, filter } }
  }
  const check = checkCron(when, tz)
  return check.ok ? { ok: true, trigger: { type: "cron", expr: when, tz } } : { ok: false, error: `trigger.invalid: ${check.message}` }
}

/** One job as `chief-auto ls` shows it. */
export type JobView = {
  id: string
  name: string
  enabled: boolean
  triggers: Array<Record<string, unknown>>
  next_run_at: number | null
  prompt: string | undefined
  last_run?: unknown
  webhook?: { url: string }
}
const origin = (c: Config) => new URL(c.url).origin
const viewOf = (c: Config, team: string, j: JobRecord): JobView => ({
  id: j.id,
  name: j.name,
  enabled: !j.paused,
  triggers: [j.trigger as Record<string, unknown>],
  next_run_at: j.trigger.type === "cron" && !j.paused ? nextFire(j.trigger.expr, j.trigger.tz, Date.now()) : null,
  prompt: j.prompt,
  last_run: j.last_run,
  ...(j.trigger.type === "webhook" ? { webhook: { url: `${origin(c)}${chiefJobHookPath(team, j.id)}` } } : {})
})
const hookOf = async (env: Env, c: Config, team: string, id: string) => ({
  url: `${origin(c)}${chiefJobHookPath(team, id)}`,
  secret: await automationHookSecret(env, team, id),
  scheme: "x-cmux-timestamp: unix seconds; x-cmux-signature: v1=hex(HMAC-SHA256(secret, x-cmux-timestamp + '.' + body)); a repeat of the same timestamp and body runs once"
})

export type UpstashCreate = { readonly name: string; readonly prompt: string; readonly when: string | null; readonly tz: string }

/** Jobs made before the engine was on (SchedulerDO automations, jobs.ts): still listed, run, paused and removed. */
export type LegacyJobs = {
  list(conversation: string | null): Promise<Array<JobView>>
  act(action: "auto_rm" | "auto_run" | "auto_pause" | "auto_resume", id: string): Promise<Out>
}

const ACTIONS = "auto_create, auto_list, auto_rm, auto_run, auto_pause, auto_resume or auto_hook"

/** `chief-auto` on Upstash. `gate` is the plan check (jobs.ts), given how many jobs this Chief has in all its chats. */
export const upstashAuto = async (
  env: Env,
  c: Config,
  p: Principal,
  conversation: string,
  action: string,
  req: Record<string, unknown>,
  create: UpstashCreate | null,
  gate: (count: number) => Promise<Out | null>,
  legacy: LegacyJobs
): Promise<Out> => {
  const team = p.team!
  const mine = (j: JobRecord | null): j is JobRecord => j !== null && j.agent === p.agent && j.owner === p.user && j.conversation === conversation
  try {
    if (action === "auto_list") {
      const jobs = await store<Array<JobRecord>>(env, team, { op: "list", agent: p.agent!, conversation })
      return { status: 200, json: { jobs: [...(await legacy.list(conversation)), ...jobs.map((j) => viewOf(c, team, j))] } }
    }
    if (action === "auto_rm" || action === "auto_run" || action === "auto_pause" || action === "auto_resume" || action === "auto_hook") {
      const id = typeof req.automation === "string" ? req.automation.trim().slice(0, 100) : ""
      if (id && !id.startsWith("cj-") && action !== "auto_hook") return legacy.act(action, id)
      const job = JOB.test(id) ? await store<JobRecord | null>(env, team, { op: "get", id }) : null
      if (!mine(job)) return { status: 404, json: { error: `no job ${id || "(no id)"} of yours in this chat (chief-auto ls)` } }
      if (action === "auto_rm") {
        // The record first: if the schedule delete then fails, its next fire finds no record and removes it.
        await store(env, team, { op: "remove", id })
        // The job is gone once its record is: a failed schedule delete is cleaned up by that schedule's next fire.
        if (job.trigger.type === "cron") await unschedule(c, id).catch((e) => console.warn(JSON.stringify({ msg: "chief job schedule not deleted", team, job: id, reason: String(e instanceof Error ? e.message : e).slice(0, 300) })))
        return { status: 200, json: { removed: id } }
      }
      if (action === "auto_run") {
        const r = await store<EnqueueResult>(env, team, { op: "enqueue", id, run: `cj_run_${crypto.randomUUID().replace(/-/g, "")}`, trigger: "manual" })
        return r.status === "unknown" ? { status: 404, json: { error: `no job ${id}` } } : { status: 200, json: { run: { id: r.run } } }
      }
      if (action === "auto_hook") {
        if (job.trigger.type !== "webhook") return { status: 400, json: { error: `${id} is not a webhook job` } }
        return { status: 200, json: { webhook: await hookOf(env, c, team, id) } }
      }
      const paused = action === "auto_pause"
      if (job.trigger.type === "cron") await flipSchedule(c, id, paused)
      const after = await store<JobRecord>(env, team, { op: "pause", id, paused })
      return { status: 200, json: { job: viewOf(c, team, after) } }
    }
    if (!create) return { status: 400, json: { error: `action must be ${ACTIONS}` } }
    const parsed = parseWhen(create.when, create.tz)
    if (!parsed.ok) return { status: 400, json: { error: parsed.error, code: "trigger.invalid" } }
    const all = await store<Array<JobRecord>>(env, team, { op: "list", agent: p.agent!, conversation: null })
    const blocked = await gate(all.length + (await legacy.list(null)).length)
    if (blocked) return blocked
    const id = newId(p.agent!)
    const made = await store<JobRecord>(env, team, { op: "insert", job: { id, agent: p.agent!, owner: p.user!, conversation, name: create.name, prompt: create.prompt, trigger: parsed.trigger } })
    if (parsed.trigger.type === "cron") {
      try {
        await qstash(c).schedules.create({
          scheduleId: id,
          destination: c.url,
          cron: `CRON_TZ=${parsed.trigger.tz} ${parsed.trigger.expr}`,
          body: JSON.stringify({ v: 2, team, job: id, trigger: "cron" } satisfies FireBody),
          headers: { "content-type": "application/json" },
          retries: RETRIES
        })
      } catch (e) {
        // No schedule, no job: the record goes too, so `ls` never shows a job that cannot fire.
        await store(env, team, { op: "remove", id })
        throw e
      }
    }
    return { status: 200, json: { job: viewOf(c, team, made), ...(parsed.trigger.type === "webhook" ? { webhook: await hookOf(env, c, team, id) } : {}) } }
  } catch (e) {
    // QStash down or refusing: say so to the Chief; nothing was half-made.
    return { status: 502, json: { error: `jobs.unavailable: ${e instanceof Error ? e.message : String(e)}`.slice(0, 500), code: "jobs.unavailable" } }
  }
}

/** ConnectionDO.ingest: acknowledge an enabled engine's event only after its runs reach the durable store. */
export const chiefJobsEvent = async (env: Env, team: string, ev: JobEvent): Promise<number> => {
  if (!upstashConfig(env)) return 0
  try {
    return ((await store<{ runs: number }>(env, team, { op: "event", ev })).runs ?? 0) as number
  } catch (e) {
    console.warn(JSON.stringify({ msg: "chief jobs event not delivered", team, event: ev.event, delivery: ev.delivery_id, reason: String(e instanceof Error ? e.message : e).slice(0, 300) }))
    throw e
  }
}

/** POST /v1/hooks/chief-job/<team>/<job>: a signed webhook delivery starts one run of a webhook job. */
export const handleChiefJobHook = async (request: Request, env: Env, team: string, job: string): Promise<Response> => {
  if (!upstashConfig(env) || !TEAM.test(team) || !JOB.test(job)) return Response.json({ ok: false, code: "selector.not_found" }, { status: 404 })
  const v = await verifyCmuxHook(request, env, team, job)
  if (!v.ok) return v.response
  const r = await store<EnqueueResult>(env, team, { op: "enqueue", id: job, run: await runIdOf(job, v.delivery), trigger: "webhook", input: v.input })
  const label = v.label ? { label: v.label } : {}
  if (r.status === "unknown") return Response.json({ ok: false, code: "selector.not_found" }, { status: 404 })
  if (r.status === "paused") return Response.json({ ok: false, code: "automation.disabled", delivery: v.delivery, ...label }, { status: 409 })
  return Response.json({ ok: true, delivery: v.delivery, ...label, status: r.status, run: r.run }, { status: 202 })
}

const parseFire = (body: string | undefined): FireBody | null => {
  if (!body) return null
  try {
    const j = JSON.parse(body) as Partial<FireBody>
    const trigger = j.trigger === "cron" || j.trigger === "manual" || j.trigger === "webhook" || j.trigger === "event"
    return j.v === 2 && typeof j.team === "string" && TEAM.test(j.team) && typeof j.job === "string" && JOB.test(j.job) && trigger ? (j as FireBody) : null
  } catch {
    return null
  }
}

/** POST /v1/hooks/upstash/chief-job: one Upstash Workflow run of a Chief job (signed by QStash). */
export const handleUpstashChiefJob = async (request: Request, env: Env): Promise<Response> => {
  const c = upstashConfig(env)
  if (!c) return Response.json({ error: "chief jobs do not run on Upstash here" }, { status: 404 })
  const receiver = new Receiver({ currentSigningKey: c.current, nextSigningKey: c.next })
  const protocol = ["upstash-workflow-sdk-version", "upstash-workflow-unknown-sdk", "upstash-workflow-is-failure", "upstash-workflow-failure-callback"].some((h) => request.headers.has(h))
  if (!protocol) {
    // A schedule sends an ordinary QStash message. serve() would choose a fresh workflow id on each
    // redelivery, so authenticate it first and trigger with the same id for that scheduled message.
    const raw = await request.text()
    try {
      if (!(await receiver.verify({ body: raw, signature: request.headers.get("upstash-signature") ?? "", url: c.url }))) return Response.json({ error: "invalid QStash signature" }, { status: 401 })
    } catch {
      return Response.json({ error: "invalid QStash signature" }, { status: 401 })
    }
    const body = parseFire(raw)
    const message = request.headers.get("upstash-message-id")
    if (!body || body.trigger !== "cron" || !message || message.length > 256) return Response.json({ error: "not a scheduled chief job" }, { status: 400 })
    try {
      await senderOf(c)(await runIdOf(body.job, `qstash:${message}`), body)
      return Response.json({ ok: true })
    } catch {
      // The schedule retries with the same message id, including when Upstash took the run but its ack was lost.
      return Response.json({ error: "chief job workflow unavailable" }, { status: 503 })
    }
  }
  const handler = serve<FireBody>(
    async (context) => {
      const body = context.requestPayload
      const out = await context.run("cmux:chief", () => store<FireResult>(env, body.team, { op: "fire", body, run: context.workflowRunId }))
      // A removed job's schedule that still fired (the remove stopped between the two): remove it now.
      if (!out.ok && out.code === "job.gone" && body.trigger === "cron") await context.run("cmux:unschedule", () => unschedule(c, body.job))
      if (!out.ok) console.warn(JSON.stringify({ msg: "chief job not delivered", job: body.job, run: context.workflowRunId, code: out.code }))
    },
    {
      url: c.url,
      qstashClient: qstash(c),
      receiver,
      initialPayloadParser: (body) => {
        const job = parseFire(body)
        if (!job) throw new Error("not a chief job")
        return job
      },
      // Retries ran out: the record says so, `chief-auto ls` shows it.
      failureFunction: async ({ context, failResponse }) => {
        const body = context.requestPayload
        await store(env, body.team, { op: "failed", id: body.job, run: context.workflowRunId, trigger: body.trigger, message: failResponse })
      },
      disableTelemetry: true
    }
  )
  return handler.fetch(request, env as unknown as Record<string, string | undefined>)
}
