import { DurableObject } from "cloudflare:workers"
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context"
import type { AssistantMessage } from "@earendil-works/pi-ai"
import { createRegistry, GenerationTask, Harness, hook, InboxDoc, section, ToolTask } from "@earendil-works/pi-durable"
import { PiHarness } from "agents/harness/pi"
import { Lifecycle, type LifecycleJobContext, type LifecycleJobOutcome } from "agents/lifecycle"
import type { Env } from "../env.ts"
import { assertFaultHooks } from "../chief-fault.ts"
import { ackWake, chiefPrincipal, postReply, readConversation, runChanged, typing } from "../chief-brain/brain-io.ts"
import { postMessage } from "./post.ts"
import { clip, clipInput, readRun, readRuns, readSteps, type Run, type Step, type StepPatch, upsertStep } from "../chief-brain/brain-runs.ts"
import { type BrainConfig, readConfig, SCHEMA, writeConfig } from "../chief-brain/brain-store.ts"
import { claudeAuthFor, forgetClaudeAuth, HOLDER, turnsObject } from "../chief-brain/claude-auth.ts"
import { Compactor, compactorHold } from "../chief-brain/compactor.ts"
import { marksHeader, PrefixCache, ttlMs, turnPlan } from "../chief-brain/cache-prefix.ts"
import { capText, type Kind, Memory, RETRY_MS } from "../chief-brain/memory.ts"
import { brainModels, compactorModel, FAKE, gatewayOptions, isClaude, isMetered, pickTurnModel, turnFailedNotice } from "../chief-brain/models.ts"
import { meteredOwner } from "../model-gateway/routes.ts"
import { clipReply, formatMessage, inboxKind, isNoReply, linkIds, ownsRoot, replyTarget, textParts, threadOf } from "../chief-brain/brain-text.ts"
import { AGENT } from "../chief-brain/prompts.ts"
import { kernelSystem, kernelTools, type LedgerIntent, ledgerStep } from "./kernel.ts"
import { oneLine } from "../chief-brain/brain-text.ts"
import { AGENT_RATE_WINDOW_MS, brainName, POST_RETRY_MS, TURN_MS, type Admission } from "../chief-brain/brain-do.ts"
import { batchMarker, runRequest } from "./run-view.ts"

/**
 * ChiefDurableDO, Cloud Chief "D" (plans/cmux-next/cloud-chief-durable-DESIGN.md): one per Chief
 * conversation (name `<agent>/<conversation>`), one role. pi-durable (through the agents PiHarness,
 * whose Lifecycle job wakes an evicted object so pi resumes its own tasks) owns every run: its inbox,
 * steers, model calls, tool calls and retries. D keeps only what pi cannot know:
 *
 * - `cd_batch`: one row per wake batch (the new messages of one wake), submitted to pi once under the
 *   request id `batch:<first message id>`; a repeated wake finds the row and submits nothing.
 * - `cd_run`: the open run (one at a time) with the memory view its requests send, rendered once when
 *   the run opens, so every request of the run (and one resumed after an eviction) has the same prefix.
 *
 * A batch that comes while a run is open joins it (pi `steer`). When the model's final answer comes
 * and no message is queued, `onYield` posts the reply (client_msg_id `chief-reply:<agent>:<run>`, so a
 * rerun after a crash keeps one message), acks the wake cursor and closes the run. With a message
 * queued, the answer is not posted: pi places the queued message as the next run, which answers both.
 *
 * Settings, admission and the daily cap stay in P's settings object (ChiefBrainDO `<agent>`); the
 * Claude sign-in in P's holder; the paid-turn count in P's turns object. Memory is P's format (OptChat),
 * copied from P's conversation brain on the first wake (`memoryExport`).
 */
const SCHEMA_D = [
  `CREATE TABLE IF NOT EXISTS cd_batch (n INTEGER PRIMARY KEY AUTOINCREMENT, request TEXT UNIQUE NOT NULL, run TEXT NOT NULL, first_seq INTEGER NOT NULL, last_seq INTEGER NOT NULL, trigger_message TEXT NOT NULL, trigger_kind TEXT NOT NULL, trigger_thread_root TEXT, trigger_own_root INTEGER NOT NULL DEFAULT 1, created INTEGER NOT NULL, submitted INTEGER NOT NULL DEFAULT 0)`,
  `CREATE TABLE IF NOT EXISTS cd_run (id TEXT PRIMARY KEY, first INTEGER NOT NULL, covered TEXT NOT NULL, view TEXT NOT NULL, state TEXT NOT NULL, created INTEGER NOT NULL, post_key INTEGER NOT NULL DEFAULT 0)`,
  // View line id -> conversation message id: the kernel's send/reply name a line, a post names a message.
  `CREATE TABLE IF NOT EXISTS cd_line (i INTEGER PRIMARY KEY, message TEXT NOT NULL)`,
  // The kernel's ledgers (chief-kernel ledger.rs), as its fold returns them.
  `CREATE TABLE IF NOT EXISTS cd_ledger (k INTEGER PRIMARY KEY CHECK (k = 1), state TEXT NOT NULL)`
]
/** Columns added after the first staging deploy (CREATE TABLE IF NOT EXISTS does not add them). */
const COLUMNS_D: ReadonlyArray<[string, string, string]> = [
  ["cd_run", "stopped", "INTEGER NOT NULL DEFAULT 0"],
  // Whether trigger_thread_root is the trigger's own (brain-text ownsRoot); batches from before keep the old reply target.
  ["cd_batch", "trigger_own_root", "INTEGER NOT NULL DEFAULT 1"]
]
export const HOST_D = "cloud-chief-d"
const HARNESS_NAME = "pi-durable-d"

