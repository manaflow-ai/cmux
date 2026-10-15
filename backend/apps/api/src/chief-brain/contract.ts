import { Context, type Effect, Schema, type Stream } from "effect"
import type { Credits } from "../credits.ts"
import type { Minted } from "../hand-api.ts"
import type { Sandbox } from "../hand-sandbox.ts"
import type { HandsError, HandSummary, Profile, StoredEvent } from "../hand-wire.ts"

/**
 * The Brain contract: what any Chief brain implementation produces for one wake, and the live frames
 * a member's conversation socket carries while a run works. Implementation-neutral on purpose: the
 * Cloud brain on pi-durable (brain-do.ts, "P"), a Cloud brain on another harness ("O") and the local
 * Rust optchat-chief emit the same JSON. The DO-side caller (the MuxDO wake path) and every page only
 * know this file's shapes, never which implementation runs.
 *
 * Wire names (hq-1f DESIGN.md "Live frames", FINAL v1): frames carry `type`; the Cloud conversation
 * socket also sets `t` to the same value, because every other frame on that socket is keyed by `t`.
 * The owner stamps `author` (the Chief participant) on every frame it sends and on each `run.live`
 * run: run ids repeat across Chiefs, so a client keys live state by conversation + author + run.
 *
 * Live frames (capability `chief-live-v1`, in the Cloud socket's `welcome.capabilities`):
 * - No separate subscribe: a member's subscribed conversation socket receives `step.delta` and
 *   `run.activity` with the same read rules as the Run/Step records (members only).
 * - On subscribe (join and every reconnect) the socket receives ONE `run.live` right after its
 *   snapshot: the text so far and the activity of every running run (`runs: []` = nothing live).
 *   The client replaces its live state with it, then applies `step.delta` frames whose `seq` is
 *   above the snapshot's `seq` for that step.
 * - A gap (a step's `seq` jumps past the next number) or a reset (a `step.delta` with `seq` 0 for a
 *   step the client already holds text for: a model request was retried) means the client sends
 *   `run.live.get {conversation}` on the same socket and replaces its live state with the answer. The
 *   owner also sends `run.live` to every member by itself when a producer restarts a step.
 * - The final Step row (`conversation-run-changed` with the step) replaces the step's live text; a
 *   terminal Run status ends the run's live state; the reply message (client_msg_id = Run.turn)
 *   replaces the streaming bubble. Thought text never becomes a message.
 * - Live frames are never stored: not messages, not op-log rows, not Step rows, not in snapshots.
 *   The owner keeps an in-memory buffer per running run (64 KiB of tail text per step), freed at the
 *   run's end; after an owner restart the buffer starts empty and fills from the next frame.
 */

/** Run and Step ids (TRAJECTORIES.md: 1-128 of [A-Za-z0-9_.:-]). */
export const RunId = Schema.String.check(Schema.isPattern(/^[A-Za-z0-9_.:-]{1,128}$/))
export const StepId = RunId
const Ms = Schema.Number.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(0))
const Seq = Ms

export const RunStatus = Schema.Literals(["running", "done", "failed", "cancelled"])
export const StepKind = Schema.Literals(["talk", "thought", "tool", "note"])
export const LiveKind = Schema.Literals(["talk", "thought"])

/** TRAJECTORIES.md Run (summary). Extra producer fields are allowed and ignored by readers. */
export const Run = Schema.Struct({
  id: RunId,
  conversation: Schema.String,
  author: Schema.String,
  turn: Schema.optionalKey(Schema.String),
  answers: Schema.optionalKey(Schema.Array(Schema.String)),
  thread_root: Schema.optionalKey(Schema.String),
  status: RunStatus,
  title: Schema.optionalKey(Schema.String),
  started_at: Ms,
  ended_at: Schema.optionalKey(Ms),
  step_count: Schema.optionalKey(Seq),
  model: Schema.optionalKey(Schema.String),
  harness: Schema.optionalKey(Schema.String),
  usage: Schema.optionalKey(Schema.Struct({ input: Ms, output: Ms, cache_read: Ms, cache_write: Ms })),
  cost_usd: Schema.optionalKey(Schema.Number),
  error: Schema.optionalKey(Schema.String),
  session: Schema.optionalKey(Schema.Struct({ kind: Schema.String, id: Schema.String, host: Schema.optionalKey(Schema.String) }))
})
export type Run = typeof Run.Type

/** TRAJECTORIES.md Step (one row of the trajectory; upsert by id). */
export const Step = Schema.Struct({
  id: StepId,
  seq: Seq,
  at: Ms,
  kind: StepKind,
  status: Schema.optionalKey(Schema.Literals(["running", "done", "failed"])),
  text: Schema.optionalKey(Schema.String),
  truncated: Schema.optionalKey(Schema.Boolean),
  tool: Schema.optionalKey(Schema.Struct({ name: Schema.String, kind: Schema.optionalKey(Schema.String), input: Schema.optionalKey(Schema.Unknown), output: Schema.optionalKey(Schema.String), started_at: Schema.optionalKey(Ms), ended_at: Schema.optionalKey(Ms) }))
})
export type Step = typeof Step.Type

