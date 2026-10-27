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
import { AUTH_FAILED, claudeAuthFor, forgetClaudeAuth, holderAuth, holderInvalidate, HOLDER, leaseTotal, ownerTurn, turnsObject } from "./claude-auth.ts"
import { Compactor, type CallRecord } from "./compactor.ts"
import { PrefixCache, ttlMs } from "./cache-prefix.ts"
import { prunePiEntries } from "./pi-prune.ts"
import { type LedgerAnswer, type LedgerOp, runLedger } from "../model-gateway/run-ledger.ts"
import { capText, type Kind, Memory, RETRY_MS } from "./memory.ts"
import { brainModel, meteredOwner, opencodeRuns } from "../model-gateway/routes.ts"
import { brainModels, CLAUDE, compactorDefault, compactorModel, creditsCanStart, creditsNotice, FAKE, turnFailedNotice, gatewayOptions, isClaude, isMetered, liveOf, modelRefusal, pickTurnModel, validModelName } from "./models.ts"
import { clipReply, formatMessage, isNoReply, replyTarget, systemFirst, textParts, stripStaleThinking } from "./brain-text.ts"
import { AGENT, systemPrompt } from "./prompts.ts"
import { handsTools, memoryTools } from "./brain-tools.ts"
import { handsEntryTool, hasHand } from "./brain-hands.ts"
import { chiefsTools } from "./brain-chiefs.ts"
import { type ChildStart, childInput, childKey, childObject, childPrompt, childRunId, postReports, readChild, slotCounts, slotEnqueue, slotPump, SPAWN_SCHEMA, CHILD_LOST_MS, archiveAndDrop, childReportText, forwardOutcomes, outcomeWhere, keepMs, turnWhereOf, type AgentOutcome, checkOutcomes, noteAgentCall, postOutcomes, queueOutcome, spawnMax, spawnTool, subagentActivity, takeReport, turnThread } from "./brain-spawn.ts"
import * as sub from "./brain-sub.ts"
import * as turnLoop from "./brain-turn.ts"
import { ccRoute } from "../chief-brain-cc/vm.ts"
import { ccNotes } from "../chief-brain-cc/turn.ts"
import { toolFiles, toolsCall } from "../chief-brain-cc/tools.ts"
import { wakeFire } from "../chief-brain-cc/wake.ts"
import { chiefJobWake, type ChiefJob, type JobDelivery } from "../chief-brain-cc/jobs.ts"
import { githubCall, githubDump, type GithubHost, githubPoll, type GithubStatus, githubTurn } from "../chief-brain-cc/github.ts"
import { ccSandbox, ccSandboxPurge, ccSandboxRetire } from "../chief-brain-cc/sandbox.ts"
import { type AppendBody, type AppendResult, type UndoBody, type UndoResult, IMPORT_SCHEMA, type ImportBody, type ImportFail, type ImportStatus, appendBatch, undoBatch, importBatch, importing, importStatus } from "./memory-import.ts"

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
export const POST_RETRY_MS = 2_500
export const MAX_POST_TRIES = 6
/**
 * The loop guard's 2 s gap is per conversation, for every agent: in a group with several Chiefs (and their
 * subagents' reports) a ready reply can meet agent_rate more than MAX_POST_TRIES times in a row. agent_rate
 * is "wait", never "no": it is retried until this long after the turn ended, then the reply is refused.
 */
export const AGENT_RATE_WINDOW_MS = 120_000
/** Whether a post refused with `code` is tried again (pure, for tests). */
export const retryPost = (code: string, tries: number, endedAt: number | null, now: number): boolean =>
  code === "agent_rate" ? now - (endedAt ?? now) < AGENT_RATE_WINDOW_MS || tries + 1 < MAX_POST_TRIES : code === "owner.unreachable" && tries + 1 < MAX_POST_TRIES
export const HOST = "cloud-chief"
/**
 * A turn waits at most this long for every message before its new ones to be summarized (the reference
 * client's `Memory.settle`, which has no bound), and only while the compactor is healthy (no failing
 * node, no rate-limit wait); otherwise, or after it, the turn runs on the last rendered view plus the
 * unsummarized messages whole (Memory.turnInput, not fresh).
 */
export const SETTLE_MS = 5_000
/** The Claude compactor's effort: CHIEF_BRAIN_COMPACT_EFFORT (staging A/B knob) when it names a level, else "high" (the reference client's). */
const compactEffort = (v: string | undefined): "low" | "medium" | "high" => (v === "low" || v === "medium" ? v : "high")
/** One line per compaction call (stage timing: how long it waited for a prefix another call wrote, then the model call). */
const logCompactCall = (c: CallRecord): void =>
  console.log(JSON.stringify({ msg: "chief_brain.compact_call", node: c.ref, model: c.model, wait_ms: c.waitMs ?? 0, ms: c.latencyMs, stop: c.stop, in: c.usage?.input ?? 0, out: c.usage?.output ?? 0, cr: c.usage?.cacheRead ?? 0, cw: c.usage?.cacheWrite ?? 0, ...(c.error ? { error: c.error.slice(0, 160) } : {}) }))
/** A millisecond setting (CHIEF_BRAIN_SETTLE_MS, CHIEF_BRAIN_PREFIX_WAIT_MS), else `d`. */
export const msOr = (v: string | undefined, d: number): number => (v !== undefined && /^\d{1,9}$/.test(v.trim()) ? Number(v.trim()) : d)
/** A turn that runs longer is stopped and recorded failed. */
export const TURN_MS = 10 * 60_000
const DEFAULT_DAILY_TURNS = 300