/**
 * D's run ids: `run_<9000000000 + n>`. The runs route takes `run_<digits>` only, and P's run ids (`run_<n>`, small n)
 * stay readable in the same conversation after a move (the route falls back to P), so the two ranges never meet.
 */
export const runIdOf = (n: number): string => `run_${9_000_000_000 + n}`

type Wake = { agent: string; owner: string; conversation: string; seq: number; reason: string; at?: number }
type OpenRun = { id: string; first: number; covered: Array<number>; view: Array<string> }

export class ChiefDurableDO extends DurableObject<Env> {
  readonly sql = this.ctx.storage.sql
  /** The open run, for the model gateway (usage, live frames, cache marks); set again by every request. */
  private current: string | undefined
  private intake: Promise<unknown> = Promise.resolve()
  private watching = new Set<string>()
  readonly memory: Memory
  readonly compactor: Compactor
  readonly registry = createRegistry()
  readonly models = brainModels(this.env, this.ctx.id.toString(), {
    claude: { auth: () => claudeAuthFor(this.env, this.holder), refused: () => (forgetClaudeAuth(), this.holder().claudeInvalidate()) },
    effort: () => this.config().effort,
    ...gatewayOptions(this.ctx, this.env, () => ({ run: this.current, conversation: this.conversation(), config: this.config(), live: true }))
  })

