import type { Automation, Body } from "@cmux/protocol"
import type { OwnerFrame, Principal } from "@cmux/ownership"
import type { ChiefBrainDO } from "../chief-brain/brain-do.ts"
import { personalTeamIdFor } from "../domains/user.ts"
import type { Env } from "../env.ts"
import { planGrantedNote, planLink, PRICING_URL, type PlanNotice } from "../plan-checkout.ts"

/**
 * A Chief's scheduled and triggered jobs (plans/cmux-next/chief-automations-DESIGN.md). Lawrence,
 * 2026-10-26: a person asks Chief for a recurring or triggered job, Chief creates it, it runs in the
 * cloud with the laptop asleep, and the result comes back to the chat.
 *
 * A job is an automation of the owner's personal team (SchedulerDO: cron, webhook and manual triggers,
 * run history, limits) whose body is `{type: "chief", chief, conversation, prompt}`. Each run hands the
 * prompt to the Chief's conversation brain (`chiefJobWake`): a "[job]" note that starts a turn, as the
 * Chief's own timer does (wake.ts). The Chief does the work in that turn and posts the result there.
 *
 * The Chief manages its jobs with `chief-auto` in its turn machine (POST 127.0.0.1:4018/vm
 * {action: auto_create|auto_list|auto_rm|auto_run}); it reaches only jobs of its own conversation.
 *
 * Upsell: without a paid plan an owner has FREE_CHIEF_JOBS jobs. The next create answers
 * `automation.plan.required` with the plan that lifts it and a Stripe Checkout link (plan-checkout.ts,
 * test mode), which the Chief sends in one line. A plan read that fails lets the job through. Once the
 * person pays, `chiefPlanWake` queues one "[billing]" note here: the Chief confirms and redoes the add.
 */
export const FREE_CHIEF_JOBS = 1
export const UPSELL_PLAN = "pro"
const PROMPT_MAX = 8000
const INPUT_MAX = 4000
type Out = { status: number; json: unknown }

// ------------------------------------------------------------------ delivery (a run of a chief body)

export interface ChiefJob {
  readonly run: string
  readonly automation: string
  readonly chief: string
  readonly conversation: string
  readonly prompt: string
  readonly trigger: string
  readonly input?: unknown
  readonly charged_user: string | null
}
export type JobDelivery = { readonly ok: true } | { readonly ok: false; readonly code: string; readonly message: string; readonly retry?: true }

/** The run's note in the Chief's conversation (its own words, never the person's). */
export const jobNote = (j: Pick<ChiefJob, "automation" | "run" | "prompt" | "trigger" | "input">): string => {
  const input = j.input === undefined ? "" : `\nTrigger input: ${JSON.stringify(j.input).slice(0, INPUT_MAX)}`
  return `[job ${j.automation}] ${j.prompt}${input}\n(Your own ${j.trigger} job ${j.run}, made with chief-auto when the person asked for it; it is not the person's word now. Do the job and post the result in this chat.)`
}

/** ChiefBrainDO side: queue the job's note in this conversation brain and start a turn. Idempotent per run. */
export const chiefJobWake = async (b: ChiefBrainDO, j: ChiefJob): Promise<JobDelivery> => {
  await b.lifecycle.start()
  const cfg = b.config()
  if (!cfg.agent || !cfg.owner || cfg.agent !== j.chief) return { ok: false, code: "chief.not_found", message: "this Chief has never answered in that conversation" }
  // Only the Chief's owner may have a job of it run: a teammate who edits the automation becomes the
  // member it is charged to, and delivery then stops (fail closed).
  if (!j.charged_user || j.charged_user !== cfg.owner) return { ok: false, code: "chief.forbidden", message: "the job is charged to a member who does not own this Chief" }
  const a = await b.admitted(cfg.agent, cfg.owner, false)
  if (!a.ok && a.reason === "owner.unreachable") return { ok: false, code: "owner.unreachable", message: "the Chief's record could not be read", retry: true }
  // Out of credits is not refused here: the turn refuses and posts the one top-up notice (brain-turn.ts).
  if (!a.ok && a.reason !== "credits_exhausted") return { ok: false, code: `chief.${a.reason}`, message: a.reason === "chief_placed" ? "a paired computer runs this Chief; scheduled jobs need the Cloud Chief" : `the Chief cannot take a turn (${a.reason})` }
  const seq = Number(b.sql.exec<{ seq: number }>(`SELECT seq FROM cb_cursor WHERE conversation = ?`, j.conversation).toArray()[0]?.seq ?? 0)
  b.sql.exec(
    `INSERT INTO cb_inbox (message, conversation, seq, kind, thread_root, text, effect_authorized, woke) VALUES (?, ?, ?, 'chief', NULL, ?, 1, 1) ON CONFLICT (message) DO NOTHING`,
    `job:${j.run}`,
    j.conversation,
    seq,
    jobNote(j)
  )
  b.kick()
  return { ok: true }
}

