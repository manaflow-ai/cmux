import type { AssistantMessageEvent } from "@earendil-works/pi-ai"
import type { Env } from "../env.ts"
import { ACTIVITY_MAX, DELTA_MAX, type LiveFrame } from "./contract.ts"

/**
 * The Cloud brain's live producer (contract.ts "Live frames"): it taps the model stream of the
 * running turn and sends `step.delta` and `run.activity` to the conversation's ConversationDO by
 * RPC, which fans them out to the members' sockets and keeps the live buffer. Nothing here is stored.
 *
 * - Step ids are the turn's Step ids: `talk:<generation task id>` and `thought:<generation task id>`
 *   (brain-do.ts names the talk Step row the same way), so the final row replaces the live text.
 * - Deltas are batched: one frame per step per ~40 ms or 64 stream deltas, whichever comes first;
 *   at most 4096 UTF-16 units per frame, never cut inside a surrogate pair. The last code point of a
 *   step is held back until the generation ends, so the step's `final` frame always carries text.
 * - A retried request of the same generation restarts its steps at seq 0 (the owner treats seq 0 on
 *   a step it holds as a reset and sends every member a fresh `run.live`).
 * - Activity: "Thinking" when a request starts, "Writing the reply" at the first text, the tool's
 *   line when the model calls a tool; newest wins, sent only when the line changes.
 * - Frames go out one after another on one promise chain, so the owner sees them in order.
 */
const BATCH_MS = 40
const BATCH_DELTAS = 64
/** One send on the chain waits at most this long, so a hung RPC never holds back later frames for good. */
const SEND_MS = 10_000

const bounded = (p: Promise<void>): Promise<void> => {
  let timer: ReturnType<typeof setTimeout> | undefined
  return Promise.race([p, new Promise<void>((r) => (timer = setTimeout(r, SEND_MS)))]).finally(() => clearTimeout(timer))
}

type Kind = "talk" | "thought"
interface LiveStep {
  readonly id: string
  readonly kind: Kind
  seq: number
  pending: string
}
/** What the brain is running now; `run` and `conversation` are unset between turns. */
export interface LiveTarget {
  readonly run: string | undefined
  readonly conversation: string | undefined
  readonly agent: string | null
}

type Send = (conversation: string, agent: string, frame: LiveFrame) => Promise<void>

const conv = (env: Env, id: string) => env.CONVERSATION_DO.get(env.CONVERSATION_DO.idFromName(id)) as unknown as { agentFrame(entity: string, agent: string, f: { live: LiveFrame }): Promise<void> }
const rpcSend = (env: Env): Send => (conversation, agent, frame) => conv(env, conversation).agentFrame(conversation, agent, { live: frame })

/** Splits `text` into chunks of at most `max` UTF-16 units without cutting a surrogate pair. */
export const chunks = (text: string, max = DELTA_MAX): Array<string> => {
  const out: Array<string> = []
  let at = 0
  while (at < text.length) {
    let end = Math.min(at + max, text.length)
    const last = text.charCodeAt(end - 1)
    if (end < text.length && last >= 0xd800 && last <= 0xdbff) end--
    out.push(text.slice(at, end))
    at = end
  }
  return out
}

/** One activity line: one line, at most 80 characters. */
export const activityLine = (line: string): string => {
  const one = line.replace(/\s+/g, " ").trim()
  return one.length <= ACTIVITY_MAX ? one : `${one.slice(0, ACTIVITY_MAX - 1).replace(/[\ud800-\udbff]$/, "")}…`
}

/** The "working on" line for a tool call (Hands will name files and sandboxes here). */
export const toolActivity = (name: string, args: unknown): string => {
  const a = (args ?? {}) as Record<string, unknown>
  if (name === "zoom" || name === "date") return "Reading memory"
  if (name === "spawn") return "Starting subagents"
  if (name === "chiefs") return typeof a.action === "string" ? `Chiefs: ${a.action}` : "Working on Chiefs"
  const target = [a.path, a.file, a.cwd, a.url].find((v): v is string => typeof v === "string" && v.length > 0)
  return target ? `${name} ${target}` : `Running ${name}`
}

export class BrainStream {
  private run: string | undefined
  private generation: string | undefined
  private readonly steps = new Map<string, LiveStep>()
  private deltas = 0
  private timer: ReturnType<typeof setTimeout> | undefined
  private line: string | undefined
  private chain: Promise<void> = Promise.resolve()

  constructor(
    private readonly target: () => LiveTarget,
    private readonly send: Send,
    private readonly now: () => number = Date.now
  ) {}

  /** The running model request (pi-durable generation task id), for the gateway's credits request ids. */
  get generationId(): string | undefined {
    return this.generation
  }

  /** Timing marks of a run: its first model request and its first token (brain-gateway.ts stores them on the run). */
  onMark: (run: string, mark: "request" | "first_token" | "generation_first_token", at: number) => void = () => undefined
  private firstToken = false
  private genToken = false