  readonly harness = new PiHarness({
    harness: ({ storage, context }) => {
      this.registry.install({
        name: "chief-d",
        // The kernel's system text and tool contract (chief-kernel, design section 13).
        sections: [section("chief", () => kernelSystem(this.config()), { tag: false })],
        tools: kernelTools({ memory: () => this.memory, send: (id, t, line, att) => this.send(id, t, line, att), stop: (id) => this.stopRun(id) }),
        hooks: [
          hook(GenerationTask, {
            beforeRequest: ({ messages }) => this.request(messages),
            afterResponse: (message, api) => this.onResponse(message, String(api.taskId)),
            onYield: async (answer, api, context) => {
              const inbox = await api.snapshot(InboxDoc, api.conversationId, context)
              // A message is queued: pi answers it (and this one) in the next run; nothing is posted now.
              if (inbox?.items.some((i) => i.mode !== "write")) return undefined
              await this.close(textParts(answer.content as ReadonlyArray<{ type: string; text?: string }>).trim(), true)
              return undefined
            }
          }),
          hook(ToolTask, {
            afterTool: (call, result) => {
              const text = textParts(result.content as ReadonlyArray<{ type: string; text?: string }>)
              const capped = capText(text)
              const out = clip(text)
              const now = Date.now()
              this.logOnce(`echo:${call.id}`, "echo", capped, { id: `tool:${call.id}`, kind: "tool", status: "done", ...(out.truncated ? { truncated: true } : {}), ended_at: now, tool: { name: call.name, output: out.text, ended_at: now } })
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
          // steeringMode/followUpMode "all": every message queued at a boundary joins at once (one view, one call).
          settings: { retry: { enabled: true, maxRetries: 3, baseDelayMs: 2000 }, compaction: { enabled: false, backgroundTokens: 0 }, steeringMode: "all", followUpMode: "all" },
          onReport: (error) => console.warn(JSON.stringify({ msg: "chief_d.pi_report", error: String(error).slice(0, 300) }))
        },
        context
      )
    },
    defaults: { model: this.models.model(FAKE) }
  })

  readonly lifecycle = Lifecycle.install(this).use(this.harness)

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    for (const q of [...SCHEMA, ...SCHEMA_D]) this.sql.exec(q)
    for (const [t, c, def] of COLUMNS_D) if (!this.sql.exec<{ name: string }>(`PRAGMA table_info(${t})`).toArray().some((r) => r.name === c)) this.sql.exec(`ALTER TABLE ${t} ADD COLUMN ${c} ${def}`)
    this.memory = new Memory(this.sql, Number(env.CHIEF_BRAIN_VIEW_BUDGET ?? "0") || 0)
    const cache = new PrefixCache(ttlMs(env.CHIEF_BRAIN_CACHE_TTL))
    this.compactor = new Compactor({
      memory: this.memory,
      deps: () => {
        const name = this.compactorName()
        if (name === undefined) throw new Error("compactor: this owner may not use the paid compactor, and this deployment has no free one")
        return { memory: this.memory, models: this.models.models, model: this.models.model(name), thinking: name === FAKE ? "off" : isClaude(name) ? "high" : "medium", prompt: "cmux", agent: AGENT, cache, record: (c) => console.log(JSON.stringify({ msg: "chief_d.compact_call", node: c.ref, model: c.model, ms: c.latencyMs, stop: c.stop })) }
      },
      onBuilt: () => undefined,
      off: () => (this.compactorName() === undefined ? "no compactor model this owner may use" : undefined),
      onFirstFailure: (l, i, error) => console.warn(JSON.stringify({ msg: "chief_d.compactor_failed", node: `${l}:${i}`, error: error.slice(0, 300) })),
      onRetryWait: (at) => void this.schedule("compact", "compact", at).catch(() => undefined),
      hold: compactorHold(this.sql)
    })
  }

  // ------------------------------------------------------------------ helpers

  private holder = () => this.env.CHIEF_BRAIN_DO.get(this.env.CHIEF_BRAIN_DO.idFromName(HOLDER)) as unknown as { claudeAuth(): Promise<string>; claudeInvalidate(): Promise<void> }
  private turns = (owner: string) => this.env.CHIEF_BRAIN_DO.get(this.env.CHIEF_BRAIN_DO.idFromName(turnsObject(owner))) as unknown as { claudeTurn(owner: string, model?: string): Promise<string> }
  private settingsOf = (agent: string) => this.env.CHIEF_BRAIN_DO.get(this.env.CHIEF_BRAIN_DO.idFromName(agent)) as unknown as { admit(agent: string, owner: string, turn: boolean): Promise<Admission> }
  private get(name: string): string | undefined {
    return this.sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = ?`, name).toArray()[0]?.value
  }
  private conversation = (): string | undefined => this.get("conversation")

  config(): BrainConfig {
    return readConfig(this.sql, { model: this.env.CHIEF_BRAIN_MODEL || FAKE, compactor_model: this.env.CHIEF_BRAIN_COMPACTOR_MODEL || this.env.CHIEF_BRAIN_FALLBACK_MODEL || FAKE })
  }

  private compactorName(): string | undefined {
    const cfg = this.config()
    const fallback = this.env.CHIEF_BRAIN_FALLBACK_MODEL || FAKE
    const picked = compactorModel(this.env, cfg.compactor_model, fallback)
    if (!isMetered(picked) || meteredOwner(this.env, cfg.owner ?? null)) return picked
    return !isMetered(fallback) ? fallback : !isMetered(cfg.model) && cfg.model ? cfg.model : undefined
  }

  /** Asks P's settings object, and keeps its answer as this brain's config copy. */
  private async admitted(agent: string, owner: string, turn: boolean): Promise<Admission> {
    const a = await this.settingsOf(agent).admit(agent, owner, turn)
    if (a.ok) {
      const { agent: ag, owner: ow, enabled, chiefs, ...rest } = a.config
      writeConfig(this.sql, { agent: ag ?? undefined, owner: ow ?? undefined, enabled: enabled ? "1" : "0", chiefs: chiefs ? "1" : "0", ...rest })
    }
    return a
  }

  private openRun(): OpenRun | null {
    const r = this.sql.exec<{ id: string; first: number; covered: string; view: string }>(`SELECT id, first, covered, view FROM cd_run WHERE state = 'open' ORDER BY created LIMIT 1`).toArray()[0]
    return r ? { id: r.id, first: Number(r.first), covered: JSON.parse(r.covered) as Array<number>, view: JSON.parse(r.view) as Array<string> } : null
  }

  /** Appends to the memory log once per key (hooks rerun after an eviction), with the run's step. */
  private logOnce(key: string, kind: Kind, text: string, step?: StepPatch): void {
    const run = this.openRun()?.id
    let changed: Step | undefined
    let logged = false
    this.ctx.storage.transactionSync(() => {
      if (this.sql.exec(`SELECT 1 FROM oc_logged WHERE key = ?`, key).toArray().length > 0) return
      this.sql.exec(`INSERT INTO oc_logged (key) VALUES (?)`, key)
      this.memory.append(kind, text)
      if (run && step) changed = upsertStep(this.sql, run, step, Date.now())
      logged = true
    })
    if (logged) this.compactor.pump()
    if (run && changed) this.announce(run, [changed])
  }

  private announce(run: string, steps: ReadonlyArray<Step>): void {
    const agent = this.config().agent
    const r = agent ? this.readRunD(agent, run) : null
    if (agent && r) this.ctx.waitUntil(runChanged(this.env, r.conversation, agent, r, steps))
  }

  private readRunD(agent: string, id: string): Run | null {
    const r = readRun(this.sql, agent, id)
    return r ? { ...r, harness: HARNESS_NAME, session: { kind: "pi", id, host: "cloud" } } : null
  }

  // ------------------------------------------------------------------ pi hooks

  private request<M extends { role: string; content?: unknown }>(messages: ReadonlyArray<M>): { messages: Array<M> } | undefined {
    const run = this.openRun()
    if (!run) return undefined
    this.current = run.id
    const agent = this.config().agent
    const conversation = this.conversation()
    if (agent && conversation) void typing(this.env, conversation, agent, true)
    const out = runRequest(messages, run)
    return out ? { messages: out } : undefined
  }

  private onResponse(message: AssistantMessage, taskId: string): void {
    if (message.stopReason === "error" || message.stopReason === "aborted") return
    const text = textParts(message.content as ReadonlyArray<{ type: string; text?: string }>).trim()
    if (text) this.logOnce(`talk:${taskId}`, "talk", text, { id: `talk:${taskId}`, kind: "talk", ...clip(text), ended_at: Date.now() })
    for (const part of message.content) {
      if (part.type !== "toolCall") continue
      const tool = { name: part.name, input: clipInput(part.arguments), started_at: Date.now() }
      this.logOnce(`tool:${part.id}`, "tool", `${part.name} ${JSON.stringify(part.arguments)}`, { id: `tool:${part.id}`, kind: "tool", status: "running", tool })
    }
  }

  /**
   * Ends the open run: posts `text` as the Chief (unless it is empty or NO_REPLY), acks the wake cursor
   * past the run's messages and turns typing off. `ok` false: the run failed (a notice says why).
   */
  private async close(text: string, ok: boolean, reason?: string): Promise<void> {
    const run = this.openRun()
    const cfg = this.config()
    if (!run || !cfg.agent || !cfg.owner) return
    const conversation = this.conversation()!
    const principal = chiefPrincipal(cfg.agent, cfg.owner)
    const t = this.sql.exec<{ trigger_message: string; trigger_kind: string; trigger_thread_root: string | null; trigger_own_root: number; last_seq: number }>(`SELECT trigger_message, trigger_kind, trigger_thread_root, trigger_own_root, last_seq FROM cd_batch WHERE run = ? ORDER BY n DESC LIMIT 1`, run.id).toArray()[0]
    const lastSeq = Number(this.sql.exec<{ s: number }>(`SELECT MAX(last_seq) AS s FROM cd_batch WHERE run = ?`, run.id).one().s)
    const stopped = Number(this.sql.exec<{ s: number }>(`SELECT stopped AS s FROM cd_run WHERE id = ?`, run.id).one().s) === 1
    // After stop() nothing more is posted (chief-kernel STOP_DESCRIPTION).
    const reply = ok && text && !stopped && !isNoReply(text) ? clipReply(linkIds(text)) : ""
    let post: string = !ok ? "none" : reply ? "pending" : "no_reply"
    let posted: string | null = null
    // The op ledger replays a refusal under its key, so each refused try moves to a new key (kept here, so a rerun of
    // this hook after a crash reuses the key of the try that may have committed: one message either way).
    const keyOf = () => `chief-reply-d:${cfg.agent}:${run.id}:${Number(this.sql.exec<{ k: number }>(`SELECT post_key AS k FROM cd_run WHERE id = ?`, run.id).one().k)}`
    let key = keyOf()
    if (reply && t) {
      const steps = Number(this.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM cb_step WHERE turn = ?`, run.id).one().n)
      const ended = Date.now()
      // The loop guard's agent_rate is "wait": retried every POST_RETRY_MS for up to AGENT_RATE_WINDOW_MS. Same key every try:
      // a refused try commits nothing, an unknown outcome commits once.
      for (;;) {
        key = keyOf()
        const res = await postReply(this.env, principal, { conversation, text: reply, run: { id: run.id, host: `${HOST_D}:${cfg.agent}`, steps }, ...replyTarget(t.trigger_kind, t.trigger_message, t.trigger_thread_root, t.trigger_own_root !== 0), key }).catch((e: unknown) => ({ ok: false as const, code: "owner.unreachable", message: String(e) }))
        if (res.ok) {
          post = "posted"
          posted = res.message
          this.ledger({ type: "reply_posted", answers: [], reply_to: replyTarget(t.trigger_kind, t.trigger_message, t.trigger_thread_root, t.trigger_own_root !== 0).reply_to ?? null, chief: true, text: reply })
          break
        }
        if ((res.code === "agent_rate" || res.code === "owner.unreachable") && Date.now() - ended < AGENT_RATE_WINDOW_MS) {
          // A refusal is final for its key; no answer (owner.unreachable) may have committed, so it keeps the key.
          if (res.code === "agent_rate") this.sql.exec(`UPDATE cd_run SET post_key = post_key + 1 WHERE id = ?`, run.id)
          await new Promise((r) => setTimeout(r, POST_RETRY_MS)) // bounded wait for the loop guard's 2 s gap; the hook holds the run meanwhile
          continue
        }
        post = "refused"
        console.warn(JSON.stringify({ msg: "chief_d.post_refused", run: run.id, code: res.code }))
        break
      }
    }
    this.ctx.storage.transactionSync(() => {
      this.sql.exec(`UPDATE cd_run SET state = ? WHERE id = ?`, ok ? "closed" : "failed", run.id)
      this.sql.exec(`UPDATE cb_turn SET status = ?, reason = ?, ended = ?, reply = ?, post = ?, posted_message = ?, turn_key = ? WHERE id = ?`, ok ? "done" : "failed", reason ?? null, Date.now(), reply || null, post, posted, posted ? key : null, run.id)
      this.sql.exec(`UPDATE cb_inbox SET state = ? WHERE turn = ?`, ok ? "done" : "failed", run.id)
    })
    this.current = undefined
    this.announce(run.id, [])
    this.ledger({ type: "turn_ended", said_no_reply: ok && isNoReply(text) })
    if (!ok) await turnFailedNotice(this.env, this.sql, cfg, conversation, run.id, reason ?? "unknown", undefined)
    await typing(this.env, conversation, cfg.agent, false)
    if (Number.isFinite(lastSeq)) await ackWake(this.env, cfg.agent, principal, conversation, lastSeq).catch(() => undefined)
  }