/**
 * ChiefBrainDO side: a plan bought through this Chief's checkout link is on (plan-checkout.ts
 * grantPlanSession). Queues one note per checkout session and starts a turn, only for this Chief and
 * only when the plan is on its owner's own team.
 */
export const chiefPlanWake = async (b: ChiefBrainDO, n: PlanNotice): Promise<JobDelivery> => {
  await b.lifecycle.start()
  const cfg = b.config()
  if (!cfg.agent || !cfg.owner || cfg.agent !== n.chief) return { ok: false, code: "chief.not_found", message: "this Chief has never answered in that conversation" }
  if (personalTeamIdFor(cfg.owner) !== n.team) return { ok: false, code: "chief.forbidden", message: "the plan is not on this Chief's owner's team" }
  const adm = await b.admitted(cfg.agent, cfg.owner, false)
  if (!adm.ok && adm.reason === "owner.unreachable") return { ok: false, code: "owner.unreachable", message: "the Chief's record could not be read", retry: true }
  if (!adm.ok && adm.reason !== "credits_exhausted") return { ok: false, code: `chief.${adm.reason}`, message: `the Chief cannot take a turn (${adm.reason})` }
  const seq = Number(b.sql.exec<{ seq: number }>(`SELECT seq FROM cb_cursor WHERE conversation = ?`, n.conversation).toArray()[0]?.seq ?? 0)
  b.sql.exec(
    `INSERT INTO cb_inbox (message, conversation, seq, kind, thread_root, text, effect_authorized, woke) VALUES (?, ?, ?, 'chief', NULL, ?, 1, 1) ON CONFLICT (message) DO NOTHING`,
    `plan:${n.session}`,
    n.conversation,
    seq,
    planGrantedNote(n.plan)
  )
  b.kick()
  return { ok: true }
}

// ------------------------------------------------------------------ chief-auto (the Chief's own client)

type SchedulerStub = {
  submit(entity: string, principal: Principal, frame: { t: "op"; op: string; params: unknown; idempotency_key: string; origin?: string }): Promise<{ frames: ReadonlyArray<OwnerFrame> }>
  readOp(entity: string, principal: Principal, op: string, params: unknown): Promise<{ ok: true; value: unknown } | { ok: false; code: string; message: string }>
}

/** The Chief acting for its owner on the owner's personal team's scheduler (classes it needs for its jobs). */
export const chiefJobPrincipal = (agent: string, owner: string): Principal => ({
  kind: "agent",
  identity: `chief:${agent}`,
  agent,
  user: owner,
  team: personalTeamIdFor(owner),
  grant_classes: ["read", "execute", "mutate-shared", "destructive"]
})

const scheduler = (env: Env, team: string) => env.SCHEDULER_DO.get(env.SCHEDULER_DO.idFromName(team)) as unknown as SchedulerStub

const mutate = async (env: Env, p: Principal, op: string, params: unknown, key: string): Promise<{ ok: true; value: any } | { ok: false; code: string; message: string; details?: unknown }> => {
  const res = await scheduler(env, p.team!).submit(p.team!, p, { t: "op", op, params, idempotency_key: key, origin: "script" })
  const reply = res.frames.find((f) => f.t === "result" || f.t === "reject") as { t: string; value?: unknown; code?: string; message?: string; details?: unknown } | undefined
  if (!reply) return { ok: false, code: "owner.unreachable", message: "no reply from the scheduler" }
  return reply.t === "reject" ? { ok: false, code: reply.code ?? "rejected", message: reply.message ?? "", details: reply.details } : { ok: true, value: reply.value }
}