/** Text of one `step.delta`: 1..4096 UTF-16 units, never a lone surrogate at either end. */
export const DELTA_MAX = 4096
/** The owner's live buffer keeps this much tail text per step (UTF-16 units). */
export const LIVE_STEP_MAX = 64 * 1024
/** `run.activity.line`: 1..80 characters, one line. */
export const ACTIVITY_MAX = 80
export const LIVE_CAPABILITY = "chief-live-v1"

const DeltaText = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(DELTA_MAX))
const ActivityLine = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(ACTIVITY_MAX), Schema.isPattern(/^[^\n\r]+$/))

/** Tokens appended to a talk or thought step. `seq` is per (run, step), from 0, +1 per frame. */
export const StepDelta = Schema.Struct({
  type: Schema.Literal("step.delta"),
  conversation: Schema.String,
  run: RunId,
  step: StepId,
  kind: LiveKind,
  seq: Seq,
  text: DeltaText,
  /** The step's last delta; the Step row with the full text follows. */
  final: Schema.optionalKey(Schema.Literal(true)),
  /** Owner-stamped: the Chief that writes the run (run ids are unique per Chief, not per conversation). */
  author: Schema.optionalKey(Schema.String)
})
export type StepDelta = typeof StepDelta.Type

/** The compact "working on" line: newest wins; the client renders elapsed time from `since`. */
export const RunActivity = Schema.Struct({
  type: Schema.Literal("run.activity"),
  conversation: Schema.String,
  run: RunId,
  line: ActivityLine,
  since: Ms,
  at: Ms,
  author: Schema.optionalKey(Schema.String)
})
export type RunActivity = typeof RunActivity.Type

export const LiveStep = Schema.Struct({ step: StepId, kind: LiveKind, seq: Seq, text: Schema.String })
export const LiveRun = Schema.Struct({
  run: RunId,
  author: Schema.optionalKey(Schema.String),
  steps: Schema.Array(LiveStep),
  activity: Schema.optionalKey(Schema.Struct({ line: ActivityLine, since: Ms, at: Ms }))
})
/** Sent to ONE socket on join, on reconnect, after `run.live.get`; to every member after a step reset. */
export const RunLiveSnapshot = Schema.Struct({ type: Schema.Literal("run.live"), conversation: Schema.String, runs: Schema.Array(LiveRun) })
export type RunLiveSnapshot = typeof RunLiveSnapshot.Type

/** Client request on the conversation socket (`t` or `type` = "run.live.get"); answer: one `run.live`. */
export const RunLiveGet = Schema.Struct({ type: Schema.Literal("run.live.get"), conversation: Schema.String })

/** What a producer sends to the conversation owner (Cloud: ConversationDO.agentFrame `{live}`). */
export const LiveFrame = Schema.Union([StepDelta, RunActivity])
export type LiveFrame = typeof LiveFrame.Type
export const decodeLiveFrame = Schema.decodeUnknownExit(LiveFrame)

// ---------------------------------------------------------------------------------------------- Chief Protocol v0

/**
 * Chief Protocol (CP) v0 messages, named by method (hq-1f PROTOCOL.md). The HOST owns conversations
 * and fans out; the BRAIN runs the loop. Durable calls carry idempotency (run/step by run + step id,
 * conversation/post by client_msg_id); run/delta and run/activity are ephemeral and the host projects
 * them to clients as `step.delta` and `run.activity` above.
 */
export const WakeReason = Schema.Literals(["dm", "mention", "reply", "channel"])
/** host -> brain (notification). The brain pulls messages with conversation/read after `cursor`. */
export const ChiefWake = Schema.Struct({ wake_id: Schema.String, conversation: Schema.String, cursor: Seq, reason: WakeReason })
/** brain -> host: the wake's outcome; unacked wakes are sent again after a reconnect. */
export const ChiefAck = Schema.Struct({ wake_id: Schema.String, outcome: Schema.Literals(["answered", "skipped", "failed"]) })
export const RunStartParams = Schema.Struct({ run: Run })
export const RunStepParams = Schema.Struct({ run: RunId, step: Step })
export const RunDeltaParams = Schema.Struct({ run: RunId, step: StepId, kind: LiveKind, seq: Seq, text: DeltaText, final: Schema.optionalKey(Schema.Literal(true)) })
export const RunActivityParams = Schema.Struct({ run: RunId, line: ActivityLine, since: Ms })
export const RunEndParams = Schema.Struct({ run: Run })
export const ConversationPostParams = Schema.Struct({ conversation: Schema.String, client_msg_id: Schema.String, body: Schema.String, thread_root: Schema.optionalKey(Schema.String), run: Schema.optionalKey(RunId) })

