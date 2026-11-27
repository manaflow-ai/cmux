import { env } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { Schema } from "effect"
import { Body } from "@cmux/protocol"
import { describe, expect, it, vi } from "vitest"
import type { Env } from "../src/env.ts"
import type { ChiefBrainDO } from "../src/chief-brain/brain-do.ts"
import { drain, steerQueued } from "../src/chief-brain/brain-turn.ts"
import { finishJobDestinations, rememberJobDestination, resolveJobDestination } from "../src/chief-brain-cc/job-destination.ts"
import { autoCall, chiefJobWake } from "../src/chief-brain-cc/jobs.ts"
import { jobsStore } from "../src/chief-brain-cc/jobs-store.ts"

const destination = { type: "slack" as const, slackTeamId: "T123", channelId: "C123" }
const makeEnv = (failPost = false) => {
  const requests: Array<Request> = []
  const fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const request = new Request(input, init)
    requests.push(request)
    if (new URL(request.url).pathname.endsWith("/channels")) return Response.json({ channels: [{ ...destination, name: "releases" }] })
    if (failPost) throw new Error("transport failure")
    return Response.json({ ts: "123.456" })
  })
  return { requests, fetch, env: { ENVIRONMENT: "test", INTERNAL_TOKEN: "test-only-internal", PLATFORM: { fetch } } as unknown as Env }
}
const inBrain = async (f: (b: ChiefBrainDO) => Promise<void>) => {
  const ns = (env as unknown as Env).CHIEF_BRAIN_DO
  await runInDurableObject(ns.get(ns.idFromName(`job-slack-${crypto.randomUUID()}`)), async (instance) => f(instance as ChiefBrainDO))
}
const turn = (b: ChiefBrainDO, id: string, status: string, reply: string | null) => {
  b.sql.exec(`INSERT INTO cb_turn (id, conversation, trigger_message, trigger_kind, last_seq, status, model, started, reply, post) VALUES (?, 'conv_test', 'job:run', 'chief', 0, ?, 'fake', 0, ?, 'posted')`, id, status, reply)
}
const inbox = (b: ChiefBrainDO, message: string, run: string) => b.sql.exec(`INSERT INTO cb_inbox (message, conversation, seq, kind, text, turn, state) VALUES (?, 'conv_test', 0, 'chief', 'job', ?, 'done')`, message, run)

