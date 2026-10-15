import { Exit } from "effect"
import { decodeLiveFrame, LIVE_STEP_MAX, type LiveFrame } from "./chief-brain/contract.ts"

export { LIVE_CAPABILITY } from "./chief-brain/contract.ts"

/**
 * The ConversationDO's live buffer for Chief runs (chief-brain/contract.ts "Live frames"): what a
 * member who joins or reconnects mid-run needs to see the text so far and the "working on" line.
 * In memory only; never stored, never in the op log or a snapshot of the log. Lost on eviction,
 * which only shortens what a late joiner sees (the Step rows and the reply stay authoritative).
 *
 * Keys: a run id is unique per Chief, not per conversation (two Chiefs both have `run_1`), so runs
 * are keyed by author + id, and every frame the owner sends carries `author` (owner-stamped).
 * Bounds: 64 KiB of tail text per step, 32 steps per run (the oldest step goes first), 8 live runs
 * per conversation (the least recently touched goes first), a run with no frame for an hour is
 * dropped (a brain that died mid-run). A thought step ends at its `final` delta (it has no Step row).
 */
interface LiveStep {
  kind: "talk" | "thought"
  seq: number
  text: string
}
interface LiveRun {
  readonly author: string
  readonly run: string
  readonly steps: Map<string, LiveStep>
  /** Steps whose Step row arrived: later deltas for them are dropped (the row is the text). */
  readonly done: Set<string>
  activity?: { line: string; since: number; at: number }
  touched: number
}

const MAX_STEPS = 32
const MAX_RUNS = 8
const MAX_ENDED = 256
const STALE_MS = 60 * 60_000

const keyOf = (author: string, run: string) => `${author}\u0000${run}`
/** The tail of `text` within the cap, never starting with half a surrogate pair. */
const tail = (text: string): string => {
  if (text.length <= LIVE_STEP_MAX) return text
  const t = text.slice(-LIVE_STEP_MAX)
  return /^[\udc00-\udfff]/.test(t) ? t.slice(1) : t
}

export class LiveBuffer {
  private readonly runs = new Map<string, LiveRun>()
  private readonly ended = new Set<string>()

  constructor(private readonly now: () => number = Date.now) {}

  /**
   * A producer's frame from Chief `author` (already checked to be a participant). Returns the frame
   * for every member's socket, and `reset` when a step restarted (members get a fresh run.live),
   * or null to drop it (invalid, another conversation, a finished run or step, a duplicate).
   */
  apply(conversation: string, author: string, raw: unknown): { readonly frame: string; readonly reset: boolean } | null {
    const exit = decodeLiveFrame(raw)
    if (Exit.isFailure(exit)) return null
    const f: LiveFrame = exit.value
    const key = keyOf(author, f.run)
    if (f.conversation !== conversation || this.ended.has(key)) return null
    let r = this.runs.get(key)
    if (!r) this.runs.set(key, (r = this.open(author, f.run)))
    r.touched = this.now()
    let reset = false
    if (f.type === "run.activity") r.activity = { line: f.line, since: f.since, at: f.at }
    else {
      // A retried request restarts its thought at seq 0 (the failed attempt's final ended it).
      if (r.done.has(f.step) && !(f.kind === "thought" && f.seq === 0)) return null
      r.done.delete(f.step)
      const s = r.steps.get(f.step)
      if (!s || f.seq === 0) {
        if (!s && r.steps.size >= MAX_STEPS) r.steps.delete(r.steps.keys().next().value!)
        reset = s !== undefined
        r.steps.set(f.step, { kind: f.kind, seq: f.seq, text: tail(f.text) })
      } else {
        if (f.seq <= s.seq) return null
        s.seq = f.seq
        s.text = tail(s.text + f.text)
      }
      // A thought has no Step row: its final delta ends it (a talk step ends at its row).
      if (f.final && f.kind === "thought") [r.steps.delete(f.step), r.done.add(f.step)]
    }
    return { frame: JSON.stringify({ t: f.type, ...f, author }), reset }
  }

  /** A new run entry, after dropping the least recently touched one at the cap. */
  private open(author: string, run: string): LiveRun {
    if (this.runs.size >= MAX_RUNS) this.runs.delete([...this.runs.entries()].sort((a, b) => a[1].touched - b[1].touched)[0]![0])
    return { author, run, steps: new Map(), done: new Set(), touched: this.now() }
  }

  /** A run summary and the steps that changed (`conversation-run-changed`): rows end live steps; a terminal run ends the run. */
  runChanged(author: string, run: unknown, steps: ReadonlyArray<unknown>): void {
    const r0 = run as { id?: unknown; status?: unknown } | null
    if (typeof r0?.id !== "string") return
    const key = keyOf(author, r0.id)
    if (r0.status !== undefined && r0.status !== "running") {
      this.runs.delete(key)
      this.ended.add(key)
      if (this.ended.size > MAX_ENDED) this.ended.delete(this.ended.values().next().value!)
      return
    }
    // A row can overtake the first live frame: remember it so a late delta cannot open the step again.
    let r = this.runs.get(key)
    if (!r && steps.length > 0) this.runs.set(key, (r = this.open(author, r0.id)))
    if (!r) return
    for (const s of steps) {
      const id = (s as { id?: unknown; kind?: unknown } | null)?.id
      if (typeof id === "string" && (id.startsWith("talk:") || id.startsWith("thought:"))) [r.steps.delete(id), r.done.add(id)]
    }
  }

  /** `run.live` for one conversation: every running run's text so far and activity. */
  snapshot(conversation: string): string {
    const now = this.now()
    for (const [k, r] of this.runs) if (now - r.touched > STALE_MS) this.runs.delete(k)
    const runs = [...this.runs.values()].map((r) => ({
      run: r.run,
      author: r.author,
      steps: [...r.steps.entries()].map(([step, s]) => ({ step, kind: s.kind, seq: s.seq, text: s.text })),
      ...(r.activity ? { activity: r.activity } : {})
    }))
    return JSON.stringify({ t: "run.live", type: "run.live", conversation, runs })
  }
}

const buffers = new WeakMap<object, LiveBuffer>()
/** The live buffer of one ConversationDO (keyed by its state object). */
export const liveBuffer = (ctx: object): LiveBuffer => {
  let b = buffers.get(ctx)
  if (!b) buffers.set(ctx, (b = new LiveBuffer()))
  return b
}

/**
 * Socket frames for the live buffer, before OwnerDO's own handling. `subscribe` (join, reconnect):
 * OwnerDO answers with its snapshot first, then this socket gets one `run.live` (returns false so
 * OwnerDO still handles the subscribe). `run.live.get` (`t` or `type`): one `run.live` (returns true).
 * Members only; a non-member's `run.live.get` gets an error.
 */
export const liveSocketFrame = (ctx: object, ws: WebSocket, frame: { readonly t?: string; readonly type?: unknown }, conversation: string | undefined, member: boolean): boolean => {
  const get = frame.t === "run.live.get" || (frame.t === undefined && frame.type === "run.live.get")
  if (frame.t !== "subscribe" && !get) return false
  const send = (text: string) => {
    try {
      ws.send(text)
    } catch {}
  }
  if (!conversation || !member) {
    if (get) send(JSON.stringify({ t: "error", code: "auth.forbidden", message: "not a participant" }))
    return get
  }
  const snapshot = liveBuffer(ctx).snapshot(conversation)
  if (get) send(snapshot)
  else queueMicrotask(() => send(snapshot))
  return get
}
