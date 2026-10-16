import { DurableObject } from "cloudflare:workers"
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context"
import type { AssistantMessage } from "@earendil-works/pi-ai"
import { createRegistry, GenerationTask, Harness, hook, section, ToolTask } from "@earendil-works/pi-durable"
import { PiHarness } from "agents/harness/pi"
import { Lifecycle, type LifecycleJobContext, type LifecycleJobOutcome } from "agents/lifecycle"
import type { Env } from "../env.ts"
import { ackWake, chiefPrincipal, chiefRecord, chiefRecordFresh, postReply, readConversation, runChanged, typing } from "./brain-io.ts"
import { clip, clipInput, flushMarks, lastTalk, markPending, runError, readRun, readRuns, readSteps, type Run, type Step, type StepPatch, upsertStep } from "./brain-runs.ts"
import { type BrainConfig, patchError, readConfig, SCHEMA, writeConfig } from "./brain-store.ts"
import { AUTH_FAILED, holderAuth, holderInvalidate, holderTurn, HOLDER } from "./claude-auth.ts"
import { Compactor, type CallRecord } from "./compactor.ts"
import { prunePiEntries } from "./pi-prune.ts"
import { type LedgerAnswer, type LedgerOp, runLedger } from "../model-gateway/run-ledger.ts"
import { capText, type Kind, Memory, RETRY_MS } from "./memory.ts"
import { brainModels, compactorDefault, compactorModel, creditsCanStart, creditsNotice, FAKE, turnFailedNotice, gatewayOptions, isClaude, liveOf, modelRefusal, pickTurnModel, validModelName } from "./models.ts"
import { clipReply, formatMessage, isNoReply, replyTarget, systemFirst, textParts } from "./brain-text.ts"
import { AGENT, systemPrompt } from "./prompts.ts"
import { handsTools, memoryTools } from "./brain-tools.ts"
import { chiefsTools } from "./brain-chiefs.ts"

/**
 * ChiefBrainDO, one per chief (name = the chief's agent id): a Chief that answers in Cloud
 * conversations by itself, on pi-durable (the Cloudflare agents SDK PiHarness), with the OptChat
 * memory (optchat-wasm over this object's SQLite) as its whole context. Ported from optchat-lab
 * impl/pi-durable (ChatDO): same memory, compactor and one-fresh-pi-session-per-turn loop.
 *
 * Two roles of one class: the chief's settings object (name `<agent>`, the owner's settings and the
 * daily turn count) and one brain per conversation (name `<agent>/<conversation>`, memory, inbox and
 * runs), so a reply in one conversation never draws on another conversation's messages.
 *
 * Input: MuxDO forwards each committed `mux.wake` of a cloud-brain chief (a DM, a mention, a reply,
 * or every person's message in a channel with wake_policy "all") to the conversation's brain, which
 * pulls the new messages as the chief and runs one turn per batch, answering the newest woken one.
 * Output: one `message.send` per turn as the chief (thread reply in a channel), carrying a `work`
 * part that names the run; the run's steps (talk, tool, echo) are read with `run()`. Typing frames
 * show while a turn runs. `NO_REPLY` posts nothing. Then `mux.ack` moves the wake cursor.
 * Off unless the owner enabled it (`configure`); every turn and post asks the settings object
 * (enabled, the chief record live and not placed on a server, under the daily turn limit). The
 * Worker forwards wakes only where CHIEF_BRAIN_ENABLED is "1".
 */
/** Post retries after the loop guard's agent_rate (another agent spoke under 2 s ago). */
const POST_RETRY_MS = 2_500
const MAX_POST_TRIES = 6
const HOST = "cloud-chief"
/** A turn waits at most this long for the compactor to settle the view, then runs on the view as it is. */
const SETTLE_MS = 3_000 // only before a forced re-render (Memory.foldDue); a turn never waits on the compactor otherwise
/** A turn that runs longer is stopped and recorded failed. */
const TURN_MS = 10 * 60_000
const DEFAULT_DAILY_TURNS = 300