export const brainName = (agent: string, conversation: string) => `${agent}/${conversation}`
export type Admission = { readonly ok: true; readonly config: BrainConfig } | { readonly ok: false; readonly reason: string }

export type ConfigPatch = Partial<Pick<BrainConfig, "enabled" | "model" | "effort" | "compactor_model" | "role" | "personality" | "instructions" | "chiefs">>

/** The continuation message after a turn made or found the Chief's first hand (one per run). */
export const HANDS_CONTINUE = "Your new hand is ready, and the full hands and agent tools are now available. Continue the person's request from where you stopped; do not repeat what you already did."

type HandInfo = { hand: string; name: string; online: boolean; vm: boolean }

/** The hand a compact hands step returned (new_sandbox: the new hand; list: the first online one), or null. */
const handOfResult = (action: string, result: string): HandInfo | null => {
  try {
    const v = JSON.parse(result) as unknown
    const pick = (x: { hand?: unknown; name?: unknown; online?: unknown; sandbox?: unknown }): HandInfo | null =>
      typeof x.hand === "string" && typeof x.name === "string" ? { hand: x.hand, name: x.name, online: x.online !== false, vm: x.sandbox === true || action === "new_sandbox" } : null
    if (action === "new_sandbox" && v && typeof v === "object") return pick(v as never)
    if (Array.isArray(v)) return pick((v.find((h) => h && (h as { online?: unknown }).online) ?? v[0] ?? {}) as never)
  } catch {
    // Not JSON: the continuation gives no hand details.
  }
  return null
}

const parseHandInfo = (info: string | undefined): HandInfo | null => {
  try {
    return info ? (JSON.parse(info) as HandInfo) : null
  } catch {
    return null
  }
}

/**
 * The continuation's message: the hand the first part made or found (id, name, online, work folder), so the model
 * starts the agent at once (it does not list its hands again). A paired machine picks its own name, so the name is
 * only a quoted label (control characters removed, capped); the model addresses the hand by its id.
 */
export const handsContinueText = (info: string | undefined, workdir: string): string => {
  const h = parseHandInfo(info)
  if (!h || typeof h.hand !== "string" || !/^[A-Za-z0-9_-]{1,80}$/.test(h.hand)) return HANDS_CONTINUE
  const label = JSON.stringify(String(h.name ?? "").replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 60))
  const folder = h.vm ? ` Its work folder is ${workdir}.` : ""
  const use = h.online ? ` Use it directly with the agent or hands tools (hand "${h.hand}"${h.vm ? `, cwd "${workdir}"` : ""}); there is no need to list your hands.` : ` Check it once with the hands tool before you start an agent on it (hand "${h.hand}").`
  return `${HANDS_CONTINUE} Your hand: ${label} (${h.hand}), ${h.online ? "online" : "not online yet"}.${folder}${use}`
}

export class ChiefBrainDO extends DurableObject<Env> {
  readonly sql = this.ctx.storage.sql
  /** The object's state and env for the split-out modules (brain-turn.ts, brain-sub.ts); DurableObject keeps them protected. */
  readonly doCtx = this.ctx
  readonly doEnv = this.env
  /** When this object was made, until the first wake reports it (Run.timing boot_at: a cold start). */
  bootAt: number | undefined = Date.now()
  readonly models = brainModels(this.env, this.ctx.id.toString(), { claude: { auth: () => claudeAuthFor(this.env, this.holder), refused: () => (forgetClaudeAuth(), this.holder().claudeInvalidate()) }, effort: () => this.config().effort, ...gatewayOptions(this.ctx, this.env, () => ({ run: this.turnId, conversation: this.turnConversation, config: this.config(), live: !this.childOf() })) })
  readonly registry = createRegistry()
  memory: Memory
  compactor: Compactor
  turnId: string | undefined
  turnConversation: string | undefined
  draining: Promise<void> | undefined
  readonly posting = new Set<string>()
  /** Operations that joined the running turn (messages that came in while it ran): the turn waits for them too. */
  steered: Array<string> = []
  /** The running turn's input is with pi: from then until it ends, new messages may join it. */
  turnLive = false
  authing: Promise<string> | undefined
  /** Child role (brain-spawn.ts): the start payload, read once from cb_config `spawn`. */
  child: ChildStart | null | undefined
  reporting: Promise<void> | undefined
  reportAgain = false
  subsChain: Promise<void> = Promise.resolve()
  /** The Chief's `agent` tool calls in flight (call id -> start): an agent outcome waits until they returned. */
  readonly agentCalls = new Map<string, number>()