describe("Chief automation Slack destinations", () => {
  it("keeps the optional destination through the scheduler Body decoder", () => {
    const body = { type: "chief", chief: "agent_chief", conversation: "conv_01234567890123456789012345", prompt: "Release summary", destination }
    expect(Schema.decodeUnknownSync(Body)(body)).toEqual(body)
    expect(() => Schema.decodeUnknownSync(Body)({ ...body, destination: { ...destination, channelId: "http://other" } })).toThrow()
  })

  it("resolves ids and names only from the owner's installed channels with binding auth", async () => {
    const t = makeEnv()
    expect(await resolveJobDestination(t.env, "user_owner", { slack_channel: "#releases" })).toEqual(destination)
    expect(await resolveJobDestination(t.env, "user_owner", { slack_channel: "C123" })).toEqual(destination)
    expect(t.requests[0]!.headers.get("authorization")).toBe("Bearer test-only-internal")
    expect(new URL(t.requests[0]!.url).searchParams.get("ownerUserId")).toBe("user_owner")
    await expect(resolveJobDestination(t.env, "user_owner", { destination: { ...destination, slackTeamId: "TOTHER" } })).rejects.toThrow("not available")
    expect(await resolveJobDestination(t.env, "user_owner", {})).toBeUndefined()
    expect(t.requests).toHaveLength(3)
  })

  it("refuses Slack destinations outside development without calling the binding", async () => {
    const t = makeEnv()
    await expect(resolveJobDestination({ ...t.env, ENVIRONMENT: "production" }, "user_owner", { slack_channel: "C123" })).rejects.toThrow("only available in development")
    await expect(resolveJobDestination({ ...t.env, ENVIRONMENT: "staging" }, "user_owner", { destination })).rejects.toThrow("only available in development")
    expect(t.requests).toHaveLength(0)
    expect(await resolveJobDestination({ ...t.env, ENVIRONMENT: "production" }, "user_owner", {})).toBeUndefined()
  })

  it("persists and returns Upstash destinations, including a pre-destination database", async () => inBrain(async (b) => {
    b.sql.exec(`CREATE TABLE cc_jobs (id TEXT PRIMARY KEY, agent TEXT NOT NULL, owner TEXT NOT NULL, conversation TEXT NOT NULL, name TEXT NOT NULL, prompt TEXT NOT NULL, trigger TEXT NOT NULL, paused INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, last_run TEXT)`)
    const job = { id: "job_slack", agent: "agent_chief", owner: "user_owner", conversation: "conv_test", name: "Release", prompt: "Summarize", trigger: { type: "manual" as const }, destination }
    await jobsStore(b, "team_test", { op: "insert", job }, null)
    expect(await jobsStore(b, "team_test", { op: "get", id: job.id }, null)).toMatchObject(job)
    expect(await jobsStore(b, "team_test", { op: "list", agent: job.agent, conversation: job.conversation }, null)).toEqual([expect.objectContaining({ destination })])
    const chiefJob = vi.fn(async () => ({ ok: true }))
    const host = { sql: b.sql, doEnv: { CHIEF_BRAIN_DO: { idFromName: (name: string) => name, get: () => ({ chiefJob }) } } } as unknown as ChiefBrainDO
    await jobsStore(host, "team_test", { op: "fire", run: "run123", body: { v: 2, team: "team_test", job: job.id, trigger: "manual" } }, null)
    expect(chiefJob).toHaveBeenCalledWith(expect.objectContaining({ destination, run: "upstash:run123", charged_user: job.owner }))
  }))

  it("chief-auto resolves its flag and passes the destination into SchedulerDO creation", async () => {
    const t = makeEnv()
    const submitted: Array<Record<string, unknown>> = []
    const scheduler = {
      readOp: async () => ({ ok: true, value: { automations: [] } }),
      submit: async (_entity: string, _principal: unknown, frame: { params: Record<string, unknown> }) => {
        submitted.push(frame.params)
        return { frames: [{ t: "result", value: { id: "auto_test", name: "Release", enabled: true, triggers: [{ spec: { type: "manual" } }], next_run_at: null, body: frame.params.body } }] }
      }
    }
    const host = { config: () => ({ owner: "user_owner", agent: "agent_chief" }), doEnv: { ...t.env, SCHEDULER_DO: { idFromName: (name: string) => name, get: () => scheduler } } } as unknown as ChiefBrainDO
    const result = await autoCall(host, "conv_test", { action: "auto_create", name: "Release", prompt: "Release summary", when: "manual", slack_channel: "#releases" })
    expect(result.status).toBe(200)
    expect(submitted).toEqual([expect.objectContaining({ body: expect.objectContaining({ type: "chief", destination }) })])
    expect(result.json).toMatchObject({ job: { destination } })
  })

  it("records a job destination before kick and preserves event effect restrictions", async () => inBrain(async (b) => {
    const cfg = { agent: "agent_chief", owner: "user_owner" }
    const host = { sql: b.sql, lifecycle: { start: async () => {} }, config: () => cfg, admitted: async () => ({ ok: true }), kick: vi.fn() } as unknown as ChiefBrainDO
    const job = { run: "event-run", automation: "job_slack", chief: cfg.agent, charged_user: cfg.owner, conversation: "conv_test", prompt: "Release", trigger: "event", destination }
    expect(await chiefJobWake(host, job)).toEqual({ ok: true })
    expect(await chiefJobWake(host, job)).toEqual({ ok: true })
    expect(b.sql.exec(`SELECT effect_authorized FROM cb_inbox`).toArray()).toEqual([{ effect_authorized: 0 }])
    expect(b.sql.exec(`SELECT destination FROM cb_job_destinations`).toArray()).toEqual([{ destination: JSON.stringify(destination) }])
  }))

  it("posts only the completed run's final text once, and leaves ordinary or unfinished turns alone", async () => inBrain(async (b) => {
    const t = makeEnv()
    const waiting: Array<Promise<unknown>> = []
    const host = { sql: b.sql, doEnv: t.env, config: () => ({ owner: "user_owner" }), doCtx: { waitUntil: (p: Promise<unknown>) => waiting.push(p) } } as unknown as ChiefBrainDO
    turn(b, "complete", "done", "Final release summary")
    turn(b, "ordinary", "done", "Private chat")
    turn(b, "running", "running", "Partial reply")
    turn(b, "silent", "done", "NO_REPLY")
    b.sql.exec(`UPDATE cb_turn SET post = 'no_reply' WHERE id = 'silent'`)
    inbox(b, "job:silent", "silent")
    rememberJobDestination(b, "job:silent", destination)
    inbox(b, "job:run", "complete")
    inbox(b, "job:pending", "running")
    rememberJobDestination(b, "job:run", destination)
    rememberJobDestination(b, "job:pending", destination)
    finishJobDestinations(host, "silent")
    finishJobDestinations(host, "running")
    finishJobDestinations(host, "ordinary")
    expect(waiting).toHaveLength(0)
    finishJobDestinations(host, "complete")
    finishJobDestinations(host, "complete")
    await Promise.all(waiting)
    const posts = t.requests.filter((r) => r.method === "POST")
    expect(posts).toHaveLength(1)
    expect(await posts[0]!.json()).toMatchObject({ slackTeamId: "T123", channelId: "C123", text: "Final release summary" })
  }))

  it("isolates a Slack failure without retrying or changing the Chief's completed turn", async () => inBrain(async (b) => {
    const t = makeEnv(true)
    const waiting: Array<Promise<unknown>> = []
    const host = { sql: b.sql, doEnv: t.env, config: () => ({ owner: "user_owner" }), doCtx: { waitUntil: (p: Promise<unknown>) => waiting.push(p) } } as unknown as ChiefBrainDO
    turn(b, "complete", "done", "Final reply")
    inbox(b, "job:run", "complete")
    rememberJobDestination(b, "job:run", destination)
    finishJobDestinations(host, "complete")
    await expect(Promise.all(waiting)).resolves.toBeDefined()
    finishJobDestinations(host, "complete")
    expect(t.requests.filter((r) => r.method === "POST")).toHaveLength(1)
    expect(b.sql.exec(`SELECT status FROM cb_turn WHERE id = 'complete'`).toArray()).toEqual([{ status: "done" }])
  }))

  it.each(["job-first", "chat-first"])("does not batch a destination job with unrelated queued chat (%s)", async (order) => inBrain(async (b) => {
    const messages = order === "job-first" ? ["job:run", "chat:private"] : ["chat:private", "job:run"]
    for (const message of messages) b.sql.exec(`INSERT INTO cb_inbox (message, conversation, seq, kind, text, woke, effect_authorized) VALUES (?, 'conv_test', 0, 'chief', ?, 1, 1)`, message, message)
    rememberJobDestination(b, "job:run", destination)
    const batches: Array<Array<string>> = []
    const host = {
      sql: b.sql, childOf: () => null, config: () => ({ agent: "agent_chief", owner: "user_owner" }),
      admitted: async () => ({ ok: true }), doEnv: { ENVIRONMENT: "test" },
      compactor: { off: () => true }, memory: { first: () => 0, len: () => 0 },
      openTurn: (_conversation: string, rows: Array<{ message: string; n: number }>) => {
        batches.push(rows.map((r) => r.message))
        for (const row of rows) b.sql.exec(`UPDATE cb_inbox SET state = 'done' WHERE n = ?`, row.n)
      }
    } as unknown as ChiefBrainDO
    await drain(host)
    expect(batches).toEqual(messages.map((m) => [m]))
  }))

  it("never steers private chat into a destination turn or a destination job into an ordinary turn", async () => inBrain(async (b) => {
    turn(b, "destination-turn", "running", null)
    turn(b, "ordinary-turn", "running", null)
    b.sql.exec(`UPDATE cb_turn SET trigger_message = 'chat:trigger' WHERE id = 'ordinary-turn'`)
    rememberJobDestination(b, "job:run", destination)
    b.sql.exec(`INSERT INTO cb_inbox (message, conversation, seq, kind, text, woke, effect_authorized) VALUES ('chat:private', 'conv_test', 1, 'chief', 'private owner message', 1, 1)`)
    b.sql.exec(`INSERT INTO cb_inbox (message, conversation, seq, kind, text, woke, effect_authorized) VALUES ('job:run', 'conv_test', 2, 'chief', 'public destination job', 1, 1)`)
    const steer = vi.fn(async () => {})
    const append = vi.fn()
    const host = {
      sql: b.sql, turnId: "destination-turn", turnLive: true, doCtx: b.doCtx,
      memory: { append }, compactor: { pump: () => {} }, steered: [], steerOps: () => [],
      harness: { session: () => ({ steer }) }
    } as unknown as ChiefBrainDO
    await steerQueued(host, "conv_test")
    expect(steer).not.toHaveBeenCalled()
    expect(append).not.toHaveBeenCalled()
    host.turnId = "ordinary-turn"
    await steerQueued(host, "conv_test")
    expect(steer).toHaveBeenCalledTimes(1)
    expect(steer.mock.calls[0]).toEqual([[{ type: "text", text: "private owner message" }], expect.any(Object)])
    expect(b.sql.exec(`SELECT message, state, turn FROM cb_inbox ORDER BY n`).toArray()).toEqual([
      { message: "chat:private", state: "running", turn: "ordinary-turn" },
      { message: "job:run", state: "queued", turn: null }
    ])
  }))
})