  // ------------------------------------------------------------------ RPC

  /** MuxDO's wake (at least once): the new messages become one batch, submitted to pi once. */
  async wake(w: Wake): Promise<{ queued: number } | { skipped: string; retry?: true }> {
    const p = this.intake.then(() => this.take(w))
    this.intake = p.catch(() => undefined)
    return p
  }

  private async take(w: Wake): Promise<{ queued: number } | { skipped: string; retry?: true }> {
    await this.lifecycle.start()
    writeConfig(this.sql, { conversation: w.conversation })
    const principal = chiefPrincipal(w.agent, w.owner)
    const [a, view] = await Promise.all([this.admitted(w.agent, w.owner, false).catch((): Admission => ({ ok: false, reason: "owner.unreachable" })), readConversation(this.env, w.conversation, principal)])
    if (!a.ok) return a.reason === "owner.unreachable" ? { skipped: a.reason, retry: true } : { skipped: a.reason }
    if ("refused" in view) return view.refused === "unknown_conversation" ? { skipped: view.refused, retry: true } : { skipped: view.refused }
    if (this.get("imported") === undefined) await this.importFromP(w)
    const cursor = this.sql.exec<{ seq: number }>(`SELECT seq FROM cb_cursor WHERE conversation = ?`, w.conversation).toArray()[0]?.seq ?? w.seq - 1
    const fresh = view.messages.filter((m) => m.seq > cursor)
    const top = fresh.reduce((s, m) => Math.max(s, m.seq), cursor)
    const rows = fresh.flatMap((m) => {
      if (m.author === w.agent || m.retracted_at !== undefined) return []
      const text = formatMessage(view.head, m, { owner: w.owner })
      // A reply that names no thread is in the thread of the message it answers (#25588; brain-text threadOf).
      return text ? [{ id: m.id, seq: m.seq, thread_root: threadOf(m, view.messages), own_root: ownsRoot(m) ? 1 : 0, text }] : []
    })
    this.sql.exec(`INSERT INTO cb_cursor (conversation, seq) VALUES (?, ?) ON CONFLICT (conversation) DO UPDATE SET seq = MAX(seq, excluded.seq)`, w.conversation, top)
    if (rows.length === 0) {
      if (top > cursor && !this.openRun()) await ackWake(this.env, w.agent, principal, w.conversation, top).catch(() => undefined)
      this.watchOpen()
      return { queued: 0 }
    }
    const kind = inboxKind(view.head)
    const trigger = rows.find((r) => r.seq === w.seq) ?? rows[rows.length - 1]!
    // A person's message waits for words (the reply ledger) when it was for the Chief: its own chat or a DM, or a
    // mention or reply in a group. A group message that woke it only by wake_policy "all" may get NO_REPLY.
    const forChief = oneLine(kind) || w.reason === "mention" || w.reason === "reply"
    const persons = new Set(view.head.participants.filter((p) => p.kind === "human").map((p) => p.id))
    const waits = new Set(fresh.filter((m) => m.seq === w.seq && forChief && persons.has(m.author)).map((m) => m.id))
    return this.submitBatch({ agent: w.agent, owner: w.owner, conversation: w.conversation, request: `batch:${rows[0]!.id}`, rows, trigger: { id: trigger.id, thread_root: trigger.thread_root, own_root: trigger.own_root }, kind, wokeSeq: w.seq, top, waits })
  }