/** One brain output call: `{method, params}`; the order of one wake is run/start, run/step|delta|activity..., run/end, conversation/post. */
export const BrainCall = Schema.Union([
  Schema.Struct({ method: Schema.Literal("run/start"), params: RunStartParams }),
  Schema.Struct({ method: Schema.Literal("run/step"), params: RunStepParams }),
  Schema.Struct({ method: Schema.Literal("run/delta"), params: RunDeltaParams }),
  Schema.Struct({ method: Schema.Literal("run/activity"), params: RunActivityParams }),
  Schema.Struct({ method: Schema.Literal("run/end"), params: RunEndParams }),
  Schema.Struct({ method: Schema.Literal("conversation/post"), params: ConversationPostParams }),
  Schema.Struct({ method: Schema.Literal("chief/ack"), params: ChiefAck })
])
export type BrainCall = typeof BrainCall.Type
export type ChiefWake = typeof ChiefWake.Type

export const BrainErrorCode = Schema.Literals(["disabled", "chief_archived", "chief_placed", "daily_turn_limit", "credits_exhausted", "model_unavailable", "model_failed", "timeout", "owner.unreachable"])
export class BrainError extends Schema.TaggedError<BrainError>()("BrainError", { code: BrainErrorCode, message: Schema.String }) {}

// ---------------------------------------------------------------------------------------------- models

/** Effort per Chief (pi-ai thinking levels). Default "low". */
export const Effort = Schema.Literals(["off", "minimal", "low", "medium", "high", "xhigh", "max"])
export type Effort = typeof Effort.Type
export const DEFAULT_EFFORT: Effort = "low"
export const DEFAULT_MODEL = "claude-opus-5-5"
/**
 * A model name: `fake` (tests), a Claude name served by the configured Bedrock route
 * (`claude-opus-5-5`, `claude-sonnet-5-5`, `claude-haiku-5-5`), `openrouter:<vendor>/<model>`, or a
 * Workers AI id `@cf/<vendor>/<model>`.
 */
export const ModelName = Schema.String.check(Schema.isPattern(/^(fake|claude-(opus|sonnet|haiku)-5-5|openrouter:[A-Za-z0-9._-]{1,64}\/[A-Za-z0-9._:-]{1,128}|@cf\/[a-z0-9._-]{1,64}\/[a-z0-9._-]{1,96})$/))
export const ChiefModelSettings = Schema.Struct({ model: ModelName, effort: Effort, compactor_model: ModelName })

// ---------------------------------------------------------------------------------------------- services

/** One brain implementation: a wake in, its CP calls out. `ModelGateway`, `Hands` and `Credits` are what it may use. */
export interface BrainShape {
  readonly wake: (wake: ChiefWake) => Stream.Stream<BrainCall, BrainError, ModelGateway | Hands | Credits>
}
export class Brain extends Context.Service<Brain, BrainShape>()("cmux/chief/Brain") {}

/**
 * CP `model/stream` (host capability `model_gateway`): Cloud brains reach models only through the
 * host, which owns keys, routes, caps and credits. Slice 2 fills the stream; today `offers` only.
 */
export interface ModelGatewayShape {
  readonly offers: (model: string) => boolean
}
export class ModelGateway extends Context.Service<ModelGateway, ModelGatewayShape>()("cmux/chief/ModelGateway") {}

/**
 * The Chief's hands (hand-do.ts, chief-brain/brain-hands.ts): typed requests to the owner's installed
 * hands (agent.*, fs.*, exec; hand-wire.ts HAND_ACTIONS). HandDO checks the caller's grant; each hand
 * checks its own local policy. Live: `handsLayer(env, caller)` in brain-hands.ts.
 */
export interface HandsShape {
  readonly list: () => Effect.Effect<ReadonlyArray<HandSummary>, HandsError>
  /** A single-use pairing code (10 min) and the install line for a new machine. */
  readonly pairCode: (name: string, profile: Profile) => Effect.Effect<Minted, HandsError>
  /** A new Freestyle sandbox with its hand installed and paired (hand-sandbox.ts). */
  readonly newSandbox: (name: string) => Effect.Effect<Sandbox, HandsError>
  /** A hand id, or the name of one of the owner's hands. */
  readonly resolve: (hand: string) => Effect.Effect<string, HandsError>
  readonly call: (hand: string, action: string, params: unknown, timeoutMs?: number) => Effect.Effect<unknown, HandsError>
  /** Events of an agent session after `afterSeq`; waits up to `waitMs` for the first new one. */
  readonly events: (hand: string, session: string, afterSeq: number, waitMs: number) => Effect.Effect<{ events: ReadonlyArray<StoredEvent>; last_seq: number; head_seq: number }, HandsError>
}
export class Hands extends Context.Service<Hands, HandsShape>()("cmux/chief/Hands") {}
