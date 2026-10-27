import { Client as QStash, Receiver } from "@upstash/qstash"
import { Client as WorkflowClient } from "@upstash/workflow"
import { serve } from "@upstash/workflow/cloudflare"
import type { Principal } from "@cmux/ownership"
import { checkCron, nextFire } from "../cron.ts"
import type { Env } from "../env.ts"
import type { ChiefJob, JobDelivery } from "./jobs.ts"

/**
 * Chief jobs on Upstash Workflow (prototype, issue 25573; default off: CHIEF_JOBS_ENGINE=upstash).
 *
 * The clock and the run are Upstash's: each job is a QStash schedule (`CRON_TZ=<tz> <cron>`) whose
 * destination is this Worker's workflow endpoint, and each fire is one Upstash Workflow run. The run's
 * one durable step hands the prompt to the Chief's conversation brain (`chiefJob`, the same delivery the
 * SchedulerDO path uses), keyed by the workflow run id, so a retried step queues the note once. Upstash
 * retries the step; nothing here polls or keeps a timer.
 *
 * The job's record is its schedule: the body names the Chief, conversation, owner and prompt, and the
 * schedule id starts with the Chief's id, so `ls`, `rm` and `run` reach only this Chief's jobs in this
 * conversation. Every request to the endpoint must carry a valid QStash signature: the body becomes the
 * Chief's own note, so an unsigned or forged body never reaches a brain.
 */

export const UPSTASH_WORKFLOW_PATH = "/v1/hooks/upstash/chief-job"
/** A run's delivery retries (QStash retries the step that threw). */
const RETRIES = 5

/** The job a schedule (or a run-now trigger) carries to the workflow endpoint. */
export type UpstashJob = {
  readonly v: 1
  readonly job: string
  readonly chief: string
  readonly conversation: string
  readonly owner: string
  readonly name: string
  readonly prompt: string
  readonly trigger: "cron" | "manual"
}

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

const qstash = (c: Config) => new QStash({ token: c.token, ...(c.baseUrl ? { baseUrl: c.baseUrl } : {}) })
const workflows = (c: Config) => new WorkflowClient({ token: c.token, ...(c.baseUrl ? { baseUrl: c.baseUrl } : {}) })

/** Schedule ids: the Chief's id first, so a list is filtered to one Chief before its bodies are read. */
const idPrefix = (agent: string) => `cj-${agent.replace(/[^A-Za-z0-9]/g, "")}-`
const newId = (agent: string) => `${idPrefix(agent)}${crypto.randomUUID().replace(/-/g, "").slice(0, 20)}`

const parseJob = (body: string | undefined): UpstashJob | null => {
  if (!body) return null
  try {
    const j = JSON.parse(body) as Partial<UpstashJob>
    const s = (v: unknown) => typeof v === "string" && v.length > 0
    return j.v === 1 && s(j.job) && s(j.chief) && s(j.conversation) && s(j.owner) && s(j.name) && s(j.prompt) ? (j as UpstashJob) : null
  } catch {
    return null
  }
}

/** One job as `chief-auto ls` shows it. */
type View = { id: string; name: string; enabled: boolean; triggers: Array<{ type: "cron"; expr: string; tz: string }>; next_run_at: number | null; prompt: string }

/** `CRON_TZ=America/Los_Angeles 15 19 * * *` back into its expression and zone. */
const splitCron = (cron: string): { expr: string; tz: string } => {
  const m = cron.match(/^CRON_TZ=(\S+)\s+(.+)$/)
  return m ? { expr: m[2]!, tz: m[1]! } : { expr: cron, tz: "UTC" }
}

/** This Chief's jobs in `conversation` (its jobs elsewhere and other teams' are not listed). */
const ownJobs = async (c: Config, p: Principal, conversation: string | null): Promise<Array<{ job: UpstashJob; view: View }>> => {
  const prefix = idPrefix(p.agent!)
  const out: Array<{ job: UpstashJob; view: View }> = []
  for (const s of await qstash(c).schedules.list()) {
    if (!s.scheduleId.startsWith(prefix)) continue
    const job = parseJob(s.body)
    // The body is ours (we wrote it), but a schedule only counts when it names this Chief, owner and chat.
    if (!job || job.job !== s.scheduleId || job.chief !== p.agent || job.owner !== p.user) continue
    if (conversation !== null && job.conversation !== conversation) continue
    const { expr, tz } = splitCron(s.cron)
    out.push({ job, view: { id: s.scheduleId, name: job.name, enabled: !s.isPaused, triggers: [{ type: "cron", expr, tz }], next_run_at: s.isPaused ? null : (s.nextScheduleTime ?? nextFire(expr, tz, Date.now())), prompt: job.prompt } })
  }
  return out
}

export type UpstashCreate = { readonly name: string; readonly prompt: string; readonly when: string | null; readonly tz: string }

/**
 * `chief-auto` on Upstash: auto_list, auto_rm, auto_run and auto_create. `gate` is the plan check
 * (jobs.ts), given how many jobs this Chief has over all its conversations.
 */