  /**
   * Opens a run for a batch, or joins the open run with it, and submits it to pi once (request id `request`).
   * `rows`: the new messages (logged to memory once each, keyed by message id); `note`: a host note instead
   * (the reply ledger's retry), shown after the view and never logged. `waits`: the person messages the
   * kernel's reply ledger tracks.
   */
  private async submitBatch(b: { agent: string; owner: string; conversation: string; request: string; rows: ReadonlyArray<{ id: string; seq: number; thread_root: string | null; own_root: number; text: string }>; note?: string; trigger: { id: string; thread_root: string | null; own_root: number }; kind: string; wokeSeq: number; top: number; waits: ReadonlySet<string> }): Promise<{ queued: number } | { skipped: string; retry?: true }> {
    const principal = chiefPrincipal(b.agent, b.owner)
    const { rows } = b
    // A new run is admitted (the daily turn count, credits) once; a batch that joins an open run is not.
    const open = this.openRun()
    if (!open) {
      const t = await this.admitted(b.agent, b.owner, true).catch((): Admission => ({ ok: false, reason: "owner.unreachable" }))
      if (!t.ok) {
        // Not answered: the rows were seen (cursor moved), the wake is acked so the queue stays bounded.
        if (t.reason === "owner.unreachable") return { skipped: t.reason, retry: true }
        await typing(this.env, b.conversation, b.agent, false)
        await ackWake(this.env, b.agent, principal, b.conversation, b.top).catch(() => undefined)
        return { skipped: t.reason }
      }
    }
    const request = b.request
    let n = 0
    let runId = open?.id ?? ""
    let model = this.config().model
    if (!open) {
      const picked = await pickTurnModel(model, this.env.CHIEF_BRAIN_FALLBACK_MODEL, (m) => this.turns(b.owner).claudeTurn(b.owner, m).then((v) => (v !== "ok" || !isClaude(m) ? v : claudeAuthFor(this.env, this.holder).then(() => "ok", () => "auth_failed"))).catch(() => "holder_unreachable"))
      if (picked.model === null) {
        console.warn(JSON.stringify({ msg: "chief_d.paid_model_refused", reason: picked.reason }))
        await ackWake(this.env, b.agent, principal, b.conversation, b.top).catch(() => undefined)
        return { skipped: "model_refused" }
      }
      model = picked.model
    }
    const firstSeq = rows[0]?.seq ?? b.top
    const lastSeq = rows[rows.length - 1]?.seq ?? b.top
    const created = this.ctx.storage.transactionSync(() => {
      const dup = this.sql.exec<{ n: number }>(`SELECT n FROM cd_batch WHERE request = ?`, request).toArray()[0]
      if (dup) return false
      n = Number(this.sql.exec<{ n: number }>(`INSERT INTO cd_batch (request, run, first_seq, last_seq, trigger_message, trigger_kind, trigger_thread_root, trigger_own_root, created) VALUES (?, '', ?, ?, ?, ?, ?, ?, ?) RETURNING n`, request, firstSeq, lastSeq, b.trigger.id, b.kind, b.trigger.thread_root, b.trigger.own_root, Date.now()).one().n)
      const fresher = this.memory.first() >= this.memory.len()
      for (const r of rows) {
        if (this.sql.exec(`INSERT INTO oc_logged (key) VALUES (?) ON CONFLICT DO NOTHING RETURNING key`, `user:${r.id}`).toArray().length === 0) continue
        const entry = this.memory.append("user", r.text)
        this.sql.exec(`INSERT INTO cd_line (i, message) VALUES (?, ?) ON CONFLICT DO NOTHING`, entry.i, r.id)
        this.ledgerSync({ type: "message_logged", id: r.id, seq: r.seq, text: r.text, from_person: b.waits.has(r.id) })
      }
      if (!open) {
        runId = runIdOf(n)
        const blocks = [...this.memory.turnInput(rows.length, fresher), ...(b.note ? [b.note] : [])].filter((t) => t.trim().length > 0)
        writeConfig(this.sql, { [`marks:${runId}`]: marksHeader(turnPlan(this.sql, model, blocks, ttlMs(this.env.CHIEF_BRAIN_CACHE_TTL))) })
        this.sql.exec(`INSERT INTO cd_run (id, first, covered, view, state, created) VALUES (?, ?, ?, ?, 'open', ?)`, runId, n, JSON.stringify([n]), JSON.stringify(blocks), Date.now())
        this.sql.exec(`INSERT INTO cb_turn (id, conversation, trigger_message, trigger_kind, trigger_thread_root, last_seq, status, model, started, submitted) VALUES (?, ?, ?, ?, ?, ?, 'running', ?, ?, 1)`, runId, b.conversation, b.trigger.id, b.kind, b.trigger.thread_root, lastSeq, model, Date.now())
      } else this.sql.exec(`UPDATE cb_turn SET last_seq = MAX(last_seq, ?), trigger_message = ?, trigger_thread_root = ? WHERE id = ?`, lastSeq, b.trigger.id, b.trigger.thread_root, runId)
      this.sql.exec(`UPDATE cd_batch SET run = ? WHERE n = ?`, runId, n)
      for (const r of rows) this.sql.exec(`INSERT INTO cb_inbox (message, conversation, seq, kind, thread_root, text, woke, state, turn) VALUES (?, ?, ?, ?, ?, ?, ?, 'running', ?) ON CONFLICT (message) DO NOTHING`, r.id, b.conversation, r.seq, b.kind, r.thread_root, r.text, r.seq === b.wokeSeq ? 1 : 0, runId)
      // Every message this run will see; a retry note's run sees the messages that still wait.
      const seen = b.note ? this.awaitingIds() : rows.map((r) => r.id)
      this.ledgerSync({ type: "turn_started", seen, reports: [] })
      return true
    })
    this.compactor.pump()
    if (!created) {
      // Submitted before (this wake repeats one that got no answer): pi takes the same request id once.
      n = Number(this.sql.exec<{ n: number }>(`SELECT n FROM cd_batch WHERE request = ?`, request).one().n)
      runId = String(this.sql.exec<{ run: string }>(`SELECT run FROM cd_batch WHERE n = ?`, n).one().run)
    }
    const session = this.harness.session()
    if (!open && created) {
      const root = await (await this.harness.pi()).root(BACKGROUND_CONTEXT)
      const m = this.models.model(model)
      await root.configure({ model: { provider: m.provider, modelId: m.id }, thinkingLevel: this.models.thinking(model) }, BACKGROUND_CONTEXT)
      // A fresh pi context per run when pi is idle (its transcript then holds this run only); a run that opens while
      // pi finishes the last one starts after it, and the request hook cuts the older entries off.
      if (!(await session.busy())) await session.reset()
      // After an eviction the job wakes the object and the watch starts again (onStart does too).
      await this.schedule("watch", "watch", Date.now() + 60_000)
      this.announce(runId, [])
    }
    const body = b.note ?? rows.map((r) => r.text).join("\n\n")
    const input = [{ type: "text" as const, text: `${batchMarker(n)}${body}` }]
    await this.harness.submit(input, { operationId: request, whenBusy: "steer" })
    // Only a submitted batch is waited on (pi answers an unknown id "not_found", which is not a failed run).
    this.sql.exec(`UPDATE cd_batch SET submitted = 1 WHERE n = ?`, n)
    this.watchOpen()
    return { queued: rows.length }
  }