/** This Chief's jobs in `conversation` (other jobs of the team are not its own). */
const ownJobs = async (env: Env, p: Principal, conversation: string | null): Promise<Array<Automation>> => {
  const out: Array<Automation> = []
  let cursor: string | undefined
  for (let i = 0; i < 20; i++) {
    const r = await scheduler(env, p.team!).readOp(p.team!, p, "automation.list", { limit: 100, ...(cursor ? { cursor } : {}) })
    if (!r.ok) throw new Error(`${r.code}: ${r.message}`)
    const v = r.value as { automations: Array<Automation>; next_cursor?: string | null }
    out.push(...v.automations.filter((a) => a.body.type === "chief" && a.body.chief === p.agent && (conversation === null || a.body.conversation === conversation)))
    if (!v.next_cursor) break
    cursor = v.next_cursor
  }
  return out
}

/** Does the owner have a paid plan? `unknown` when it cannot be read (the job goes through). */
export const ownerPaid = async (env: Env, owner: string): Promise<"paid" | "free" | "unknown"> => {
  try {
    const user = env.USER_DO.get(env.USER_DO.idFromName(owner)) as unknown as { stackUserOf(entity: string): Promise<string | null> }
    const stackUser = await user.stackUserOf(owner)
    if (!stackUser) return "unknown"
    const team = personalTeamIdFor(owner)
    const plan = (await (env.TEAM_DO.get(env.TEAM_DO.idFromName(team)) as unknown as { inferencePlan(e: string, u: string, s?: string): Promise<{ ok: boolean; paid?: boolean }> }).inferencePlan(team, owner, stackUser)) as { ok: boolean; paid?: boolean }
    return plan.ok ? (plan.paid ? "paid" : "free") : "unknown"
  } catch {
    return "unknown"
  }
}

const view = (a: Automation) => ({
  id: a.id,
  name: a.name,
  enabled: a.enabled,
  triggers: a.triggers.map((t) => t.spec),
  next_run_at: a.next_run_at,
  prompt: a.body.type === "chief" ? a.body.prompt : undefined
})

const str = (v: unknown, max: number) => (typeof v === "string" && v.trim() ? v.trim().slice(0, max) : null)

/** One `chief-auto` call from the running turn of `conversation`. */
export const autoCall = async (b: ChiefBrainDO, conversation: string, raw: unknown): Promise<Out> => {
  const cfg = b.config()
  if (!cfg.agent || !cfg.owner || !conversation) return { status: 409, json: { error: "no Chief is bound to this turn" } }
  const env = b.doEnv
  const p = chiefJobPrincipal(cfg.agent, cfg.owner)
  const req = (raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {}) as Record<string, unknown>
  const fail = (status: number, r: { code: string; message: string }) => ({ status, json: { error: `${r.code}: ${r.message}`, code: r.code } })
  if (req.action === "auto_list") return { status: 200, json: { jobs: (await ownJobs(env, p, conversation)).map(view) } }
  if (req.action === "auto_rm" || req.action === "auto_run") {
    const id = str(req.automation, 40)
    const job = id ? (await ownJobs(env, p, conversation)).find((a) => a.id === id) : undefined
    if (!job) return { status: 404, json: { error: `no job ${id ?? "(no id)"} of yours in this chat (chief-auto ls)` } }
    const r = await mutate(env, p, req.action === "auto_rm" ? "automation.delete" : "automation.run", { automation: job.id }, `chief-auto:${req.action}:${job.id}:${crypto.randomUUID()}`)
    return r.ok ? { status: 200, json: req.action === "auto_rm" ? { removed: job.id } : { run: r.value } } : fail(400, r)
  }
  if (req.action !== "auto_create") return { status: 400, json: { error: "action must be auto_create, auto_list, auto_rm or auto_run" } }
  const name = str(req.name, 80)
  const prompt = str(req.prompt, PROMPT_MAX)
  if (!name || !prompt) return { status: 400, json: { error: "a job needs a name and a prompt (what to do on each run)" } }
  const when = str(req.when, 120)
  const tz = str(req.tz, 64) ?? "UTC"
  const triggers: Array<Record<string, unknown>> = [{ type: "manual" }]
  if (when === "webhook") triggers.unshift({ type: "webhook" })
  else if (when && when !== "manual") triggers.unshift({ type: "cron", expr: when, tz })
  // The upsell gate: on the free plan a Chief has FREE_CHIEF_JOBS jobs (over all its conversations).
  const mine = await ownJobs(env, p, null)
  if (mine.length >= FREE_CHIEF_JOBS && (await ownerPaid(env, cfg.owner)) === "free") {
    const checkout = env.CLOUD_API_ORIGIN ? await planLink(env, env.CLOUD_API_ORIGIN, p.team!, UPSELL_PLAN, { chief: cfg.agent, conversation }) : null
    return {
      status: 402,
      json: {
        error: `automation.plan.required: the free plan has ${FREE_CHIEF_JOBS} scheduled job; Pro ($50/month) has more`,
        code: "automation.plan.required",
        plan: UPSELL_PLAN,
        checkout: checkout ?? PRICING_URL,
        test_mode: checkout !== null
      }
    }
  }
  const body: Body = { type: "chief", chief: cfg.agent, conversation, prompt }
  const r = await mutate(env, p, "automation.create", { name, description: `Chief job: ${prompt.slice(0, 200)}`, triggers, body }, `chief-auto:create:${cfg.agent}:${conversation}:${crypto.randomUUID()}`)
  if (!r.ok) return fail(r.code === "trigger.invalid" || r.code === "validation.invalid" ? 400 : r.code === "automation.limit" ? 413 : 502, r)
  const job = r.value as Automation
  let webhook: unknown
  if (when === "webhook") {
    const w = await scheduler(env, p.team!).readOp(p.team!, p, "automation.webhook.get", { automation: job.id }).catch(() => null)
    webhook = w && w.ok ? w.value : undefined
  }
  return { status: 200, json: { job: view(job), ...(webhook ? { webhook } : {}) } }
}