  readonly harness = new PiHarness({
    harness: ({ storage, context }) => {
      this.registry.install({
        name: "chief",
        sections: [section("chief", () => (this.childOf() ? childPrompt(this.childOf()!) : systemPrompt(this.config())), { tag: false })],
        // A child (subagent) gets hands only: no memory, no Chief management, no spawn (one level deep).
        // Hands come from the "chief-hands" extension (installHands): full, or a compact entry until a hand exists.
        tools: this.childOf() ? [] : [...memoryTools(() => this.memory), ...chiefsTools(this.env, () => this.config(), () => this.effectsAuthorized()), spawnTool(this.spawnHost())],
        hooks: [
          hook(GenerationTask, {
            beforeRequest: async ({ messages }, api) => {
              const agent = (liveOf(this.ctx).request(String(api.taskId)), this.config().agent)
              if (this.turnConversation && agent && !this.childOf()) void typing(this.env, this.turnConversation, agent, true)
              // Thinking made under another tools list (a run's hands continuation, a hand paired between turns) is dropped.
              const fresh = stripStaleThinking(messages)
              if (fresh.stripped > 0) console.log(JSON.stringify({ msg: "chief_brain.thinking_stripped", run: this.turnId ?? null, blocks: fresh.stripped }))
              if (fresh.openMismatch > 0) console.error(JSON.stringify({ msg: "chief_brain.thinking_open_turn_mismatch", run: this.turnId ?? null, messages: fresh.openMismatch }))
              return systemFirst(fresh.messages) ?? (fresh.stripped > 0 ? { messages: fresh.messages } : undefined)
            },
            afterResponse: (message, api) => this.onResponse(message, String(api.taskId))
          }),
          hook(ToolTask, {
            afterTool: (call, result) => {
              const text = textParts(result.content as ReadonlyArray<{ type: string; text?: string }>)
              const capped = capText(text)
              const out = clip(text)
              if (call.name === "agent") this.agentCallEnded(call.id, text)
              this.logOnce(`echo:${call.id}`, "echo", capped, { id: `tool:${call.id}`, kind: "tool", status: "done", ...(out.truncated ? { truncated: true } : {}), ...((now) => ({ ended_at: now, tool: { name: call.name, output: out.text, ended_at: now } }))(Date.now()) })
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
          // steeringMode "all": every message steered in during a model call joins the next call (the reference
          // client reads all waiting messages at once); pi's default takes one per call, so a burst of 8 notes made 4-7 calls.
          settings: { retry: { enabled: true, maxRetries: 3, baseDelayMs: 2000 }, compaction: { enabled: false, backgroundTokens: 0 }, steeringMode: "all" },
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
    for (const q of [...SCHEMA, ...SPAWN_SCHEMA, IMPORT_SCHEMA]) this.sql.exec(q)
    const inboxColumns = new Set(this.sql.exec<{ name: string }>(`PRAGMA table_info(cb_inbox)`).toArray().map((c) => c.name))
    if (!inboxColumns.has("effect_authorized")) this.sql.exec(`ALTER TABLE cb_inbox ADD COLUMN effect_authorized INTEGER NOT NULL DEFAULT 0`)
    // Whether thread_root is the message's own (brain-text ownsRoot); rows from before keep the old reply target.
    if (!inboxColumns.has("own_root")) this.sql.exec(`ALTER TABLE cb_inbox ADD COLUMN own_root INTEGER NOT NULL DEFAULT 1`)
    const turnColumns = new Set(this.sql.exec<{ name: string }>(`PRAGMA table_info(cb_turn)`).toArray().map((c) => c.name))
    if (!turnColumns.has("effect_authorized")) this.sql.exec(`ALTER TABLE cb_turn ADD COLUMN effect_authorized INTEGER NOT NULL DEFAULT 0`)
    if (!turnColumns.has("trigger_own_root")) this.sql.exec(`ALTER TABLE cb_turn ADD COLUMN trigger_own_root INTEGER NOT NULL DEFAULT 1`)
    this.memory = new Memory(this.sql, Number(env.CHIEF_BRAIN_VIEW_BUDGET ?? "0") || 0)
    const compactCache = new PrefixCache(ttlMs(env.CHIEF_BRAIN_CACHE_TTL), msOr(env.CHIEF_BRAIN_PREFIX_WAIT_MS, PrefixCache.WAIT_MS))
    this.compactor = new Compactor({
      memory: this.memory,
      deps: () => {
        const name = this.compactorName()
        if (name === undefined) throw new Error("compactor: this owner may not use the paid compactor, and this deployment has no free one")
        return { memory: this.memory, models: this.models.models, model: this.models.model(name), thinking: name === FAKE ? "off" : isClaude(name) ? compactEffort(env.CHIEF_BRAIN_COMPACT_EFFORT) : "medium", prompt: "cmux", agent: AGENT, cache: compactCache, record: logCompactCall }
      },
      onBuilt: () => undefined,
      off: () => (importing(this.sql) ? "a memory copy is under way" : this.compactorName() === undefined ? "no compactor model this owner may use" : undefined),
      onFirstFailure: (l, i, error) => console.warn(JSON.stringify({ msg: "chief_brain.compactor_failed", node: `${l}:${i}`, error: error.slice(0, 300) })),
      onRetryWait: (at) => this.schedule("compact", "compact", at),
      retryBaseMs: Number(env.CHIEF_BRAIN_COMPACT_RETRY_BASE_MS) || undefined
    })
  }

  async onStart(): Promise<void> {
    this.compactor.pump()
    this.kick()
    for (const r of this.sql.exec<{ id: string }>(`SELECT id FROM cb_turn WHERE post = 'pending'`).toArray()) void this.postAndSchedule(r.id)
    if (this.sql.exec(`SELECT 1 FROM cb_spawn WHERE posted = 0 LIMIT 1`).toArray().length > 0) void this.deliverReports()
    if (this.sql.exec(`SELECT 1 FROM cb_agent_out WHERE posted = 0 LIMIT 1`).toArray().length > 0) void this.flushOutcomes()
    if (this.sql.exec(`SELECT 1 FROM cb_spawn_slot LIMIT 1`).toArray().length > 0) void this.pumpSlots()
    if (!this.memory.settled() && !this.compactor.off()) await this.schedule("compact", "compact", Date.now() + RETRY_MS)
  }

  /**
   * The compactor's model: a paid one (Haiku) only for an owner allowed paid models, as for turns (modelRefusal);
   * else the free fallback or the Chief's own unpaid turn model. undefined: none (production with a refused owner):
   * compaction is off and the nodes stay unbuilt, never a fake summary kept as a permanent node.
   */
  private compactorName(): string | undefined {
    const cfg = this.config()
    // The Claude Code route (chief-brain-cc/) has no Cloud model route for the compactor: compaction is off and the
    // turns read the whole unsummarized log (Memory.turnInput), never a fake summary.
    if (ccRoute(this.env, cfg.owner)) return undefined
    const fallback = this.env.CHIEF_BRAIN_FALLBACK_MODEL || FAKE
    const picked = compactorModel(this.env, cfg.compactor_model, fallback)
    if (!isMetered(picked) || meteredOwner(this.env, cfg.owner ?? null)) return picked
    return !isMetered(fallback) ? fallback : !isMetered(cfg.model) && cfg.model ? cfg.model : undefined
  }

  // ------------------------------------------------------------------ settings object (name = agent)

  defaults() {
    const fallback = this.env.CHIEF_BRAIN_FALLBACK_MODEL || FAKE
    const compactor = compactorDefault(this.env, this.env.CHIEF_BRAIN_MODEL || FAKE, fallback)
    // The paid compactor (Haiku) is the default only for an owner allowed paid models (modelRefusal refuses it otherwise,
    // and the chiefs tool copies this value into the Chiefs it makes); other owners get the free fallback, or keep the
    // paid name where there is none (the compactor then builds nothing for them; never a fake summary).
    if (!isMetered(compactor) || isMetered(fallback)) return { model: this.env.CHIEF_BRAIN_MODEL || FAKE, compactor_model: compactor }
    const owner = this.sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = 'owner'`).toArray()[0]?.value ?? null
    return { model: this.env.CHIEF_BRAIN_MODEL || FAKE, compactor_model: meteredOwner(this.env, owner) ? compactor : fallback }
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
  /** Owner's turns object (`claude-turns/<owner>`) only: one metered turn of `owner` (allow-list, the owner's daily cap, a lease of the deployment's bound). */
  async claudeTurn(owner: string, model?: string): Promise<string> {
    return ownerTurn(this.env, this.sql, owner, model ?? CLAUDE, (day, n) => {
      if (this.leasing) return this.leasing.then(() => 0)
      const p = this.holder().claudeLease(day, n).finally(() => (this.leasing = undefined))
      this.leasing = p
      return p
    })
  }
  leasing: Promise<number> | undefined
  /**
   * The caller warms this object: a new Chief's first turn then meets a running object. A conversation brain
   * that knows its Chief also starts its wake's reads (the settings object and chief record, the team's meter,
   * the route's auth, pi) while MuxDO commits the wake (mux-wake-delivery.ts warmBrain).
   */
  async warm(): Promise<true> {
    const cfg = this.config()
    // Only an enabled pi Chief's conversation brain (an opencode, local or disabled Chief's old object stays asleep).
    if (!cfg.agent || !cfg.owner || !cfg.enabled || cfg.brain_impl !== "pi" || this.childOf()) return true
    await this.lifecycle.start()
    // The Claude Code route (chief-brain-cc/) needs none of the model route's reads: only the admission.
    if (ccRoute(this.env, cfg.owner)) {
      this.ctx.waitUntil(this.settingsOf(cfg.agent).admit(cfg.agent, cfg.owner, false).catch(() => undefined))
      return true
    }
    const [agent, owner] = [cfg.agent, cfg.owner]
    this.ctx.waitUntil(this.settingsOf(agent).admit(agent, owner, false).catch(() => undefined))
    this.ctx.waitUntil(creditsCanStart(this.env, cfg).catch(() => undefined))
    if (isClaude(cfg.model)) this.ctx.waitUntil(claudeAuthFor(this.env, this.holder).catch(() => undefined))
    this.ctx.waitUntil(this.harness.pi().catch(() => undefined))
    return true
  }
  /** Holder only: a lease of today's deployment-wide bound (CHIEF_BRAIN_CLAUDE_DAILY_TURNS_TOTAL) for an owner's turns object. */
  async claudeLease(day: string, want: number): Promise<number> { return leaseTotal(this.env, this.sql, day, want) }
  /** Holder only: the route answered 401, so the stored access token goes. */
  async claudeInvalidate(): Promise<void> { holderInvalidate(this.sql) }
  /** Conversation brain: a per-run gateway token's revoke check and spend cap (model-gateway/run-ledger.ts). */
  async runToken(run: string, jti: string, cap: number, o: LedgerOp): Promise<LedgerAnswer> { return runLedger(this.sql, run, jti, cap, o) }
  holder = () => this.env.CHIEF_BRAIN_DO.get(this.env.CHIEF_BRAIN_DO.idFromName(HOLDER))
  turns = (owner: string) => this.env.CHIEF_BRAIN_DO.get(this.env.CHIEF_BRAIN_DO.idFromName(turnsObject(owner)))

  /** The owner's settings (the Worker checked the caller owns `agent`). Turning it on needs a live chief that no server runs. */
  async configure(agent: string, owner: string, patch: ConfigPatch): Promise<{ ok: true; config: BrainConfig } | { ok: false; code: string; message: string }> {
    await this.lifecycle.start()
    const cur = this.config()
    if ((cur.agent !== null && cur.agent !== agent) || (cur.owner !== null && cur.owner !== owner)) return { ok: false, code: "auth.forbidden", message: "this brain belongs to another chief" }
    const invalid = patchError(patch, validModelName)
    if (invalid) return { ok: false, code: "validation.invalid", message: invalid }
    // Claude bills one person's metered account: allowed owners only, and never for background compaction.
    // Turning the brain on (from off) checks the model it would run on (the patch's, else the current one), so an
    // owner off the paid list cannot enable a Chief whose model is paid only to be refused at its first turn. A save
    // that repeats enabled:true on a Chief already on is not refused for it (its turns say why they cannot run).
    // An opencode Chief with a container runs its turns on brainModel (opencode/host.ts): that is the model checked.
    const turningOn = patch.enabled === true && !cur.enabled
    const model = patch.model ?? cur.model
    const impl = turningOn && opencodeRuns(this.env) ? await (this.env.MUX_DO.get(this.env.MUX_DO.idFromName(agent)) as unknown as { brainImplOf(): Promise<string> }).brainImplOf() : "pi"
    const refused = modelRefusal(this.env, owner, turningOn ? { ...patch, model: impl === "opencode" ? brainModel(model) : model } : patch)
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

  /** The memory copy from a Mac Chief (memory-import.ts): where it stands. */
  memoryImportStatus(): ImportStatus {
    return importStatus(this.sql)
  }

  /** One batch of the memory copy; after the last one the view is folded again from the copied nodes. */
  async memoryImport(body: ImportBody | AppendBody | UndoBody, brainOn: boolean): Promise<ImportStatus | ImportFail | (AppendResult & { ok: true }) | (UndoResult & { ok: true })> {
    if ("mode" in body) {
      if (this.childOf()) return { ok: false, status: 400, code: "validation.invalid", message: "a subagent has no memory" }
      if (body.mode === "undo") {
        const u = undoBatch(this.sql, this.ctx.storage, body)
        if (u.ok) {
          this.memory.rewound()
          this.compactor.pump()
        }
        return u
      }
      const r = await appendBatch(this.sql, this.ctx.storage, body, (text) => void this.memory.append("note", text))
      if (r.ok && r.added > 0) this.compactor.pump()
      return r
    }
    if (this.childOf()) return { ok: false, status: 400, code: "validation.invalid", message: "a subagent has no memory" }
    const r = importBatch(this.sql, this.ctx.storage, body, brainOn)
    if (!("ok" in r) && body.done) {
      this.memory.reload()
      this.compactor.pump()
    }
    return r
  }

  /** A brain asks before a turn (`turn: true` counts it) or a post: enabled, the chief live and not placed, under the daily limit. */
  async admit(agent: string, owner: string, turn: boolean): Promise<Admission> {
    await this.lifecycle.start()
    const cfg = this.config()
    if (!cfg.enabled) return { ok: false, reason: "disabled" }
    if (cfg.agent !== agent || cfg.owner !== owner) return { ok: false, reason: "other_chief" }
    // The chief record and the credits check go at the same time (two other objects, independent reads).
    // A turn on the Claude Code route (chief-brain-cc/) uses no Cloud model route and is not charged to credits.
    const [record, credits] = await Promise.all([chiefRecordFresh(this.env, owner, agent).catch(() => undefined), turn && !ccRoute(this.env, owner) ? creditsCanStart(this.env, cfg) : Promise.resolve("ok" as const)])
    if (record === undefined) return { ok: false, reason: "owner.unreachable" }
    if (!record) return { ok: false, reason: "chief_archived" }
    if (record.brain_place) return { ok: false, reason: "chief_placed" }
    if (record.display_name !== cfg.display_name) writeConfig(this.sql, { display_name: record.display_name })
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

  settingsOf(agent: string) {
    return this.env.CHIEF_BRAIN_DO.get(this.env.CHIEF_BRAIN_DO.idFromName(agent))
  }

  /** Asks the settings object and keeps its answer as this brain's config copy. */
  async admitted(agent: string, owner: string, turn: boolean): Promise<Admission> {
    // A memory copy under way (memory-import.ts): no turn appends to the log until its last batch.
    if (importing(this.sql)) return { ok: false, reason: "memory_importing" } as Admission
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
    return sub.spawned(this, n)
  }
  /** Parent brain: a deleted child's run record (its object's storage is gone), or null. */
  async spawnRun(n: number, afterSeq = 0): Promise<{ run: Run; steps: Array<Step>; has_more: boolean } | null> {
    return sub.spawnRun(this, n, afterSeq)
  }
  /** Parent brain: keeps a child's run record before the child deletes its storage. */
  async spawnArchive(n: number, body: string): Promise<void> {
    return sub.spawnArchive(this, n, body)
  }

  /** This brain's runs, newest first (the Worker checked membership first). */
  async runs(conversation: string, before: number | undefined, limit: number): Promise<{ runs: Array<Run>; has_more: boolean }> {
    await this.lifecycle.start()
    const agent = this.config().agent
    return agent ? readRuns(this.sql, agent, conversation, before, limit) : { runs: [], has_more: false }
  }

  /** The Claude Code route's turn machine (POST /v1/chief-cc/<agent>/<conversation>/notes, chief-brain-cc/turn.ts). */
  async ccNotes(token: string, body: { run?: unknown; events?: unknown; result?: unknown; net?: unknown }): Promise<{ status: number; json?: unknown }> {
    // A turn machine outlives an evicted object: its post must start the object (onStart resumes the running
    // turn, which waits for this post), else the post meets no running turn (401) and the ready reply is lost.
    await this.lifecycle.start()
    return ccNotes(this, token, body)
  }

  /** The Chief's own tools (chief-brain-cc/tools.ts), on its `<agent>/tools` object only: one `chief-tools` call. */
  async ccTools(req: unknown): Promise<{ status: number; json: unknown }> {
    return toolsCall(this.sql, req)
  }

  /** The Chief's own tools as path -> text, for its next turn machine (chief-brain-cc/turn.ts). */
  async ccToolFiles(): Promise<Record<string, string>> {
    return toolFiles(this.sql)
  }

  /** The Chief's GitHub login (chief-brain-cc/github.ts), on its `<agent>/github` object only: one `chief-github` call or settings change. */
  async ccGithub(agent: string, req: unknown, machine: boolean): Promise<{ status: number; json: unknown }> {
    await this.lifecycle.start()
    return githubCall(this.githubHost(), agent, req, machine)
  }

  /** The token and status a turn machine of this Chief gets (chief-brain-cc/turn.ts). */
  async ccGithubTurn(agent: string): Promise<{ token: string | null; status: GithubStatus }> {
    return githubTurn(this.githubHost(), agent)
  }

  /** Its rows as stored (tests: no token in clear). */
  async ccGithubDump(): Promise<Array<{ name: string; value: string }>> {
    return githubDump(this.sql)
  }

  private githubHost(): GithubHost {
    return { sql: this.sql, env: this.env, schedule: (at) => this.schedule("gh-poll", "gh-poll", at) }
  }

  /**
   * The Chief's sandboxes (chief-brain-cc/sandbox.ts), on its `<agent>/sandboxes` object only: one `chief-vm` call.
   * `legacy`: sandboxes a conversation brain kept before they moved here (adopted once).
   */
  async ccSandboxCall(agent: string, req: unknown, legacy: ReadonlyArray<{ id: string; name: string; created_at: number }> = []): Promise<{ status: number; json: unknown }> {
    return ccSandbox(this, agent, req, legacy)
  }

  /** The Chief was archived: its sandboxes pause and its Freestyle identity goes, with every token and grant. */
  async ccSandboxRetire(): Promise<{ paused: number; revoked: boolean }> {
    return ccSandboxRetire(this)
  }

  /** The Chief was deleted: its sandboxes are deleted and its Freestyle identity goes. */
  async ccSandboxPurge(): Promise<{ deleted: number; left: number; revoked: boolean }> {
    return ccSandboxPurge(this)
  }

  /** A run of one of this Chief's jobs (chief-brain-cc/jobs.ts, AutomationRunWorkflow): its note starts a turn here. */
  async chiefJob(j: ChiefJob): Promise<JobDelivery> {
    return chiefJobWake(this, j)
  }

  /** MuxDO forwards a committed wake here. Pulls the conversation's new messages as the chief and starts a turn. */
  async wake(w: { agent: string; owner: string; conversation: string; seq: number; reason: string; at?: number }): Promise<{ queued: number } | { skipped: string; retry?: true }> {
    return turnLoop.wake(this, w)
  }

  /** A peer Chief's message (brain-turn.ts peerNote), forwarded by the owner's install. */
  async peerNote(w: { agent: string; owner: string; conversation: string; from: string; text: string; key: string }): Promise<{ queued: boolean } | { skipped: string }> {
    return turnLoop.peerNote(this, w)
  }

  /**
   * Logs the conversation's queued messages of the turn's thread into the running turn and gives them
   * to it (pi steer, after its current step). The op is recorded (memory and storage) before anything
   * awaits, so the turn's wait loop and a restart both see it; a failed steer puts the rows back.
   */
  async steerQueued(conversation: string): Promise<void> {
    return turnLoop.steerQueued(this, conversation)
  }

  /** The joined operations of `turn`, as stored (restart: the turn waits for them and gives pi any it never got). */
  steerOps(turn: string): Array<{ op: string; text: string }> {
    return turnLoop.steerOps(this, turn)
  }

  // ------------------------------------------------------------------ logging

  /** Appends to the memory log once per key; the running turn's step changes go to every member's socket. */
  logOnce(key: string, kind: Kind, text: string, step?: StepPatch): void {
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
  announce(turn: string, steps: ReadonlyArray<Step>): void {
    // A subagent run is not shown live as a Chief run (its card and the runs route show it).
    if (this.childOf()) return
    const agent = this.config().agent
    const run = agent ? readRun(this.sql, agent, turn) : null
    if (agent && run) this.ctx.waitUntil(liveOf(this.ctx).after(() => runChanged(this.env, run.conversation, agent, run, steps))) // behind the live frames
  }

  onResponse(message: AssistantMessage, taskId: string): void {
    if (message.stopReason === "error" || message.stopReason === "aborted") return
    const text = textParts(message.content as ReadonlyArray<{ type: string; text?: string }>).trim()
    if (text) this.logOnce(`talk:${taskId}`, "talk", text, { id: `talk:${taskId}`, kind: "talk", ...clip(text), ended_at: Date.now() })
    for (const part of message.content) {
      if (part.type !== "toolCall") continue
      if (part.name === "agent") this.agentCalls.set(part.id, Date.now())
      const tool = { name: part.name, input: clipInput(part.arguments), started_at: Date.now() }
      this.logOnce(`tool:${part.id}`, "tool", `${part.name} ${JSON.stringify(part.arguments)}`, { id: `tool:${part.id}`, kind: "tool", status: "running", tool })
    }
  }

  // ------------------------------------------------------------------ turns

  kick(): void {
    return turnLoop.kick(this)
  }

  async drain(): Promise<void> {
    return turnLoop.drain(this)
  }

  /** Logs the new messages, then builds the cache-stable input (frozen view + delta, OptChat 5a) with the turn row in one transaction (a restart resubmits the same bytes). */
  openTurn(conversation: string, rows: ReadonlyArray<{ n: number; message: string; seq: number; kind: string; thread_root: string | null; own_root?: number; text: string; woke: number; effect_authorized: number }>, fresh = false): void {
    return turnLoop.openTurn(this, conversation, rows, fresh)
  }

  async runTurn(id: string): Promise<void> {
    return turnLoop.runTurn(this, id)
  }

  async postAndSchedule(id: string): Promise<void> {
    return turnLoop.postAndSchedule(this, id)
  }

  /**
   * Posts the run's reply as the chief. Returns when to try again (the loop guard's agent_rate, or no
   * answer), or null when done; done acks the wakes.
   */
  async post(id: string): Promise<number | null> {
    return turnLoop.post(this, id)
  }

  /** Typing off and the wake cursor moved past the run's messages. */
  async finish(id: string): Promise<void> {
    return turnLoop.finish(this, id)
  }

  // ------------------------------------------------------------------ subagents (brain-spawn.ts)

  /** The start payload when this object is a child (subagent), else null. */
  childOf(): ChildStart | null {
    if (this.child === undefined) this.child = readChild(this.sql)
    return this.child
  }

  /** A child runs a task an authorized spawn created. A Chief turn may run
   * effects only while every message delivered to it was owner-authored. */
  effectsAuthorized(): boolean {
    if (this.childOf()) return true
    if (!this.turnId) return false
    return this.sql.exec<{ effect_authorized: number }>(`SELECT effect_authorized FROM cb_turn WHERE id = ?`, this.turnId).toArray()[0]?.effect_authorized === 1
  }

  /**
   * The hands tools as their own extension: the full `hands` + `agent` pair when the Chief has a hand (or is a
   * child, which works on hands), else one compact `hands` entry (list, pair_code, new_sandbox): about 1.8k fewer
   * input tokens per request for a Chief with no hand, without losing the way to get one. The set changes only at a
   * turn boundary (startTurnHands): after new_sandbox or pairing, the next turn has the full tools.
   */
  installHands(): void {
    // Hands off on this deployment (HANDS_ENABLED): no hands tools at all.
    if (this.env.HANDS_ENABLED !== "1") return
    const v = (k: string) => this.sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = ?`, k).toArray()[0]?.value
    // The tools are fixed for a whole turn (a model signs its thinking for the tools list; a change inside the
    // turn makes the next request a 400). The running turn's mode wins, also when the object opens again mid-turn.
    const full = this.childOf() !== null || (v("hands_turn_mode") ?? v("hands_full")) === "1"
    this.registry.install({ name: "chief-hands", tools: full ? [...this.hands()] : [handsEntryTool(this.env, () => ({ ...this.config() }), (action, result) => this.handFoundInTurn(action, result), () => this.effectsAuthorized())] })
  }

  /** At a turn boundary only: this turn's hands mode (full once a hand was found), recorded for the whole turn. */
  startTurnHands(): void {
    const full = this.sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = 'hands_full'`).toArray()[0]?.value === "1"
    writeConfig(this.sql, { hands_turn_mode: full ? "1" : "0" })
    this.installHands()
  }

  /** Checks for a hand (one list call) and records it; true when it found the first one now. The full tools come at the next pi turn, never inside one. */
  async refreshHands(): Promise<boolean> {
    if (this.env.HANDS_ENABLED !== "1") return false
    if (this.childOf() !== null || this.sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = 'hands_full'`).toArray()[0]?.value === "1") return false
    if (!(await hasHand(this.env, () => ({ ...this.config() })))) return false
    writeConfig(this.sql, { hands_full: "1" })
    return true
  }

  /** The entry tool made or found the first hand during a turn: the turn continues once with the full tools (runTurn). */
  async handFoundInTurn(action: string, result = ""): Promise<void> {
    const turn = this.turnId
    const foundNow = await this.refreshHands()
    // A list continues the run when this call found the first hand, or when it shows a hand that the turn-start check
    // found in the background (a sandbox made or a machine paired just before the message): else the turn would end
    // with no agent tool. new_sandbox continues also when the turn-start check found it first.
    if (action === "list" && !foundNow && handOfResult(action, result) === null) return
    const v = (k: string) => this.sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = ?`, k).toArray()[0]?.value
    // A hand exists now while this turn runs with the compact tools (also when the turn-start check found it first).
    if (turn && v("hands_full") === "1" && v("hands_turn_mode") === "0" && v(`hands_cont:${turn}`) === undefined) {
      // What the step returned (the hand), so the continuation starts from it instead of listing again.
      const hand = handOfResult(action, result)
      writeConfig(this.sql, { [`hands_cont:${turn}`]: "pending", ...(hand ? { [`hands_cont_info:${turn}`]: JSON.stringify(hand) } : {}) })
    }
  }

  /** The hands tools; a child's caller and agent tokens name its own object (`<conversation>:spawn:<n>`), so a hand's session-end revoke reaches it. */
  hands() {
    const c = this.childOf()
    return handsTools(this.env, () => ({ ...this.config(), run: this.turnId, conversation: c ? childKey(c.conversation, c.n) : this.turnConversation, ledger: (jti: string, o: LedgerOp) => runLedger(this.sql, this.turnId ?? "", jti, 0, o) }), (r) => (r.type === "run.activity" ? liveOf(this.ctx).activity(r.line) : this.turnId && this.announce(this.turnId, [upsertStep(this.sql, this.turnId, r.step, Date.now())])), () => this.effectsAuthorized())
  }

  spawnHost() {
    return sub.spawnHost(this)
  }

  /** Settings object: queue children; at most CHIEF_SPAWN_MAX of this Chief's children run at once. */
  async spawnEnqueue(agent: string, owner: string, items: Array<ChildStart>): Promise<{ running: number; waiting: number }> {
    return sub.spawnEnqueue(this, agent, owner, items)
  }

  /** Settings object: a child reported; its slot frees and the next waiting child starts. */
  async spawnDone(child: string): Promise<void> {
    return sub.spawnDone(this, child)
  }

  async pumpSlots(): Promise<void> {
    return sub.pumpSlots(this)
  }

  /** Child object: take the task (once) and run it. `ended`: this child already reported (a repeated start). */
  async spawnStart(s: ChildStart): Promise<{ ended: boolean }> {
    return sub.spawnStart(this, s)
  }

  /** Child: the Chief is on, live, under its daily turns, and the team has credits for the child's model (no model call otherwise). */
  async childAdmit(c: ChildStart): Promise<string | null> {
    return sub.childAdmit(this, c)
  }

  /** Child: the run ended; its report (the last talk, or a short failure line with no internal detail) goes to the parent. */
  async childEnd(id: string, ok: boolean, reason: string | null): Promise<void> {
    return sub.childEnd(this, id, ok, reason)
  }

  /** Child: hands the report to the parent brain and frees the slot; retried (job) until both answer. */
  async childReport(id: string): Promise<number | null> {
    return sub.childReport(this, id)
  }

  /** Child: CHIEF_SPAWN_KEEP_DAYS after its report, the run record moves to the parent and this object's storage goes. */
  async childGc(): Promise<LifecycleJobOutcome | void> {
    return sub.childGc(this)
  }

  /** Where the running turn's replies go (its conversation, kind and thread). */
  turnWhere() {
    return sub.turnWhere(this)
  }

  /** An `agent` tool call returned: what it saw is noted, and outcomes held back for it are checked now. */
  agentCallEnded(id: string, output: string): void {
    return sub.agentCallEnded(this, id, output)
  }

  /**
   * HandDO: an agent turn of a session this object started ended. Queued, then posted to the Chief as a work
   * message unless its own agent call already saw it; a child forwards it to its parent.
   */
  async agentOutcome(o: AgentOutcome): Promise<{ ok: true }> {
    return sub.agentOutcome(this, o)
  }

  /** Checks queued outcomes once no agent call is in flight (a call older than 15 min no longer holds them). */
  async flushOutcomes(): Promise<void> {
    return sub.flushOutcomes(this)
  }

  /** Parent brain: a child's agent outcome (checked there), posted in the thread of the spawning turn. */
  async spawnAgentOutcome(n: number, o: AgentOutcome): Promise<{ ok: true }> {
    return sub.spawnAgentOutcome(this, n, o)
  }

  /** Parent brain: a child's report (stored before anything else), then posted and queued. */
  async spawnReport(n: number, status: "done" | "failed", report: string): Promise<{ ok: true }> {
    return sub.spawnReport(this, n, status, report)
  }

  /** Parent brain: posts stored reports as work cards and queues them as woken messages (steered into a running turn, or a new turn). */
  deliverReports(): Promise<void> {
    return sub.deliverReports(this)
  }

  /** The live "N subagents" line of `conversation` (sent in order). */
  subsChanged(conversation: string): void {
    return sub.subsChanged(this, conversation)
  }

  // ------------------------------------------------------------------ jobs

  async schedule(id: string, fn: string, time: number): Promise<void> {
    await this.lifecycle.jobs.push({ id, fn, time, singleflight: true, hungTimeoutSeconds: 600 })
  }

  /** Lifecycle wakes the object for due jobs, also after an eviction. A post retry reschedules itself through the outcome. */
  async onJob({ job }: LifecycleJobContext): Promise<LifecycleJobOutcome | void> {
    if (job.fn === "post") {
      const next = await this.post(String(job.id).slice("post:".length))
      return next === null ? undefined : { rescheduleAt: next }
    }
    if (job.fn === "drain") return void this.kick()
    if (job.fn === "self-wake") return wakeFire(this, String(job.id))
    if (job.fn === "gh-poll") {
      const next = await githubPoll(this.githubHost())
      return next === null ? undefined : { rescheduleAt: next }
    }
    if (job.fn === "spawn-pump") return void (await this.pumpSlots())
    if (job.fn === "spawn-post") return void (await this.deliverReports())
    if (job.fn === "spawn-gc") return this.childGc()
    if (job.fn === "agent-out") return void (await this.flushOutcomes())
    if (job.fn !== "compact" || this.compactor.off()) return
    this.compactor.pump()
    if (!(await this.compactor.settle(AbortSignal.timeout(60_000)))) return { rescheduleAt: Date.now() + RETRY_MS }
  }
}