  // ------------------------------------------------------------------ kernel tools and ledgers

  /** The kernel's send/reply: one post now, in the thread of view line `line` (its message), keyed by the call. */
  private async send(callId: string, text: string, line: number | undefined, attachments: ReadonlyArray<string>): Promise<string> {
    const cfg = this.config()
    const conversation = this.conversation()
    if (!cfg.agent || !cfg.owner || !conversation) return "Not sent: this Chief has no conversation yet."
    const body = clipReply(linkIds(text.trim()))
    if (!body) return "Not sent: the text is empty."
    const replyTo = line === undefined ? undefined : this.sql.exec<{ message: string }>(`SELECT message FROM cd_line WHERE i = ?`, line).toArray()[0]?.message
    const res = await postMessage(this.env, chiefPrincipal(cfg.agent, cfg.owner), { conversation, text: body, key: `chief-send-d:${cfg.agent}:${callId}`, ...(replyTo ? { reply_to: replyTo } : {}) })
    if (!res.ok) return `Not sent: ${res.code}.`
    this.logOnce(`send:${callId}`, "talk", body)
    this.ledger({ type: "reply_posted", answers: [], reply_to: replyTo ?? null, chief: true, text: body })
    const notes = [line !== undefined && !replyTo ? `line ${line} is not a message this Chief can reply to, so it went to the chat` : "", attachments.length > 0 ? "attachments are not sent by a Cloud Chief yet" : ""].filter(Boolean)
    return `Sent${notes.length ? ` (${notes.join("; ")})` : ""}.`
  }

