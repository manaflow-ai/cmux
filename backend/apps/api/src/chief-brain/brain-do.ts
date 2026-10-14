import { DurableObject } from "cloudflare:workers"
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context"
import { Type, type AssistantMessage } from "@earendil-works/pi-ai"
import { createRegistry, GenerationTask, Harness, hook, section, ToolTask, type ToolRegistration } from "@earendil-works/pi-durable"
import { PiHarness } from "agents/harness/pi"
import { Lifecycle, type LifecycleJobContext, type LifecycleJobOutcome } from "agents/lifecycle"
import type { Env } from "../env.ts"
import { ackWake, chiefPrincipal, postReply, readConversation, runChanged, typing } from "./brain-io.ts"
import { clip, clipInput, lastTalk, readRun, readRuns, readSteps, type Run, type Step, type StepPatch, upsertStep } from "./brain-runs.ts"
import { type BrainConfig, PROFILE_LIMITS, readConfig, SCHEMA, writeConfig } from "./brain-store.ts"
import { Compactor, type CallRecord } from "./compactor.ts"
import { capText, cutAtMarks, type Kind, Memory, RETRY_MS } from "./memory.ts"
import { brainModels, FAKE, validModelName } from "./models.ts"
import { formatMessage, replyTarget, systemFirst, textParts } from "./brain-text.ts"
import { AGENT, DATE_DESCRIPTION, NO_REPLY, systemPrompt, ZOOM_DESCRIPTION } from "./prompts.ts"

/**
 * ChiefBrainDO, one per chief (name = the chief's agent id): a Chief that answers in Cloud
 * conversations by itself, on pi-durable (the Cloudflare agents SDK PiHarness), with the OptChat
 * memory (optchat-wasm over this object's SQLite) as its whole context. Ported from optchat-lab
 * impl/pi-durable (ChatDO): same memory, compactor and one-fresh-pi-session-per-turn loop.
 *
 * Input: MuxDO forwards each committed `mux.wake` (a DM, a mention, a reply, or every person's
 * message in a channel with wake_policy "all"). The brain pulls the new messages of that
 * conversation as the chief, queues them, and runs one turn per conversation batch.
 * Output: one `message.send` per turn as the chief (thread reply in a channel), carrying a `work`
 * part that names the run; the run's steps (talk, tool, echo) are read with `run()`. Typing frames
 * show while a turn runs. `NO_REPLY` posts nothing. Then `mux.ack` moves the wake cursor.
 * Off unless the owner enabled it (`configure`), and the Worker forwards wakes only where
 * CHIEF_BRAIN_ENABLED is "1".
 */
const ZoomArgs = Type.Object({
  id: Type.Integer({ description: "First message id of the line (the number before +)." }),
  n: Type.Integer({ description: "How many messages the line covers (the number after +); a power of 2." })
})
const DateArgs = Type.Object({ id: Type.Integer({ description: "A message id." }) })
/** Post retries after the loop guard's agent_rate (another agent spoke under 2 s ago). */
const POST_RETRY_MS = 2_500
const MAX_POST_TRIES = 6
const HOST = "cloud-chief"

export type ConfigPatch = Partial<Pick<BrainConfig, "enabled" | "model" | "compactor_model" | "role" | "personality" | "instructions">>

export class ChiefBrainDO extends DurableObject<Env> {
  private readonly sql = this.ctx.storage.sql
  readonly models = brainModels(this.env.AI, this.ctx.id.toString())
  readonly registry = createRegistry()
  memory: Memory
  compactor: Compactor
  private turnId: string | undefined
  private turnConversation: string | undefined
  private draining: Promise<void> | undefined