  /** The first model output of the run (text, thinking or a tool call) and of each generation. */
  private token(): void {
    if (!this.run) return
    if (!this.firstToken) [(this.firstToken = true), this.onMark(this.run, "first_token", this.now())]
    if (!this.genToken) [(this.genToken = true), this.onMark(this.run, "generation_first_token", this.now())]
  }

  /** A model request of the running turn starts (pi-durable GenerationTask beforeRequest). */
  request(taskId: string): void {
    const t = this.target()
    if (!t.run) return
    if (t.run !== this.run) [this.run, this.line, this.firstToken] = [t.run, undefined, false]
    else this.flush(false)
    this.onMark(t.run, "request", this.now())
    // A new attempt of the same generation streams its text again from the start.
    for (const s of this.steps.values()) [s.seq, s.pending] = [0, ""]
    if (taskId !== this.generation) [this.steps.clear(), (this.genToken = false)]
    this.generation = taskId
    this.setActivity("Thinking")
  }

  /** Runs `send` after every live frame queued so far (run changes go out behind the deltas they end). */
  after(send: () => Promise<void>): Promise<void> {
    const next = this.chain.then(() => bounded(send())).catch(() => undefined)
    this.chain = next
    return next
  }

  /** A "working on" line from outside the model stream (Hands tools: "Editing src/app.ts in sb-3"). */
  activity(line: string): void {
    if (this.target().run === this.run) this.setActivity(line)
  }

  /** Every event of the turn's model stream (models.ts taps `streamSimple`). */
  event(e: AssistantMessageEvent): void {
    if (!this.run || !this.generation || this.target().run !== this.run) return
    switch (e.type) {
      // The first output of any kind marks the token, at its block start (a redacted thinking block has no delta).
      case "toolcall_start":
      case "text_start":
      case "thinking_start":
        return this.token()
      case "text_delta":
        this.token()
        if (!this.steps.has(`talk:${this.generation}`)) this.setActivity("Writing the reply")
        return this.append("talk", e.delta)
      case "thinking_delta":
        this.token()
        return this.append("thought", e.delta)
      case "toolcall_end":
        this.flush(false)
        return this.setActivity(toolActivity(e.toolCall.name, e.toolCall.arguments))
      case "done":
      case "error":
        return this.flush(true)
      default:
    }
  }

  private append(kind: Kind, delta: string): void {
    if (!delta) return
    const id = `${kind}:${this.generation}`
    let s = this.steps.get(id)
    if (!s) this.steps.set(id, (s = { id, kind, seq: 0, pending: "" }))
    s.pending += delta
    if (++this.deltas >= BATCH_DELTAS) return this.flush(false)
    this.timer ??= setTimeout(() => this.flush(false), BATCH_MS)
  }

  /** Sends every step's pending text; `final` ends the generation's steps (the held-back tail goes too). */
  private flush(final: boolean): void {
    clearTimeout(this.timer)
    this.timer = undefined
    this.deltas = 0
    for (const s of this.steps.values()) {
      // Hold back the last code point so a later `final` frame is never empty.
      const keep = final ? 0 : s.pending.length >= 2 && /[\udc00-\udfff]$/.test(s.pending) ? 2 : s.pending.length > 0 ? 1 : 0
      const out = s.pending.slice(0, s.pending.length - keep)
      s.pending = s.pending.slice(s.pending.length - keep)
      const parts = chunks(out)
      parts.forEach((text, i) => this.emit({ type: "step.delta", step: s.id, kind: s.kind, seq: s.seq++, text, ...(final && i === parts.length - 1 ? { final: true as const } : {}) }))
    }
    if (final) this.steps.clear()
  }

  private setActivity(line: string): void {
    const l = activityLine(line)
    if (!l || l === this.line) return
    this.line = l
    const at = this.now()
    this.emit({ type: "run.activity", line: l, since: at, at })
  }

  private emit(frame: Omit<StepDeltaOut, "conversation" | "run"> | Omit<ActivityOut, "conversation" | "run">): void {
    const t = this.target()
    if (!t.run || !t.conversation || !t.agent || t.run !== this.run) return
    const full = { ...frame, conversation: t.conversation, run: t.run } as LiveFrame
    const [conversation, agent] = [t.conversation, t.agent]
    this.chain = this.chain.then(() => bounded(this.send(conversation, agent, full))).catch(() => undefined)
  }
}

type StepDeltaOut = Extract<LiveFrame, { type: "step.delta" }>
type ActivityOut = Extract<LiveFrame, { type: "run.activity" }>

const streams = new WeakMap<object, BrainStream>()

/**
 * The BrainStream of one ChiefBrainDO (keyed by its state object): created by the first call that
 * passes `env` and `target` (the models field), returned as is afterwards (the beforeRequest hook).
 */
export const liveOf = (ctx: object, env?: Env, target?: () => LiveTarget): BrainStream => {
  let s = streams.get(ctx)
  if (!s) {
    if (!env || !target) throw new Error("liveOf: the brain's live stream is not set up")
    streams.set(ctx, (s = new BrainStream(target, rpcSend(env))))
  }
  return s
}