  /** The kernel's stop: the open run posts nothing more. */
  private stopRun(_callId: string): void {
    const run = this.openRun()
    if (run) this.sql.exec(`UPDATE cd_run SET stopped = 1 WHERE id = ?`, run.id)
  }

  private awaitingIds(): Array<string> {
    const state = this.sql.exec<{ state: string }>(`SELECT state FROM cd_ledger WHERE k = 1`).toArray()[0]?.state ?? "{}"
    return ((JSON.parse(state) as { awaiting?: Array<{ id: string }> }).awaiting ?? []).map((a) => a.id)
  }

  /** One ledger fold in the caller's transaction; its intents are kept and done after it (doIntents). */
  private ledgerSync(event: Record<string, unknown>): void {
    const state = this.sql.exec<{ state: string }>(`SELECT state FROM cd_ledger WHERE k = 1`).toArray()[0]?.state ?? "{}"
    const out = ledgerStep(state, event, Date.now())
    this.sql.exec(`INSERT INTO cd_ledger (k, state) VALUES (1, ?) ON CONFLICT (k) DO UPDATE SET state = excluded.state`, out.state)
    this.pendingIntents.push(...out.intents)
    if (out.intents.length > 0) queueMicrotask(() => void this.doIntents())
  }
  private pendingIntents: Array<LedgerIntent> = []

  /** One ledger fold now, then its intents. */
  private ledger(event: Record<string, unknown>): void {
    this.ctx.storage.transactionSync(() => this.ledgerSync(event))
  }

  /** The kernel decided, the host acts: a check at a time, a retry turn on a note, or a failure post. Each is keyed. */
  private async doIntents(): Promise<void> {
    const todo = this.pendingIntents.splice(0)
    const cfg = this.config()
    const conversation = this.conversation()
    for (const it of todo) {
      try {
        if (it.kind === "schedule") await this.schedule(it.key, "ledger", it.at_ms)
        else if (it.kind === "notice" && cfg.agent && cfg.owner && conversation) await this.notice(cfg.agent, cfg.owner, conversation, it.text, it.key)
        else if (it.kind === "post" && cfg.agent && cfg.owner && conversation) await postMessage(this.env, chiefPrincipal(cfg.agent, cfg.owner), { conversation, text: it.text, reply_to: it.reply_to, key: `chief-ledger-d:${cfg.agent}:${it.key}` })
      } catch (e) {
        console.warn(JSON.stringify({ msg: "chief_d.intent_failed", kind: it.kind, key: it.key, error: String(e).slice(0, 200) }))
      }
    }
  }

  /** A retry turn on the ledger's note, answering in the thread of the newest batch's trigger. */
  private async notice(agent: string, owner: string, conversation: string, note: string, key: string): Promise<void> {
    const last = this.sql.exec<{ trigger_message: string; trigger_kind: string; trigger_thread_root: string | null; trigger_own_root: number; last_seq: number }>(`SELECT trigger_message, trigger_kind, trigger_thread_root, trigger_own_root, last_seq FROM cd_batch ORDER BY n DESC LIMIT 1`).toArray()[0]
    if (!last) return
    const p = this.intake.then(() => this.submitBatch({ agent, owner, conversation, request: `note:${key}`, rows: [], note, trigger: { id: last.trigger_message, thread_root: last.trigger_thread_root, own_root: last.trigger_own_root }, kind: last.trigger_kind, wokeSeq: -1, top: Number(last.last_seq), waits: new Set() }))
    this.intake = p.catch(() => undefined)
    await p
  }

  /**
   * Watches the open run's newest input until pi settles it. A run pi ends unanswered (model error, abort,
   * the time limit) is closed failed; a run onYield closed is done. In memory only: onStart starts it again.
   */
  private watchOpen(): void {
    const run = this.openRun()
    if (!run || this.watching.has(run.id)) return
    this.watching.add(run.id)
    const started = Number(this.sql.exec<{ s: number }>(`SELECT started AS s FROM cb_turn WHERE id = ?`, run.id).toArray()[0]?.s ?? Date.now())
    const watch = async () => {
      try {
        for (let seen = ""; ; ) {
          const still = this.openRun()
          if (!still || still.id !== run.id) return
          const newest = this.sql.exec<{ request: string }>(`SELECT request FROM cd_batch WHERE run = ? AND submitted = 1 ORDER BY n DESC LIMIT 1`, run.id).toArray()[0]?.request
          if (!newest) return
          // A batch recorded but not yet submitted (its wake is still in take, or MuxDO sends it again): take submits it.
          const pending = this.sql.exec(`SELECT 1 FROM cd_batch WHERE run = ? AND submitted = 0`, run.id).toArray().length > 0
          if (newest === seen && pending) return
          if (newest === seen) {
            // Settled and still open with no newer input: onYield was skipped for a queued write; close on the last talk.
            const talk = readSteps(this.sql, run.id, 0, 2000).filter((s) => s.kind === "talk" && s.text).at(-1)?.text ?? ""
            return await this.close(talk, true)
          }
          const left = started + TURN_MS - Date.now()
          let timer: ReturnType<typeof setTimeout> | undefined
          const r = await Promise.race([this.harness.wait(newest), new Promise<"timeout">((res) => (timer = setTimeout(() => res("timeout"), Math.max(1_000, left))))]).finally(() => clearTimeout(timer))
          if (r === "timeout") {
            await this.harness.session().abort().catch(() => undefined)
            return await this.close("", false, "timeout")
          }
          if (r.status !== "done") return await this.close("", false, r.reason ?? "unanswered")
          seen = newest
          // onYield ran for a done input in the same commit chain; give it the turn to close the run first.
          await new Promise((res) => setTimeout(res, 0))
        }
      } catch (e) {
        console.warn(JSON.stringify({ msg: "chief_d.watch_failed", run: run.id, error: String(e).slice(0, 200) }))
      } finally {
        this.watching.delete(run.id)
      }
    }
    this.ctx.waitUntil(watch())
  }