  readonly harness = new PiHarness({
    harness: ({ storage, context }) => {
      const zoom: ToolRegistration<typeof ZoomArgs> = {
        name: "zoom",
        description: ZOOM_DESCRIPTION,
        parameters: ZoomArgs,
        replay: "safe",
        execute: async ({ id, n }) => ({ content: [{ type: "text", text: this.memory.zoom(id, n) }] })
      }
      const date: ToolRegistration<typeof DateArgs> = {
        name: "date",
        description: DATE_DESCRIPTION,
        parameters: DateArgs,
        replay: "safe",
        execute: async ({ id }) => ({ content: [{ type: "text", text: this.memory.date(id, "UTC") }] })
      }
      this.registry.install({
        name: "chief",
        sections: [section("chief", () => systemPrompt(this.config()), { tag: false })],
        tools: [zoom, date],
        hooks: [
          hook(GenerationTask, {
            beforeRequest: async ({ messages }) => {
              if (this.turnConversation && this.cfgAgent()) void typing(this.env, this.turnConversation, this.cfgAgent()!, true)
              return systemFirst(messages)
            },
            afterResponse: (message, api) => this.onResponse(message, String(api.taskId))
          }),
          hook(ToolTask, {
            afterTool: (call, result) => {
              const text = textParts(result.content as ReadonlyArray<{ type: string; text?: string }>)
              const capped = capText(text)
              const out = clip(text)
              this.logOnce(`echo:${call.id}`, "echo", capped, { id: `tool:${call.id}`, kind: "tool", status: "done", ...(out.truncated ? { truncated: true } : {}), tool: { name: call.name, output: out.text, ended_at: Date.now() } })
              return capped === text ? undefined : { ...result, content: [{ type: "text", text: capped }] }
            }
          })
        ]
      })
      return Harness.open(
        storage,
        {
          models: this.models.models,
          registry: this.registry,
          settings: { retry: { enabled: true, maxRetries: 3, baseDelayMs: 2000 }, compaction: { enabled: false, backgroundTokens: 0 } },
          onReport: (error) => console.warn(JSON.stringify({ msg: "chief_brain.pi_report", error: String(error).slice(0, 300) }))
        },
        context
      )
    },
    defaults: { model: this.models.model(FAKE) }
  })

