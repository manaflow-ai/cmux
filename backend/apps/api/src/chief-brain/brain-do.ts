import { DurableObject } from "cloudflare:workers"
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context"
import type { AssistantMessage } from "@earendil-works/pi-ai"
import { createRegistry, GenerationTask, Harness, hook, section, ToolTask } from "@earendil-works/pi-durable"
import { PiHarness } from "agents/harness/pi"
import { Lifecycle, type LifecycleJobContext, type LifecycleJobOutcome } from "agents/lifecycle"
import type { Env } from "../env.ts"
import { assertFaultHooks } from "../chief-fault.ts"
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
import { handsEntryTool, hasHand } from "./brain-hands.ts"
import { chiefsTools } from "./brain-chiefs.ts"
import { type ChildStart, childInput, childKey, childObject, childPrompt, childRunId, postReports, readChild, slotCounts, slotEnqueue, slotPump, SPAWN_SCHEMA, CHILD_LOST_MS, spawnMax, spawnTool, subagentActivity, takeReport, turnThread } from "./brain-spawn.ts"

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
  readonly models = brainModels(this.env, this.ctx.id.toString(), { claude: { auth: () => this.holder().claudeAuth(), refused: () => this.holder().claudeInvalidate() }, effort: () => this.config().effort, ...gatewayOptions(this.ctx, this.env, () => ({ run: this.turnId, conversation: this.turnConversation, config: this.config(), live: !this.childOf() })) })
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
  /** Child role (brain-spawn.ts): the start payload, read once from cb_config `spawn`. */
  private child: ChildStart | null | undefined
  private reporting: Promise<void> | undefined
  private reportAgain = false
  private subsChain: Promise<void> = Promise.resolve()

  readonly harness = new PiHarness({
    harness: ({ storage, context }) => {
      this.registry.install({
        name: "chief",
        sections: [section("chief", () => (this.childOf() ? childPrompt(this.childOf()!) : systemPrompt(this.config())), { tag: false })],
        // A child (subagent) gets hands only: no memory, no Chief management, no spawn (one level deep).
        // Hands come from the "chief-hands" extension (installHands): full, or a compact entry until a hand exists.
        tools: this.childOf() ? [] : [...memoryTools(() => this.memory), ...chiefsTools(this.env, () => this.config()), spawnTool(this.spawnHost())],
        hooks: [
          hook(GenerationTask, {
            beforeRequest: async ({ messages }, api) => {
              const agent = (liveOf(this.ctx).request(String(api.taskId)), this.config().agent)
              if (this.turnConversation && agent && !this.childOf()) void typing(this.env, this.turnConversation, agent, true)
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
      this.installHands()
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
    for (const q of [...SCHEMA, ...SPAWN_SCHEMA]) this.sql.exec(q)
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
    if (this.sql.exec(`SELECT 1 FROM cb_spawn WHERE posted = 0 LIMIT 1`).toArray().length > 0) void this.deliverReports()
    if (this.sql.exec(`SELECT 1 FROM cb_spawn_slot LIMIT 1`).toArray().length > 0) void this.pumpSlots()
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

  /** Test-only (chief-fault.ts, CHIEF_FAULT_HOOKS, never staging or production): abort this object as an eviction does. */
  async fault(): Promise<void> {
    assertFaultHooks(this.env)
    this.ctx.abort("chief fault hook: evict")
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
    // A subagent run is read only from a started child: a read never opens a child before its task (its tools come from its role).
    if (id.startsWith("sub_") && !readChild(this.sql)) return null
    await this.lifecycle.start()
    const agent = this.config().agent
    const run = agent ? readRun(this.sql, agent, id) : null
    if (!run) return null
    const steps = readSteps(this.sql, id, afterSeq, limit + 1)
    return { run, steps: steps.slice(0, limit), has_more: steps.length > limit }
  }

  /** Parent brain: did it spawn child `n` (the runs route asks before it reaches a child object). */
  async spawned(n: number): Promise<boolean> {
    return this.sql.exec(`SELECT 1 FROM cb_spawn WHERE n = ?`, n).toArray().length > 0
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
    const t = this.sql.exec<{ m: string; k: string; r: string | null }>(`SELECT trigger_message AS m, trigger_kind AS k, trigger_thread_root AS r FROM cb_turn WHERE id = ?`, turn).toArray()[0]
    const root = t?.r ?? null
    // Only the turn's own thread joins it (its reply goes there; a subagent report names that thread); other threads wait for their own turn.
    const rows = this.sql.exec<{ n: number; message: string; seq: number; text: string }>(`SELECT n, message, seq, text FROM cb_inbox WHERE state = 'queued' AND conversation = ? AND (thread_root IS ? OR thread_root IS ?) ORDER BY n`, conversation, root, t ? turnThread(t.k, t.m, root) : root).toArray()
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
      // A child never reads a memory view: no log, no compactor calls.
      if (!this.childOf()) this.memory.append(kind, text)
      if (turn && step) changed = upsertStep(this.sql, turn, step, Date.now())
      logged = true
    })
    if (logged && !this.childOf()) this.compactor.pump()
    if (turn && changed) this.announce(turn, [changed])
  }

  /** `conversation-run-changed` for the run's conversation (the run summary and the steps that changed). */
  private announce(turn: string, steps: ReadonlyArray<Step>): void {
    // A subagent run is not shown live as a Chief run (its card and the runs route show it).
    if (this.childOf()) return
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
    const child = this.childOf()
    if (child) {
      const r = this.sql.exec<{ id: string; submitted: number }>(`SELECT id, submitted FROM cb_turn WHERE status = 'running' LIMIT 1`).toArray()[0]
      if (!r) return
      // Admitted once (a daily turn counted once, also across an eviction); an unreachable owner retries later.
      if (!r.submitted && !this.sql.exec(`SELECT 1 FROM cb_config WHERE name = 'spawn.admitted'`).toArray().length) {
        const refused = await this.childAdmit(child)
        if (refused === "owner.unreachable") return void (await this.schedule("drain", "drain", Date.now() + RETRY_MS))
        if (refused) return this.childEnd(r.id, false, refused)
        writeConfig(this.sql, { "spawn.admitted": "1" })
      }
      return this.runTurn(r.id)
    }
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
    const child = this.childOf()
    if (agent && !child) void typing(this.env, row.conversation, agent, true)
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
        // The tool set is fixed here for the whole turn (from the last check); the next check runs off the hot path
        // and takes effect at the next turn boundary.
        this.startTurnHands()
        this.ctx.waitUntil(this.refreshHands().catch(() => undefined))
        await this.harness.submit(blocks.map((text) => ({ type: "text" as const, text })), { operationId: id })
      }
      // A child's bound runs from its start, across restarts (its slot frees after SLOT_STALE_MS).
      const left = child ? Math.max(1_000, Number(this.sql.exec<{ s: number }>(`SELECT started AS s FROM cb_turn WHERE id = ?`, id).one().s) + TURN_MS - Date.now()) : TURN_MS
      const limit = new Promise<"timeout">((r) => (timer = setTimeout(() => r("timeout"), left)))
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
    if (child) return this.childEnd(id, ok, reason)
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
      if (this.childOf()) return await this.childReport(id)
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

  // ------------------------------------------------------------------ subagents (brain-spawn.ts)

  /** The start payload when this object is a child (subagent), else null. */
  private childOf(): ChildStart | null {
    if (this.child === undefined) this.child = readChild(this.sql)
    return this.child
  }

  /**
   * The hands tools as their own extension: the full `hands` + `agent` pair when the Chief has a hand (or is a
   * child, which works on hands), else one compact `hands` entry (list, pair_code, new_sandbox): about 1.8k fewer
   * input tokens per request for a Chief with no hand, without losing the way to get one. The set changes only at a
   * turn boundary (startTurnHands): after new_sandbox or pairing, the next turn has the full tools.
   */
  private installHands(): void {
    const v = (k: string) => this.sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = ?`, k).toArray()[0]?.value
    // The tools are fixed for a whole turn (a model signs its thinking for the tools list; a change inside the
    // turn makes the next request a 400). The running turn's mode wins, also when the object opens again mid-turn.
    const full = this.childOf() !== null || (v("hands_turn_mode") ?? v("hands_full")) === "1"
    this.registry.install({ name: "chief-hands", tools: full ? [...this.hands()] : [handsEntryTool(this.env, () => ({ ...this.config() }), () => this.refreshHands())] })
  }

  /** At a turn boundary only: this turn's hands mode (full once a hand was found), recorded for the whole turn. */
  private startTurnHands(): void {
    const full = this.sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = 'hands_full'`).toArray()[0]?.value === "1"
    writeConfig(this.sql, { hands_turn_mode: full ? "1" : "0" })
    this.installHands()
  }

  /** Checks for a hand (one list call) and records it; the full tools come at the next turn boundary, never inside a turn. */
  private async refreshHands(): Promise<void> {
    if (this.childOf() !== null || this.sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = 'hands_full'`).toArray()[0]?.value === "1") return
    if (!(await hasHand(this.env, () => ({ ...this.config() })))) return
    writeConfig(this.sql, { hands_full: "1" })
  }

  /** The hands tools; a child's caller and agent tokens name its own object (`<conversation>:spawn:<n>`), so a hand's session-end revoke reaches it. */
  private hands() {
    const c = this.childOf()
    return handsTools(this.env, () => ({ ...this.config(), run: this.turnId, conversation: c ? childKey(c.conversation, c.n) : this.turnConversation, ledger: (jti: string, o: LedgerOp) => runLedger(this.sql, this.turnId ?? "", jti, 0, o) }), (r) => (r.type === "run.activity" ? liveOf(this.ctx).activity(r.line) : this.turnId && this.announce(this.turnId, [upsertStep(this.sql, this.turnId, r.step, Date.now())])))
  }

  private spawnHost() {
    return {
      env: this.env,
      sql: this.sql,
      transaction: (f: () => void) => this.ctx.storage.transactionSync(f),
      turn: () => (this.turnId && this.turnConversation ? { run: this.turnId, conversation: this.turnConversation } : undefined),
      config: () => this.config(),
      isChild: () => this.childOf() !== null,
      enqueue: (items: ReadonlyArray<ChildStart>) => this.settingsOf(items[0]!.agent).spawnEnqueue(items[0]!.agent, items[0]!.owner, [...items]) as Promise<{ running: number; waiting: number }>,
      changed: (conversation: string) => {
        this.subsChanged(conversation)
        // The lost-child check runs even when no report ever comes.
        void this.schedule("spawn-post", "spawn-post", Date.now() + CHILD_LOST_MS + 60_000)
      }
    }
  }

  /** Settings object: queue children; at most CHIEF_SPAWN_MAX of this Chief's children run at once. */
  async spawnEnqueue(agent: string, owner: string, items: Array<ChildStart>): Promise<{ running: number; waiting: number }> {
    await this.lifecycle.start()
    const cfg = this.config()
    if (cfg.agent !== agent || cfg.owner !== owner || items.some((s) => s.agent !== agent || s.owner !== owner)) throw new Error("spawn: another chief's settings")
    slotEnqueue(this.sql, items, Date.now())
    await this.pumpSlots()
    return slotCounts(this.sql)
  }

  /** Settings object: a child reported; its slot frees and the next waiting child starts. */
  async spawnDone(child: string): Promise<void> {
    await this.lifecycle.start()
    this.sql.exec(`DELETE FROM cb_spawn_slot WHERE child = ?`, child)
    await this.pumpSlots()
  }

  private async pumpSlots(): Promise<void> {
    const at = await slotPump(this.sql, this.env, spawnMax(this.env))
    if (at !== null) await this.schedule("spawn-pump", "spawn-pump", at)
  }

  /** Child object: take the task (once) and run it. `ended`: this child already reported (a repeated start). */
  async spawnStart(s: ChildStart): Promise<{ ended: boolean }> {
    const id = childRunId(s.n)
    if (!readChild(this.sql)) {
      // Before the lifecycle starts: the harness opens with the child's tools and prompt.
      this.ctx.storage.transactionSync(() => {
        writeConfig(this.sql, { spawn: JSON.stringify(s), agent: s.agent, owner: s.owner, enabled: "1", model: s.model, effort: s.effort, display_name: s.display_name })
        this.sql.exec(`INSERT INTO cb_turn (id, conversation, trigger_message, trigger_kind, trigger_thread_root, last_seq, status, model, started, input) VALUES (?, ?, ?, 'spawn', NULL, 0, 'running', ?, ?, ?) ON CONFLICT (id) DO NOTHING`, id, s.conversation, s.parent_run, s.model, Date.now(), JSON.stringify(childInput(s)))
      })
      this.child = undefined
    }
    await this.lifecycle.start()
    const post = this.sql.exec<{ post: string | null }>(`SELECT post FROM cb_turn WHERE id = ?`, id).toArray()[0]?.post ?? null
    this.kick()
    return { ended: post === "reported" || post === "refused" }
  }

  /** Child: the Chief is on, live, under its daily turns, and the team has credits for the child's model (no model call otherwise). */
  private async childAdmit(c: ChildStart): Promise<string | null> {
    const a = (await this.settingsOf(c.agent).admit(c.agent, c.owner, true).catch((): Admission => ({ ok: false, reason: "owner.unreachable" }))) as Admission
    if (!a.ok) return a.reason
    const credits = await creditsCanStart(this.env, { ...this.config(), model: c.model })
    return credits === "ok" ? null : credits === "exhausted" ? "credits_exhausted" : "owner.unreachable"
  }

  /** Child: the run ended; its report (the last talk, or a short failure line with no internal detail) goes to the parent. */
  private async childEnd(id: string, ok: boolean, reason: string | null): Promise<void> {
    const why = String(reason ?? "")
    const talk = ok ? lastTalk(this.sql, id) : ""
    const report = ok
      ? (talk && !isNoReply(talk) ? talk : "(no answer)")
      : /^(disabled|other_chief|chief_archived|chief_placed)$/.test(why)
        ? "I could not do the task: the Chief is off or archived."
        : /credits/i.test(why)
        ? "I could not do the task: this team is out of Cloud credits."
        : /daily_turn_limit|daily_cap/.test(why)
          ? "I could not do the task: the Chief reached today's limit."
          : "I could not finish the task (the model did not answer, or it ran too long)."
    if (!ok) console.warn(JSON.stringify({ msg: "chief_brain.spawn_child_failed", run: id, reason: why.slice(0, 300), error: runError(this.sql, id)?.slice(0, 300) }))
    this.sql.exec(`UPDATE cb_turn SET status = ?, reason = ?, ended = ?, input = NULL, reply = ?, post = 'pending' WHERE id = ?`, ok ? "done" : "failed", reason, Date.now(), clipReply(report), id)
    this.announce(id, [])
    await this.postAndSchedule(id)
  }

  /** Child: hands the report to the parent brain and frees the slot; retried (job) until both answer. */
  private async childReport(id: string): Promise<number | null> {
    const c = this.childOf()
    const t = this.sql.exec<{ status: string; reply: string | null; post: string; post_tries: number }>(`SELECT status, reply, post, post_tries FROM cb_turn WHERE id = ?`, id).toArray()[0]
    if (!c || !t || t.post !== "pending") return null
    const parent = this.env.CHIEF_BRAIN_DO.get(this.env.CHIEF_BRAIN_DO.idFromName(brainName(c.agent, c.conversation)))
    try {
      await parent.spawnReport(c.n, t.status === "done" ? "done" : "failed", t.reply ?? "")
      await this.settingsOf(c.agent).spawnDone(childObject(c.agent, c.conversation, c.n))
      this.sql.exec(`UPDATE cb_turn SET post = 'reported' WHERE id = ?`, id)
      return null
    } catch (e) {
      console.warn(JSON.stringify({ msg: "chief_brain.spawn_report_retry", run: id, tries: t.post_tries, error: String(e).slice(0, 200) }))
      if (t.post_tries >= 30) {
        this.sql.exec(`UPDATE cb_turn SET post = 'refused' WHERE id = ?`, id)
        await this.settingsOf(c.agent).spawnDone(childObject(c.agent, c.conversation, c.n)).catch(() => undefined)
        return null
      }
      this.sql.exec(`UPDATE cb_turn SET post_tries = post_tries + 1 WHERE id = ?`, id)
      return Date.now() + Math.min(60_000, POST_RETRY_MS * 2 ** Math.min(t.post_tries, 5))
    }
  }

  /** Parent brain: a child's report (stored before anything else), then posted and queued. */
  async spawnReport(n: number, status: "done" | "failed", report: string): Promise<{ ok: true }> {
    await this.lifecycle.start()
    takeReport(this.sql, n, status, report, Date.now())
    this.ctx.waitUntil(this.deliverReports())
    return { ok: true }
  }

  /** Parent brain: posts stored reports as work cards and queues them as woken messages (steered into a running turn, or a new turn). */
  private deliverReports(): Promise<void> {
    if (this.reporting) return ((this.reportAgain = true), this.reporting)
    this.reporting = (async () => {
      do {
        this.reportAgain = false
        const cfg = this.config()
        if (!cfg.agent || !cfg.owner) return
        // A child that never reported within CHILD_LOST_MS counts as failed.
        this.sql.exec(`UPDATE cb_spawn SET state = 'failed', report = 'I did not report in time.', ended = ? WHERE state IN ('queued', 'enqueued') AND created < ?`, Date.now(), Date.now() - CHILD_LOST_MS)
        const a = await this.admitted(cfg.agent, cfg.owner, false).catch((): Admission => ({ ok: false, reason: "owner.unreachable" }))
        if (!a.ok && a.reason === "owner.unreachable") return void (await this.schedule("spawn-post", "spawn-post", Date.now() + POST_RETRY_MS))
        // The Chief was turned off, archived or placed: its reports are not posted.
        if (!a.ok) this.sql.exec(`UPDATE cb_spawn SET posted = 1 WHERE posted = 0 AND state IN ('done', 'failed')`)
        const r = a.ok ? await postReports(this.env, this.sql, (f) => this.ctx.storage.transactionSync(f), chiefPrincipal(cfg.agent, cfg.owner), `${HOST}:${cfg.agent}`) : { conversations: new Set<string>(), retry: false }
        if (r.retry) await this.schedule("spawn-post", "spawn-post", Date.now() + POST_RETRY_MS)
        for (const c of r.conversations) if (this.turnLive && this.turnId && this.turnConversation === c) await this.steerQueued(c)
        if (r.conversations.size > 0) this.kick()
        for (const { c } of this.sql.exec<{ c: string }>(`SELECT DISTINCT conversation AS c FROM cb_spawn`).toArray()) this.subsChanged(c)
      } while (this.reportAgain)
    })().finally(() => (this.reporting = undefined))
    return this.reporting
  }

  /** The live "N subagents" line of `conversation` (sent in order). */
  private subsChanged(conversation: string): void {
    const agent = this.config().agent
    if (!agent) return
    this.subsChain = this.subsChain.then(() => subagentActivity(this.env, this.sql, agent, conversation)).catch(() => undefined)
    this.ctx.waitUntil(this.subsChain)
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
    if (job.fn === "spawn-pump") return void (await this.pumpSlots())
    if (job.fn === "spawn-post") return void (await this.deliverReports())
    if (job.fn !== "compact") return
    this.compactor.pump()
    if (!(await this.compactor.settle(AbortSignal.timeout(60_000)))) return { rescheduleAt: Date.now() + RETRY_MS }
  }
}