  async onStart(): Promise<void> {
    this.compactor.pump()
    this.watchOpen()
  }

  /** P's conversation brain copies its memory and read cursor here, once, before D's first batch. */
  private async importFromP(w: Wake): Promise<void> {
    const p = this.env.CHIEF_BRAIN_DO.get(this.env.CHIEF_BRAIN_DO.idFromName(brainName(w.agent, w.conversation))) as unknown as { memoryExport(after: number, limit: number): Promise<MemoryExport> }
    const head = await p.memoryExport(-1, 500)
    if (head.count > 0 && this.memory.len() === 0) {
      const rows = [...head.messages]
      for (let after = rows.at(-1)?.i ?? -1; rows.length < head.count; after = rows.at(-1)!.i) {
        const page = await p.memoryExport(after, 500)
        if (page.messages.length === 0) break
        rows.push(...page.messages.filter((m) => m.i < head.count))
      }
      this.ctx.storage.transactionSync(() => {
        for (const m of rows) this.sql.exec(`INSERT INTO oc_message (i, kind, text, size, date) VALUES (?, ?, ?, ?, ?) ON CONFLICT DO NOTHING`, m.i, m.kind, m.text, m.size, m.date)
        for (const n of head.nodes) this.sql.exec(`INSERT INTO oc_node (l, i, text, size) VALUES (?, ?, ?, ?) ON CONFLICT DO NOTHING`, n.l, n.i, n.text, n.size)
        for (const k of head.logged) this.sql.exec(`INSERT INTO oc_logged (key) VALUES (?) ON CONFLICT DO NOTHING`, k)
        if (head.checkpoint) this.sql.exec(`INSERT INTO oc_checkpoint (id, json) VALUES (1, ?) ON CONFLICT (id) DO UPDATE SET json = excluded.json`, head.checkpoint)
        if (head.cursor !== null) this.sql.exec(`INSERT INTO cb_cursor (conversation, seq) VALUES (?, ?) ON CONFLICT (conversation) DO UPDATE SET seq = MAX(seq, excluded.seq)`, w.conversation, head.cursor)
      })
      this.memory.reload()
      console.log(JSON.stringify({ msg: "chief_d.memory_imported", conversation: w.conversation, messages: rows.length, nodes: head.nodes.length }))
    } else if (head.cursor !== null) this.sql.exec(`INSERT INTO cb_cursor (conversation, seq) VALUES (?, ?) ON CONFLICT (conversation) DO UPDATE SET seq = MAX(seq, excluded.seq)`, w.conversation, head.cursor)
    writeConfig(this.sql, { imported: "1" })
  }

  /** A run with its steps after `afterSeq`, or null (the Worker checked the caller is a member first). */
  async run(id: string, afterSeq = 0, limit = 500): Promise<{ run: Run; steps: Array<Step>; has_more: boolean } | null> {
    const agent = this.config().agent
    const run = agent ? this.readRunD(agent, id) : null
    if (!run) return null
    const steps = readSteps(this.sql, id, afterSeq, limit + 1)
    return { run, steps: steps.slice(0, limit), has_more: steps.length > limit }
  }

  async runs(conversation: string, before: number | undefined, limit: number): Promise<{ runs: Array<Run>; has_more: boolean }> {
    const agent = this.config().agent
    if (!agent) return { runs: [], has_more: false }
    const r = readRuns(this.sql, agent, conversation, before, limit)
    return { ...r, runs: r.runs.map((x) => ({ ...x, harness: HARNESS_NAME })) }
  }

  /** Test only (chief-fault.ts): dies as an eviction does. */
  async fault(): Promise<void> {
    assertFaultHooks(this.env)
    this.ctx.abort("chief fault hook: evict")
  }

  // ------------------------------------------------------------------ jobs

  private async schedule(id: string, fn: string, time: number): Promise<void> {
    await this.lifecycle.jobs.push({ id, fn, time, singleflight: true, hungTimeoutSeconds: 600 })
  }

  /** Lifecycle wakes the object for due jobs, also after an eviction: the run watch and the compactor's retries. */
  async onJob({ job }: LifecycleJobContext): Promise<LifecycleJobOutcome | void> {
    if (job.fn === "watch") {
      this.watchOpen()
      return this.openRun() ? { rescheduleAt: Date.now() + 60_000 } : undefined
    }
    if (job.fn === "ledger") return void this.ledger({ type: "check_due" })
    if (job.fn !== "compact" || this.compactor.off()) return
    // Held after failures (compactor.ts): wake when the hold ends, without keeping the object up meanwhile.
    const held = this.compactor.cooling()
    if (held > 0) return { rescheduleAt: Date.now() + Math.max(held, RETRY_MS) }
    this.compactor.pump()
    if (!(await this.compactor.settle(AbortSignal.timeout(60_000)))) return { rescheduleAt: Date.now() + Math.max(RETRY_MS, this.compactor.cooling()) }
  }
}

export interface MemoryExport {
  readonly count: number
  readonly messages: ReadonlyArray<{ i: number; kind: string; text: string; size: number; date: string }>
  readonly nodes: ReadonlyArray<{ l: number; i: number; text: string; size: number }>
  readonly logged: ReadonlyArray<string>
  readonly checkpoint: string | null
  readonly cursor: number | null
}