  readonly lifecycle = Lifecycle.install(this).use(this.harness)

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    for (const q of SCHEMA) this.sql.exec(q)
    this.memory = new Memory(this.sql, Number(env.CHIEF_BRAIN_VIEW_BUDGET ?? "0") || 0)
    this.compactor = new Compactor({
      memory: this.memory,
      deps: () => {
        const name = this.config().compactor_model
        return { memory: this.memory, models: this.models.models, model: this.models.model(name), thinking: name === FAKE ? "off" : "medium", prompt: "cmux", agent: AGENT, record: (_c: CallRecord) => undefined }
      },
      onBuilt: () => undefined,
      onFirstFailure: (l, i, error) => console.warn(JSON.stringify({ msg: "chief_brain.compactor_failed", node: `${l}:${i}`, error: error.slice(0, 300) })),
      onRetryWait: (at) => this.schedule("compact", "compact", at)
    })
  }

  async onStart(): Promise<void> {
    this.compactor.pump()
    this.kick()
    for (const r of this.sql.exec<{ id: string }>(`SELECT id FROM cb_turn WHERE post = 'pending'`).toArray()) void this.post(r.id)
    if (!this.memory.settled()) await this.schedule("compact", "compact", Date.now() + RETRY_MS)
  }

  // ------------------------------------------------------------------ config and reads

  private defaults() {
    return { model: this.env.CHIEF_BRAIN_MODEL || FAKE, compactor_model: this.env.CHIEF_BRAIN_COMPACTOR_MODEL || this.env.CHIEF_BRAIN_MODEL || FAKE }
  }
  config(): BrainConfig {
    return readConfig(this.sql, this.defaults())
  }
  private cfgAgent = () => this.config().agent

  /** The owner's settings (the Worker checked the caller owns `agent`). Binds the object to its chief on first use. */
  async configure(agent: string, owner: string, patch: ConfigPatch): Promise<{ ok: true; config: BrainConfig } | { ok: false; code: string; message: string }> {
    await this.lifecycle.start()
    const cur = this.config()
    if ((cur.agent !== null && cur.agent !== agent) || (cur.owner !== null && cur.owner !== owner)) return { ok: false, code: "auth.forbidden", message: "this brain belongs to another chief" }
    const bad = (m: string) => ({ ok: false as const, code: "validation.invalid", message: m })
    if (patch.enabled !== undefined && typeof patch.enabled !== "boolean") return bad("enabled must be a boolean")
    for (const k of ["model", "compactor_model"] as const) if (patch[k] !== undefined && !validModelName(patch[k])) return bad(`${k} must be "fake" or a Workers AI id @cf/<vendor>/<model>`)
    for (const k of ["role", "personality", "instructions"] as const) {
      const v = patch[k]
      if (v !== undefined && (typeof v !== "string" || [...v].length > PROFILE_LIMITS[k] || /[\u0000-\u0008\u000b\u000c\u000e-\u001f]/.test(v))) return bad(`${k} must be text of at most ${PROFILE_LIMITS[k]} characters`)
    }
    writeConfig(this.sql, {
      agent,
      owner,
      ...(patch.enabled === undefined ? {} : { enabled: patch.enabled ? "1" : "0" }),
      model: patch.model,
      compactor_model: patch.compactor_model,
      role: patch.role,
      personality: patch.personality,
      instructions: patch.instructions
    })
    return { ok: true, config: this.config() }
  }

  async status(): Promise<{ config: BrainConfig; messages: number; settled: boolean; queued: number; busy: boolean }> {
    await this.lifecycle.start()
    const queued = Number(this.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM cb_inbox WHERE state = 'queued'`).one().n)
    return { config: this.config(), messages: this.memory.len(), settled: this.memory.settled(), queued, busy: this.turnId !== undefined }
  }

  /** A run (turn) with its steps after `afterSeq`, or null. The Worker checks the caller is a member of `run.conversation`. */
  async run(id: string, afterSeq = 0, limit = 500): Promise<{ run: Run; steps: Array<Step>; has_more: boolean } | null> {
    await this.lifecycle.start()
    const agent = this.config().agent
    const run = agent ? readRun(this.sql, agent, id) : null
    if (!run) return null
    const steps = readSteps(this.sql, id, afterSeq, limit + 1)
    return { run, steps: steps.slice(0, limit), has_more: steps.length > limit }
  }

  /** This chief's runs in one conversation, newest first (the Worker checked membership first). */
  async runs(conversation: string, before: number | undefined, limit: number): Promise<{ runs: Array<Run>; has_more: boolean }> {
    await this.lifecycle.start()
    const agent = this.config().agent
    return agent ? readRuns(this.sql, agent, conversation, before, limit) : { runs: [], has_more: false }
  }

  // ------------------------------------------------------------------ wakes

  /** MuxDO forwards a committed wake. Pulls the conversation's new messages as the chief and starts a turn. */
  async wake(w: { agent: string; owner: string; conversation: string; seq: number; reason: string }): Promise<{ queued: number } | { skipped: string }> {
    await this.lifecycle.start()
    const cfg = this.config()
    if (!cfg.enabled) return { skipped: "disabled" }
    if (cfg.agent !== w.agent || cfg.owner !== w.owner) return { skipped: "other_chief" }
    const view = await readConversation(this.env, w.conversation, chiefPrincipal(w.agent, w.owner))
    if ("refused" in view) return { skipped: view.refused }
    const me = view.head.participants.find((p) => p.id === w.agent)
    if (me?.display_name && me.display_name !== cfg.display_name) writeConfig(this.sql, { display_name: me.display_name })
    // A conversation the brain never read starts at the wake: older history is not answered.
    const cursor = this.sql.exec<{ seq: number }>(`SELECT seq FROM cb_cursor WHERE conversation = ?`, w.conversation).toArray()[0]?.seq ?? w.seq - 1
    let queued = 0
    let top = cursor
    for (const m of view.messages) {
      if (m.seq <= cursor) continue
      top = Math.max(top, m.seq)
      if (m.author === w.agent || m.retracted_at !== undefined) continue
      const text = formatMessage(view.head, m)
      if (!text) continue
      const fresh = this.sql
        .exec(`INSERT INTO cb_inbox (message, conversation, seq, kind, thread_root, text) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT (message) DO NOTHING RETURNING n`, m.id, w.conversation, m.seq, view.head.kind ?? "group", m.thread_root ?? null, text)
        .toArray()
      queued += fresh.length
    }
    this.sql.exec(`INSERT INTO cb_cursor (conversation, seq) VALUES (?, ?) ON CONFLICT (conversation) DO UPDATE SET seq = MAX(seq, excluded.seq)`, w.conversation, top)
    if (queued === 0 && top > cursor) await ackWake(this.env, w.agent, chiefPrincipal(w.agent, w.owner), w.conversation, top).catch(() => undefined)
    this.kick()
    return { queued }
  }

  // ------------------------------------------------------------------ logging

  /** Appends to the memory log once per key; the running turn's step changes go to every member's socket. */
  private logOnce(key: string, kind: Kind, text: string, step?: StepPatch): void {
    let changed: Step | undefined
    let logged = false
    const turn = this.turnId
    this.ctx.storage.transactionSync(() => {
      if (this.sql.exec(`SELECT 1 FROM oc_logged WHERE key = ?`, key).toArray().length > 0) return
      this.sql.exec(`INSERT INTO oc_logged (key) VALUES (?)`, key)
      this.memory.append(kind, text)
      if (turn && step) changed = upsertStep(this.sql, turn, step, Date.now())
      logged = true
    })
    if (logged) this.compactor.pump()
    if (turn && changed) this.announce(turn, [changed])
  }

  /** `conversation-run-changed` for the run's conversation (the run summary and the steps that changed). */
  private announce(turn: string, steps: ReadonlyArray<Step>): void {
    const agent = this.config().agent
    const run = agent ? readRun(this.sql, agent, turn) : null
    if (agent && run) this.ctx.waitUntil(runChanged(this.env, run.conversation, agent, run, steps))
  }

  private onResponse(message: AssistantMessage, taskId: string): void {
    if (message.stopReason === "error" || message.stopReason === "aborted") return
    const text = textParts(message.content as ReadonlyArray<{ type: string; text?: string }>).trim()
    if (text) this.logOnce(`talk:${taskId}`, "talk", text, { id: `talk:${taskId}`, kind: "talk", ...clip(text) })
    for (const part of message.content) {
      if (part.type !== "toolCall") continue
      const tool = { name: part.name, input: clipInput(part.arguments), started_at: Date.now() }
      this.logOnce(`tool:${part.id}`, "tool", `${part.name} ${JSON.stringify(part.arguments)}`, { id: `tool:${part.id}`, kind: "tool", status: "running", tool })
    }
  }

  // ------------------------------------------------------------------ turns

  private kick(): void {
    if (this.draining) return
    this.draining = this.drain()
      .catch((e: unknown) => console.error(JSON.stringify({ msg: "chief_brain.drain_failed", error: String(e).slice(0, 300) })))
      .finally(() => (this.draining = undefined))
    this.ctx.waitUntil(this.draining)
  }

  private async drain(): Promise<void> {
    for (;;) {
      const running = this.sql.exec<{ turn: string }>(`SELECT turn FROM cb_inbox WHERE state = 'running' ORDER BY n LIMIT 1`).toArray()[0]
      if (running) {
        await this.runTurn(running.turn)
        continue
      }
      const first = this.sql.exec<{ conversation: string }>(`SELECT conversation FROM cb_inbox WHERE state = 'queued' ORDER BY n LIMIT 1`).toArray()[0]
      if (!first) return
      await this.compactor.settle()
      const rows = this.sql
        .exec<{ n: number; message: string; seq: number; kind: string; thread_root: string | null; text: string }>(`SELECT n, message, seq, kind, thread_root, text FROM cb_inbox WHERE state = 'queued' AND conversation = ? ORDER BY n`, first.conversation)
        .toArray()
      if (rows.length > 0) this.openTurn(first.conversation, rows)
    }
  }

  /** Renders the view BEFORE logging the new messages, then logs them with the turn row in one transaction (a restart resubmits the same bytes). */
  private openTurn(conversation: string, rows: ReadonlyArray<{ n: number; message: string; seq: number; kind: string; thread_root: string | null; text: string }>): void {
    const id = `run_${rows[0]!.n}`
    const view = this.memory.render()
    const input = JSON.stringify([...cutAtMarks(view.text, view.marks), rows.map((r) => r.text).join("\n\n")])
    const last = rows[rows.length - 1]!
    this.ctx.storage.transactionSync(() => {
      for (const r of rows) {
        this.sql.exec(`INSERT INTO oc_logged (key) VALUES (?) ON CONFLICT DO NOTHING`, `user:${r.message}`)
        this.memory.append("user", r.text)
        this.sql.exec(`UPDATE cb_inbox SET state = 'running', turn = ? WHERE n = ?`, id, r.n)
      }
      this.sql.exec(
        `INSERT INTO cb_turn (id, conversation, trigger_message, trigger_kind, trigger_thread_root, last_seq, status, model, started, input) VALUES (?, ?, ?, ?, ?, ?, 'running', ?, ?, ?)`,
        id, conversation, last.message, last.kind, last.thread_root, Math.max(...rows.map((r) => r.seq)), this.config().model, Date.now(), input
      )
    })
    this.compactor.pump()
    this.announce(id, [])
  }

  private async runTurn(id: string): Promise<void> {
    const row = this.sql.exec<{ submitted: number; input: string | null; model: string; conversation: string }>(`SELECT submitted, input, model, conversation FROM cb_turn WHERE id = ?`, id).toArray()[0]
    if (!row) throw new Error(`run ${id} has no row`)
    const agent = this.config().agent
    this.turnId = id
    this.turnConversation = row.conversation
    if (agent) void typing(this.env, row.conversation, agent, true)
    let ok = false
    let reason: string | null = null
    try {
      if (!row.submitted) {
        const blocks = JSON.parse(row.input ?? "[]") as Array<string>
        const model = this.models.model(row.model)
        const root = await (await this.harness.pi()).root(BACKGROUND_CONTEXT)
        await root.configure({ model: { provider: model.provider, modelId: model.id }, thinkingLevel: this.models.thinking(row.model) }, BACKGROUND_CONTEXT)
        // A fresh context every turn: the model sees the view, the new messages and its own tool loop.
        await this.harness.session().reset()
        this.sql.exec(`UPDATE cb_turn SET submitted = 1 WHERE id = ?`, id)
        await this.harness.submit(blocks.map((text) => ({ type: "text" as const, text })), { operationId: id })
      }
      const result = await this.harness.wait(id)
      ok = result.status === "done"
      reason = ok ? null : (result.reason ?? "unknown")
    } catch (e) {
      reason = e instanceof Error ? e.message : String(e)
    } finally {
      this.turnId = undefined
      this.turnConversation = undefined
    }
    const reply = ok ? lastTalk(this.sql, id) : ""
    const post = !ok ? "none" : reply === "" || reply === NO_REPLY ? "no_reply" : "pending"
    this.sql.exec(`UPDATE cb_turn SET status = ?, reason = ?, ended = ?, input = NULL, reply = ?, post = ? WHERE id = ?`, ok ? "done" : "failed", reason, Date.now(), post === "pending" ? reply : null, post, id)
    this.sql.exec(`UPDATE cb_inbox SET state = ? WHERE turn = ?`, ok ? "done" : "failed", id)
    if (!ok) console.warn(JSON.stringify({ msg: "chief_brain.turn_failed", run: id, reason: String(reason).slice(0, 300) }))
    this.announce(id, [])
    if (post === "pending") await this.post(id)
    else await this.finish(id)
    if (!this.memory.settled()) await this.schedule("compact", "compact", Date.now() + RETRY_MS)
  }

  /** Posts the run's reply as the chief; retries the loop guard's agent_rate later; then acks the wakes. */
  private async post(id: string): Promise<void> {
    const t = this.sql.exec<{ conversation: string; trigger_message: string; trigger_kind: string; trigger_thread_root: string | null; reply: string | null; post: string; post_tries: number; post_key: number }>(`SELECT conversation, trigger_message, trigger_kind, trigger_thread_root, reply, post, post_tries, post_key FROM cb_turn WHERE id = ?`, id).toArray()[0]
    const cfg = this.config()
    if (!t || t.post !== "pending" || !t.reply || !cfg.agent || !cfg.owner) return
    const steps = Number(this.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM cb_step WHERE turn = ?`, id).one().n)
    const target = replyTarget(t.trigger_kind, t.trigger_message, t.trigger_thread_root)
    // The ledger replays a refusal under the same key, so a refused try's retry needs a new key (the
    // key is also the client message id); an unknown outcome (no answer) retries under the same key.
    const key = `chief-reply:${cfg.agent}:${id}:${t.post_key}`
    const res = await postReply(this.env, chiefPrincipal(cfg.agent, cfg.owner), { conversation: t.conversation, text: t.reply, run: { id, host: `${HOST}:${cfg.agent}`, steps }, ...target, key }).catch(
      (e: unknown) => ({ ok: false as const, code: "owner.unreachable", message: String(e) })
    )
    const retry = (res.ok === false && (res.code === "agent_rate" || res.code === "owner.unreachable")) && t.post_tries + 1 < MAX_POST_TRIES
    if (res.ok) this.sql.exec(`UPDATE cb_turn SET post = 'posted', posted_message = ?, turn_key = ? WHERE id = ?`, res.message, key, id)
    else if (retry) {
      this.sql.exec(`UPDATE cb_turn SET post_tries = post_tries + 1, post_key = post_key + ? WHERE id = ?`, res.code === "agent_rate" ? 1 : 0, id)
      await this.schedule(`post:${id}`, "post", Date.now() + POST_RETRY_MS)
      return
    } else this.sql.exec(`UPDATE cb_turn SET post = 'refused', reason = ? WHERE id = ?`, res.code, id)
    this.announce(id, [])
    await this.finish(id)
  }

  /** Typing off and the wake cursor moved past the run's messages. */
  private async finish(id: string): Promise<void> {
    const t = this.sql.exec<{ conversation: string; last_seq: number }>(`SELECT conversation, last_seq FROM cb_turn WHERE id = ?`, id).toArray()[0]
    const cfg = this.config()
    if (!t || !cfg.agent || !cfg.owner) return
    await typing(this.env, t.conversation, cfg.agent, false)
    await ackWake(this.env, cfg.agent, chiefPrincipal(cfg.agent, cfg.owner), t.conversation, t.last_seq).catch(() => undefined)
  }

  // ------------------------------------------------------------------ jobs

  private async schedule(id: string, fn: string, time: number): Promise<void> {
    await this.lifecycle.jobs.push({ id, fn, time, singleflight: true, hungTimeoutSeconds: 600 })
  }

  /** Lifecycle wakes the object for due jobs, also after an eviction. */
  async onJob({ job }: LifecycleJobContext): Promise<LifecycleJobOutcome | void> {
    if (job.fn === "post") return void (await this.post(String(job.id).slice("post:".length)))
    if (job.fn !== "compact") return
    this.compactor.pump()
    if (!(await this.compactor.settle(AbortSignal.timeout(60_000)))) return { rescheduleAt: Date.now() + RETRY_MS }
  }
}