export const brainName = (agent: string, conversation: string) => `${agent}/${conversation}`
export type Admission = { readonly ok: true; readonly config: BrainConfig } | { readonly ok: false; readonly reason: string }

export type ConfigPatch = Partial<Pick<BrainConfig, "enabled" | "model" | "effort" | "compactor_model" | "role" | "personality" | "instructions" | "chiefs">>

export class ChiefBrainDO extends DurableObject<Env> {
  private readonly sql = this.ctx.storage.sql
  readonly models = brainModels(this.env, this.ctx.id.toString(), { claude: { auth: () => this.holder().claudeAuth(), refused: () => this.holder().claudeInvalidate() }, effort: () => this.config().effort, ...gatewayOptions(this.ctx, this.env, () => ({ run: this.turnId, conversation: this.turnConversation, config: this.config() })) })
  readonly registry = createRegistry()
  memory: Memory
  compactor: Compactor
  private turnId: string | undefined
  private turnConversation: string | undefined
  private draining: Promise<void> | undefined
  private readonly posting = new Set<string>()
  /** Operations that joined the running turn (messages that came in while it ran): the turn waits for them too. */
  private steered: Array<string> = []
  /** The running turn's input is with pi: from then until it ends, new messages may join it. */
  private turnLive = false
  private authing: Promise<string> | undefined