export const upstashAuto = async (
  c: Config,
  p: Principal,
  conversation: string,
  action: string,
  req: Record<string, unknown>,
  create: UpstashCreate | null,
  gate: (count: number) => Promise<Out | null>
): Promise<Out> => {
  try {
    if (action === "auto_list") return { status: 200, json: { jobs: (await ownJobs(c, p, conversation)).map((j) => j.view) } }
    if (action === "auto_rm" || action === "auto_run") {
      const id = typeof req.automation === "string" ? req.automation.trim().slice(0, 80) : ""
      const mine = id ? (await ownJobs(c, p, conversation)).find((j) => j.view.id === id) : undefined
      if (!mine) return { status: 404, json: { error: `no job ${id || "(no id)"} of yours in this chat (chief-auto ls)` } }
      if (action === "auto_rm") {
        await qstash(c).schedules.delete(id)
        return { status: 200, json: { removed: id } }
      }
      const run = await workflows(c).trigger({ url: c.url, body: JSON.stringify({ ...mine.job, trigger: "manual" } satisfies UpstashJob), retries: RETRIES })
      return { status: 200, json: { run: { id: run.workflowRunId } } }
    }
    if (!create) return { status: 400, json: { error: "action must be auto_create, auto_list, auto_rm or auto_run" } }
    // Upstash runs a schedule or nothing: `manual` is a job you only run with `chief-auto run`, which
    // needs no schedule, so it is refused here; a webhook job stays on the SchedulerDO path.
    if (!create.when || create.when === "manual" || create.when === "webhook") {
      return { status: 400, json: { error: "on this engine a job needs a 5-field cron as WHEN (webhook and manual jobs are not supported yet)" } }
    }
    const check = checkCron(create.when, create.tz)
    if (!check.ok) return { status: 400, json: { error: `trigger.invalid: ${check.message}`, code: "trigger.invalid" } }
    const blocked = await gate((await ownJobs(c, p, null)).length)
    if (blocked) return blocked
    const job: UpstashJob = { v: 1, job: newId(p.agent!), chief: p.agent!, conversation, owner: p.user!, name: create.name, prompt: create.prompt, trigger: "cron" }
    await qstash(c).schedules.create({
      scheduleId: job.job,
      destination: c.url,
      cron: `CRON_TZ=${create.tz} ${create.when}`,
      body: JSON.stringify(job),
      headers: { "content-type": "application/json" },
      retries: RETRIES
    })
    return { status: 200, json: { job: { id: job.job, name: job.name, enabled: true, triggers: [{ type: "cron", expr: create.when, tz: create.tz }], next_run_at: nextFire(create.when, create.tz, Date.now()), prompt: job.prompt } } }
  } catch (e) {
    // QStash down or refusing: say so to the Chief; nothing was half-made that it cannot list.
    return { status: 502, json: { error: `jobs.unavailable: ${e instanceof Error ? e.message : String(e)}`.slice(0, 500), code: "jobs.unavailable" } }
  }
}

type Brain = { chiefJob(j: ChiefJob): Promise<JobDelivery> }

/** The workflow's one durable step: hand the job to its conversation brain (idempotent per run). */
export const deliverUpstashJob = async (env: Env, job: UpstashJob, run: string): Promise<JobDelivery> => {
  const brain = env.CHIEF_BRAIN_DO.get(env.CHIEF_BRAIN_DO.idFromName(`${job.chief}/${job.conversation}`)) as unknown as Brain
  // Charged to the owner the schedule was made for; the brain refuses it unless that is the Chief's owner.
  const out = await brain.chiefJob({ run: `upstash:${run}`, automation: job.job, chief: job.chief, conversation: job.conversation, prompt: job.prompt, trigger: job.trigger, charged_user: job.owner })
  // A transient refusal (the Chief's record could not be read) throws, so Upstash retries the step.
  if (!out.ok && out.retry) throw new Error(`${out.code}: ${out.message}`)
  return out
}

/** POST /v1/hooks/upstash/chief-job: one Upstash Workflow run of a Chief job (signed by QStash). */
export const handleUpstashChiefJob = async (request: Request, env: Env): Promise<Response> => {
  const c = upstashConfig(env)
  if (!c) return Response.json({ error: "chief jobs do not run on Upstash here" }, { status: 404 })
  const handler = serve<UpstashJob>(
    async (context) => {
      const job = context.requestPayload
      const delivered = await context.run("cmux:chief", () => deliverUpstashJob(env, job, context.workflowRunId))
      if (!delivered.ok) console.warn(JSON.stringify({ msg: "chief job not delivered", job: job.job, run: context.workflowRunId, code: delivered.code }))
    },
    {
      url: c.url,
      qstashClient: qstash(c),
      receiver: new Receiver({ currentSigningKey: c.current, nextSigningKey: c.next }),
      initialPayloadParser: (body) => {
        const job = parseJob(body)
        if (!job) throw new Error("not a chief job")
        return job
      },
      disableTelemetry: true
    }
  )
  return handler.fetch(request, env as unknown as Record<string, string | undefined>)
}