/** `chief-auto`: the Chief's client (curl to chief-turn-runner on 127.0.0.1:4018). */
export const AUTO_CLIENT = `#!/bin/sh
# chief-auto: your scheduled and triggered jobs (apps/api/src/chief-brain-cc/jobs.ts). Each run puts
# "[job ID] PROMPT" in this chat as your own note and starts a turn in the cloud, with the person's
# computers asleep too: do the job then and post the result here.
#   chief-auto add NAME WHEN "PROMPT"   WHEN: a 5-field cron like "0 9 * * 1-5", webhook, or manual
#                                        (--tz Area/City before NAME for cron; default UTC)
#   chief-auto ls
#   chief-auto run ID                    run it now
#   chief-auto rm ID
# A 402 answer with code automation.plan.required carries "checkout": send the person that link in
# one line (what the plan adds, its price); nothing is charged until they pay on that page. When they
# pay, a "[billing]" note starts a turn here: say the plan is on and run the add again.
set -eu
call() {
  out=$(curl -sS -m 60 -w '\\n%{http_code}' -H 'content-type: application/json' --data-binary @- http://127.0.0.1:4018/vm) || { echo "chief-auto: no turn is running on this machine (127.0.0.1:4018 does not answer)" >&2; exit 1; }
  code=$(printf '%s' "$out" | tail -n 1)
  body=$(printf '%s' "$out" | sed '$d')
  printf '%s\\n' "$body"
  [ "$code" = 200 ] || exit 1
}
usage() { echo 'usage: chief-auto add [--tz TZ] NAME WHEN "PROMPT" | ls | run ID | rm ID' >&2; exit 2; }
case "\${1:-ls}" in
  ls) printf '{"action":"auto_list"}' | call ;;
  run|rm)
    [ $# -eq 2 ] || usage
    node -e 'process.stdout.write(JSON.stringify({action:process.argv[1],automation:process.argv[2]}))' "auto_$1" "$2" | call ;;
  add)
    shift; tz=UTC
    if [ "\${1:-}" = --tz ]; then [ $# -ge 2 ] || usage; tz="$2"; shift 2; fi
    [ $# -eq 3 ] || usage
    node -e 'process.stdout.write(JSON.stringify({action:"auto_create",name:process.argv[1],when:process.argv[2],prompt:process.argv[3],tz:process.argv[4]}))' "$1" "$2" "$3" "$tz" | call ;;
  *) usage ;;
esac
`