  readonly harness = new PiHarness({
    harness: ({ storage, context }) => {
      this.registry.install({
        name: "chief",
        sections: [section("chief", () => systemPrompt(this.config()), { tag: false })],
        tools: [...memoryTools(() => this.memory), ...chiefsTools(this.env, () => this.config()), ...handsTools(this.env, () => ({ ...this.config(), run: this.turnId, conversation: this.turnConversation, ledger: (jti: string, o: LedgerOp) => runLedger(this.sql, this.turnId ?? "", jti, 0, o) }), (r) => (r.type === "run.activity" ? liveOf(this.ctx).activity(r.line) : this.turnId && this.announce(this.turnId, [upsertStep(this.sql, this.turnId, r.step, Date.now())])))],
        hooks: [
          hook(GenerationTask, {
            beforeRequest: async ({ messages }, api) => {
              const agent = (liveOf(this.ctx).request(String(api.taskId)), this.config().agent)
              if (this.turnConversation && agent) void typing(this.env, this.turnConversation, agent, true)
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
        const set = this.config().compactor_model
        const name = compactorModel(this.env, set, this.env.CHIEF_BRAIN_FALLBACK_MODEL || FAKE)
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
    for (const r of this.sql.exec<{ id: string }>(`SELECT id FROM cb_turn WHERE post = 'pending'`).toArray()) void this.postAndSchedule(r.id)
    if (!this.memory.settled()) await this.schedule("compact", "compact", Date.now() + RETRY_MS)
  }

  // ------------------------------------------------------------------ settings object (name = agent)

  private defaults() {
    const fallback = this.env.CHIEF_BRAIN_FALLBACK_MODEL || FAKE
    return { model: this.env.CHIEF_BRAIN_MODEL || FAKE, compactor_model: compactorDefault(this.env, this.env.CHIEF_BRAIN_MODEL || FAKE, fallback) }
  }
  config(): BrainConfig {
    return readConfig(this.sql, this.defaults())
  }

  /** Holder object (name HOLDER) only: the metered Claude route's sign-in, refreshed in this object's storage; one refresh at a time. */
  async claudeAuth(): Promise<string> {
    if (!this.authing) {
      this.authing = holderAuth(this.env, this.sql).finally(() => (this.authing = undefined))
      this.authing.catch(() => undefined)
    }
    return this.authing
  }
  /** Holder only: one Claude turn of `owner` (allow-list, daily cap for the whole deployment). */
  async claudeTurn(owner: string, model?: string): Promise<string> { return holderTurn(this.env, this.sql, owner, model) }
  /** Holder only: the route answered 401, so the stored access token goes. */
  async claudeInvalidate(): Promise<void> { holderInvalidate(this.sql) }
  /** Conversation brain: a per-run gateway token's revoke check and spend cap (model-gateway/run-ledger.ts). */
  async runToken(run: string, jti: string, cap: number, o: LedgerOp): Promise<LedgerAnswer> { return runLedger(this.sql, run, jti, cap, o) }
  private holder = () => this.env.CHIEF_BRAIN_DO.get(this.env.CHIEF_BRAIN_DO.idFromName(HOLDER))

  /** The owner's settings (the Worker checked the caller owns `agent`). Turning it on needs a live chief that no server runs. */
  async configure(agent: string, owner: string, patch: ConfigPatch): Promise<{ ok: true; config: BrainConfig } | { ok: false; code: string; message: string }> {
    await this.lifecycle.start()
    const cur = this.config()
    if ((cur.agent !== null && cur.agent !== agent) || (cur.owner !== null && cur.owner !== owner)) return { ok: false, code: "auth.forbidden", message: "this brain belongs to another chief" }
    const invalid = patchError(patch, validModelName)
    if (invalid) return { ok: false, code: "validation.invalid", message: invalid }
    // Claude bills one person's metered account: allowed owners only, and never for background compaction.
    const refused = modelRefusal(this.env, owner, patch)
    if (refused) return refused
    if (patch.enabled === true) {
      const record = await chiefRecord(this.env, owner, agent)
      if (!record) return { ok: false, code: "chief_archived", message: "the chief is archived or unknown" }
      if (record.brain_place) return { ok: false, code: "chief_placed", message: "a paired server runs this chief; remove its brain place first" }
    }
    writeConfig(this.sql, { agent, owner, ...(patch.enabled === undefined ? {} : { enabled: patch.enabled ? "1" : "0" }), ...(patch.chiefs === undefined ? {} : { chiefs: patch.chiefs ? "1" : "0" }) })
    writeConfig(this.sql, { model: patch.model, effort: patch.effort, compactor_model: patch.compactor_model, role: patch.role, personality: patch.personality, instructions: patch.instructions })
    return { ok: true, config: this.config() }
  }

  async status(): Promise<{ config: BrainConfig; turns_today: number }> {
    await this.lifecycle.start()
    const day = new Date().toISOString().slice(0, 10)
    return { config: this.config(), turns_today: Number(this.sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = ?`, `turns:${day}`).toArray()[0]?.value ?? 0) }
  }

  /** A brain asks before a turn (`turn: true` counts it) or a post: enabled, the chief live and not placed, under the daily limit. */
  async admit(agent: string, owner: string, turn: boolean): Promise<Admission> {
    await this.lifecycle.start()
    const cfg = this.config()
    if (!cfg.enabled) return { ok: false, reason: "disabled" }
    if (cfg.agent !== agent || cfg.owner !== owner) return { ok: false, reason: "other_chief" }
    const record = await chiefRecordFresh(this.env, owner, agent).catch(() => undefined)
    if (record === undefined) return { ok: false, reason: "owner.unreachable" }
    if (!record) return { ok: false, reason: "chief_archived" }
    if (record.brain_place) return { ok: false, reason: "chief_placed" }
    if (record.display_name !== cfg.display_name) writeConfig(this.sql, { display_name: record.display_name })
    const credits = turn ? await creditsCanStart(this.env, cfg) : "ok"
    if (credits !== "ok") return { ok: false, reason: credits === "exhausted" ? "credits_exhausted" : "owner.unreachable" }
    if (turn) {
      const key = `turns:${new Date().toISOString().slice(0, 10)}`
      const used = Number(this.sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = ?`, key).toArray()[0]?.value ?? 0)
      if (used >= (Number(this.env.CHIEF_BRAIN_DAILY_TURNS) || DEFAULT_DAILY_TURNS)) return { ok: false, reason: "daily_turn_limit" }
      writeConfig(this.sql, { [key]: String(used + 1) })
    }
    return { ok: true, config: this.config() }
  }

  // ------------------------------------------------------------------ conversation brain (name = agent/conversation)

  private settingsOf(agent: string) {
    return this.env.CHIEF_BRAIN_DO.get(this.env.CHIEF_BRAIN_DO.idFromName(agent))
  }

  /** Asks the settings object and keeps its answer as this brain's config copy. */
  private async admitted(agent: string, owner: string, turn: boolean): Promise<Admission> {
    const a = (await this.settingsOf(agent).admit(agent, owner, turn)) as Admission
    if (a.ok) {
      const { agent: ag, owner: ow, enabled, chiefs, ...rest } = a.config
      writeConfig(this.sql, { agent: ag ?? undefined, owner: ow ?? undefined, enabled: enabled ? "1" : "0", chiefs: chiefs ? "1" : "0", ...rest })
    }
    return a
  }

  /** A run with its steps after `afterSeq`, or null. The Worker checked the caller is a member of this brain's conversation first. */
  async run(id: string, afterSeq = 0, limit = 500): Promise<{ run: Run; steps: Array<Step>; has_more: boolean } | null> {
    await this.lifecycle.start()
    const agent = this.config().agent
    const run = agent ? readRun(this.sql, agent, id) : null
    if (!run) return null
    const steps = readSteps(this.sql, id, afterSeq, limit + 1)
    return { run, steps: steps.slice(0, limit), has_more: steps.length > limit }
  }

  /** This brain's runs, newest first (the Worker checked membership first). */
  async runs(conversation: string, before: number | undefined, limit: number): Promise<{ runs: Array<Run>; has_more: boolean }> {
    await this.lifecycle.start()
    const agent = this.config().agent
    return agent ? readRuns(this.sql, agent, conversation, before, limit) : { runs: [], has_more: false }
  }

  /** MuxDO forwards a committed wake here. Pulls the conversation's new messages as the chief and starts a turn. */
  async wake(w: { agent: string; owner: string; conversation: string; seq: number; reason: string }): Promise<{ queued: number } | { skipped: string }> {
    await (this.lifecycle.start(), markPending(this.sql, "wake"))
    const a = await this.admitted(w.agent, w.owner, false)
    if (!a.ok) return { skipped: a.reason }
    const view = await readConversation(this.env, w.conversation, chiefPrincipal(w.agent, w.owner))
    if ("refused" in view) return { skipped: view.refused }
    // A conversation this brain never read starts at the wake: older history is not answered.
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
    // The woken message (it may have come in as context with an earlier wake).
    this.sql.exec(`UPDATE cb_inbox SET woke = 1 WHERE conversation = ? AND seq = ? AND state = 'queued'`, w.conversation, w.seq)
    this.sql.exec(`INSERT INTO cb_cursor (conversation, seq) VALUES (?, ?) ON CONFLICT (conversation) DO UPDATE SET seq = MAX(seq, excluded.seq)`, w.conversation, top)
    if (queued === 0 && top > cursor) await ackWake(this.env, w.agent, chiefPrincipal(w.agent, w.owner), w.conversation, top).catch(() => undefined)
    // A message that comes in while this conversation's turn runs joins that turn after its current
    // model or tool step (spec 7), instead of waiting for the turn to end.
    if (queued > 0 && this.turnLive && this.turnId && this.turnConversation === w.conversation) await this.steerQueued(w.conversation)
    this.kick()
    return { queued }
  }

  /**
   * Logs the conversation's queued messages of the turn's thread into the running turn and gives them
   * to it (pi steer, after its current step). The op is recorded (memory and storage) before anything
   * awaits, so the turn's wait loop and a restart both see it; a failed steer puts the rows back.
   */
  private async steerQueued(conversation: string): Promise<void> {
    const turn = this.turnId
    if (!turn || !this.turnLive) return
    const root = this.sql.exec<{ r: string | null }>(`SELECT trigger_thread_root AS r FROM cb_turn WHERE id = ?`, turn).toArray()[0]?.r ?? null
    // Only the turn's own thread joins it (its reply goes there); other threads wait for their own turn.
    const rows = this.sql.exec<{ n: number; message: string; seq: number; text: string }>(`SELECT n, message, seq, text FROM cb_inbox WHERE state = 'queued' AND conversation = ? AND thread_root IS ? ORDER BY n`, conversation, root).toArray()
    if (rows.length === 0) return
    const op = `${turn}:steer:${rows[0]!.n}`
    const text = rows.map((r) => r.text).join("\n\n")
    const before = this.sql.exec<{ s: number }>(`SELECT last_seq AS s FROM cb_turn WHERE id = ?`, turn).one().s
    this.ctx.storage.transactionSync(() => {
      for (const r of rows) {
        this.sql.exec(`INSERT INTO oc_logged (key) VALUES (?) ON CONFLICT DO NOTHING`, `user:${r.message}`)
        this.memory.append("user", r.text)
        this.sql.exec(`UPDATE cb_inbox SET state = 'running', turn = ? WHERE n = ?`, turn, r.n)
      }
      this.sql.exec(`UPDATE cb_turn SET last_seq = MAX(last_seq, ?) WHERE id = ?`, Math.max(...rows.map((r) => r.seq)), turn)
      writeConfig(this.sql, { [`steer:${turn}`]: JSON.stringify([...this.steerOps(turn), { op, text }]) })
    })
    this.steered.push(op)
    this.compactor.pump()
    try {
      await this.harness.session().steer([{ type: "text" as const, text }], { operationId: op })
    } catch (e) {
      console.warn(JSON.stringify({ msg: "chief_brain.steer_failed", run: turn, error: String(e).slice(0, 200) }))
      // Not given to pi: the rows wait for the next turn, and the turn's ack range is as before.
      this.steered = this.steered.filter((x) => x !== op)
      writeConfig(this.sql, { [`steer:${turn}`]: JSON.stringify(this.steerOps(turn).filter((x) => x.op !== op)) })
      this.sql.exec(`UPDATE cb_inbox SET state = 'queued', turn = NULL WHERE turn = ? AND n >= ? AND n <= ?`, turn, rows[0]!.n, rows[rows.length - 1]!.n)
      this.sql.exec(`UPDATE cb_turn SET last_seq = ? WHERE id = ?`, before, turn)
    }
  }

  /** The joined operations of `turn`, as stored (restart: the turn waits for them and gives pi any it never got). */
  private steerOps(turn: string): Array<{ op: string; text: string }> {
    const v = this.sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = ?`, `steer:${turn}`).toArray()[0]?.value
    return v ? (JSON.parse(v) as Array<{ op: string; text: string }>) : []
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
    if (agent && run) this.ctx.waitUntil(liveOf(this.ctx).after(() => runChanged(this.env, run.conversation, agent, run, steps))) // behind the live frames
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
    let failed = false
    this.draining = this.drain()
      .catch((e: unknown) => void (failed = true, console.error(JSON.stringify({ msg: "chief_brain.drain_failed", error: String(e).slice(0, 300) }))))
      .finally(() => {
        this.draining = undefined
        // A wake that queued rows while the drain was ending saw it still running: look again (after a failure, later).
        if (this.sql.exec(`SELECT 1 FROM cb_inbox WHERE state = 'queued' AND woke = 1 LIMIT 1`).toArray().length === 0) return
        if (failed) void this.schedule("drain", "drain", Date.now() + RETRY_MS)
        else this.kick()
      })
    this.ctx.waitUntil(this.draining)
  }

  private async drain(): Promise<void> {
    for (;;) {
      const running = this.sql.exec<{ turn: string }>(`SELECT turn FROM cb_inbox WHERE state = 'running' ORDER BY n LIMIT 1`).toArray()[0]
      if (running) {
        await this.runTurn(running.turn)
        continue
      }
      // Only a woken message starts a turn; the messages before it ride along as context.
      const woken = this.sql.exec<{ conversation: string }>(`SELECT conversation FROM cb_inbox WHERE state = 'queued' AND woke = 1 ORDER BY n LIMIT 1`).toArray()[0]
      if (!woken) return
      const cfg = this.config()
      const a = cfg.agent && cfg.owner ? await this.admitted(cfg.agent, cfg.owner, true).catch((): Admission => ({ ok: false, reason: "owner.unreachable" })) : ({ ok: false, reason: "unbound" } as Admission)
      const rows = this.sql
        .exec<{ n: number; message: string; seq: number; kind: string; thread_root: string | null; text: string; woke: number }>(`SELECT n, message, seq, kind, thread_root, text, woke FROM cb_inbox WHERE state = 'queued' AND conversation = ? ORDER BY n`, woken.conversation)
        .toArray()
      if (!a.ok && a.reason === "owner.unreachable") return void (await this.schedule("drain", "drain", Date.now() + RETRY_MS))
      if (!a.ok) {
        // Not answered (off, archived, placed, over the limit): the wakes are acked so the queue stays bounded.
        this.sql.exec(`UPDATE cb_inbox SET state = 'skipped' WHERE state = 'queued' AND conversation = ?`, woken.conversation)
        console.warn(JSON.stringify({ msg: "chief_brain.turn_refused", reason: a.reason }))
        if (a.reason === "credits_exhausted") await creditsNotice(this.env, cfg, woken.conversation)
        if (cfg.agent && cfg.owner && rows.length > 0) await ackWake(this.env, cfg.agent, chiefPrincipal(cfg.agent, cfg.owner), woken.conversation, Math.max(...rows.map((r) => r.seq))).catch(() => undefined)
        continue
      }
      await (markPending(this.sql, "admitted"), (this.memory.foldDue() ? this.compactor.settle(AbortSignal.timeout(SETTLE_MS)) : Promise.resolve(true)).finally(() => markPending(this.sql, "settled")))
      if (rows.length > 0) this.openTurn(woken.conversation, rows)
    }
  }

  /** Logs the new messages, then builds the cache-stable input (frozen view + delta, OptChat 5a) with the turn row in one transaction (a restart resubmits the same bytes). */
  private openTurn(conversation: string, rows: ReadonlyArray<{ n: number; message: string; seq: number; kind: string; thread_root: string | null; text: string; woke: number }>): void {
    const id = `run_${rows[0]!.n}`
    let input = "[]"
    const trigger = [...rows].reverse().find((r) => r.woke === 1) ?? rows[rows.length - 1]!
    this.ctx.storage.transactionSync(() => {
      for (const r of rows) {
        this.sql.exec(`INSERT INTO oc_logged (key) VALUES (?) ON CONFLICT DO NOTHING`, `user:${r.message}`)
        this.memory.append("user", r.text)
        this.sql.exec(`UPDATE cb_inbox SET state = 'running', turn = ? WHERE n = ?`, id, r.n)
      }
      input = JSON.stringify(this.memory.turnInput(rows.length))
      this.sql.exec(
        `INSERT INTO cb_turn (id, conversation, trigger_message, trigger_kind, trigger_thread_root, last_seq, status, model, started, input) VALUES (?, ?, ?, ?, ?, ?, 'running', ?, ?, ?)`,
        id, conversation, trigger.message, trigger.kind, trigger.thread_root, Math.max(...rows.map((r) => r.seq)), this.config().model, Date.now(), input
      )
    })
    this.compactor.pump()
    this.announce(id, (flushMarks(this.sql, id), []))
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
    let timer: ReturnType<typeof setTimeout> | undefined
    try {
      if (!row.submitted) {
        const blocks = JSON.parse(row.input ?? "[]") as Array<string>
        // A paid model: an allowed owner, the route serves it, under the deployment's cap, with the route's sign-in; else the fallback, which passes the same gate when it is paid; else no turn.
        const owner = this.config().owner ?? ""
        const picked = await pickTurnModel(row.model, this.env.CHIEF_BRAIN_FALLBACK_MODEL, (m) => this.holder().claudeTurn(owner, m).then((v) => (v !== "ok" || !isClaude(m) ? v : this.holder().claudeAuth().then(() => "ok", () => "auth_failed"))).catch(() => "holder_unreachable"))
        if (picked.reason) console.warn(picked.reason.includes("auth_failed") ? AUTH_FAILED : JSON.stringify({ msg: "chief_brain.paid_model_refused", reason: picked.reason }))
        if (picked.model === null || picked.model !== row.model) [this.announce(id, [upsertStep(this.sql, id, { id: "note:model", kind: "note", text: picked.model === null ? `No model ran: ${picked.reason}` : `${picked.reason}; this turn runs on ${picked.model}` }, Date.now())]), picked.model === null ? (() => { throw new Error(`paid model refused (${picked.reason})`) })() : [(row.model = picked.model), this.sql.exec(`UPDATE cb_turn SET model = ? WHERE id = ?`, row.model, id)]]
        const model = this.models.model(row.model)
        const root = await (await this.harness.pi()).root(BACKGROUND_CONTEXT)
        await root.configure({ model: { provider: model.provider, modelId: model.id }, thinkingLevel: this.models.thinking(row.model) }, BACKGROUND_CONTEXT)
        // A fresh context every turn: the model sees the view, the new messages and its own tool loop.
        // The previous turns' pi entries are never read again (each turn starts a fresh context): pruned when allowed.
        if (this.env.CHIEF_BRAIN_PRUNE_PI === "1") {
          const p = prunePiEntries(this.sql)
          if (p.deleted > 0 || p.skipped.length > 0) console.log(JSON.stringify({ msg: "chief_brain.pi_pruned", run: id, deleted: p.deleted, skipped: p.skipped.slice(0, 3) }))
        }
        await this.harness.session().reset()
        this.sql.exec(`UPDATE cb_turn SET submitted = 1 WHERE id = ?`, id)
        await this.harness.submit(blocks.map((text) => ({ type: "text" as const, text })), { operationId: id })
      }
      const limit = new Promise<"timeout">((r) => (timer = setTimeout(() => r("timeout"), TURN_MS)))
      this.turnLive = true
      // After a restart: the ops that joined this turn before (pi takes a repeated operation id once).
      for (const s of this.steerOps(id)) [this.steered.push(s.op), await this.harness.session().steer([{ type: "text" as const, text: s.text }], { operationId: s.op }).catch(() => undefined)]
      let result = await Promise.race([this.harness.wait(id), limit])
      // Messages that joined the turn: wait for them as well (one that came after the last step runs on, under this turn).
      for (let i = 0; i < this.steered.length && result !== "timeout"; i++) {
        const joined = await Promise.race([this.harness.wait(this.steered[i]!), limit])
        if (joined === "timeout" || joined.status !== "done") result = joined
      }
      // No message joins from here on: the next one starts its own turn.
      this.turnLive = false
      if (result === "timeout") {
        for (const op of [id, ...this.steered]) void this.harness.abort({ operationId: op }).catch(() => undefined)
        reason = "timeout"
      } else {
        ok = result.status === "done"
        reason = ok ? null : (result.reason ?? "unknown")
      }
    } catch (e) {
      reason = e instanceof Error ? e.message : String(e)
    } finally {
      clearTimeout(timer)
      this.turnLive = false
      this.steered = []
      this.sql.exec(`DELETE FROM cb_config WHERE name = ?`, `steer:${id}`)
      this.turnId = undefined
      this.turnConversation = undefined
    }
    const reply = ok ? lastTalk(this.sql, id) : ""
    const post = !ok ? "none" : reply === "" || isNoReply(reply) ? "no_reply" : "pending"
    this.sql.exec(`UPDATE cb_turn SET status = ?, reason = ?, ended = ?, input = NULL, reply = ?, post = ? WHERE id = ?`, ok ? "done" : "failed", reason, Date.now(), post === "pending" ? clipReply(reply) : null, post, id)
    this.sql.exec(`UPDATE cb_inbox SET state = ? WHERE turn = ?`, ok ? "done" : "failed", id)
    if (!ok) [console.warn(JSON.stringify({ msg: "chief_brain.turn_failed", run: id, reason: String(reason).slice(0, 300), error: runError(this.sql, id)?.slice(0, 300) })), await turnFailedNotice(this.env, this.sql, this.config(), row.conversation, id, String(reason), runError(this.sql, id))]
    this.announce(id, [])
    if (post === "pending") await this.postAndSchedule(id)
    else await this.finish(id)
    if (!this.memory.settled()) await this.schedule("compact", "compact", Date.now() + RETRY_MS)
  }

  private async postAndSchedule(id: string): Promise<void> {
    const next = await liveOf(this.ctx).after(async () => undefined).then(() => this.post(id)) // the final delta and the run end reach members before the reply
    if (next !== null) await this.schedule(`post:${id}`, "post", next)
  }

  /**
   * Posts the run's reply as the chief. Returns when to try again (the loop guard's agent_rate, or no
   * answer), or null when done; done acks the wakes.
   */
  private async post(id: string): Promise<number | null> {
    if (this.posting.has(id)) return null
    this.posting.add(id)
    try {
      const t = this.sql.exec<{ conversation: string; trigger_message: string; trigger_kind: string; trigger_thread_root: string | null; reply: string | null; post: string; post_tries: number; post_key: number }>(`SELECT conversation, trigger_message, trigger_kind, trigger_thread_root, reply, post, post_tries, post_key FROM cb_turn WHERE id = ?`, id).toArray()[0]
      const cfg = this.config()
      if (!t || t.post !== "pending" || !t.reply || !cfg.agent || !cfg.owner) return null
      // The chief may have been archived or placed on a server since the turn began.
      const a = await this.admitted(cfg.agent, cfg.owner, false).catch((): Admission => ({ ok: false, reason: "owner.unreachable" }))
      const steps = Number(this.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM cb_step WHERE turn = ?`, id).one().n)
      // The ledger replays a refusal under the same key, so a refused try's retry needs a new key (the
      // key is also the client message id); an unknown outcome (no answer) retries under the same key.
      const key = `chief-reply:${cfg.agent}:${id}:${t.post_key}`
      const res = !a.ok
        ? { ok: false as const, code: a.reason, message: a.reason }
        : await postReply(this.env, chiefPrincipal(cfg.agent, cfg.owner), { conversation: t.conversation, text: t.reply, run: { id, host: `${HOST}:${cfg.agent}`, steps }, ...replyTarget(t.trigger_kind, t.trigger_message, t.trigger_thread_root), key }).catch(
            (e: unknown) => ({ ok: false as const, code: "owner.unreachable", message: String(e) })
          )
      if (!res.ok && (res.code === "agent_rate" || res.code === "owner.unreachable") && t.post_tries + 1 < MAX_POST_TRIES) {
        this.sql.exec(`UPDATE cb_turn SET post_tries = post_tries + 1, post_key = post_key + ? WHERE id = ?`, res.code === "agent_rate" ? 1 : 0, id)
        return Date.now() + POST_RETRY_MS
      }
      if (res.ok) this.sql.exec(`UPDATE cb_turn SET post = 'posted', posted_message = ?, turn_key = ? WHERE id = ?`, res.message, key, id)
      else this.sql.exec(`UPDATE cb_turn SET post = 'refused', reason = ? WHERE id = ?`, res.code, id)
      this.announce(id, [])
      await this.finish(id)
      return null
    } finally {
      this.posting.delete(id)
    }
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

  /** Lifecycle wakes the object for due jobs, also after an eviction. A post retry reschedules itself through the outcome. */
  async onJob({ job }: LifecycleJobContext): Promise<LifecycleJobOutcome | void> {
    if (job.fn === "post") {
      const next = await this.post(String(job.id).slice("post:".length))
      return next === null ? undefined : { rescheduleAt: next }
    }
    if (job.fn === "drain") return void this.kick()
    if (job.fn !== "compact") return
    this.compactor.pump()
    if (!(await this.compactor.settle(AbortSignal.timeout(60_000)))) return { rescheduleAt: Date.now() + RETRY_MS }
  }
}
