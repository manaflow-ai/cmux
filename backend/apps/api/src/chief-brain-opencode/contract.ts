import { Schema } from "effect"

/**
 * Chief Protocol v0 shapes that the O host side reads (hq-1f PROTOCOL.md). This is O's copy until
 * the shared `chief-brain/contract.ts` (owner 1f-P) lands; then this file re-exports from it.
 *
 * Brain -> host notifications arrive on the opencode server's event stream as the plugin's RPC
 * event `rpc.cmux-chief.cp` with data `{jsonrpc: "2.0", method, params}`. Steps and runs are the
 * TRAJECTORIES.md shapes; the decoder keeps unknown fields, so the brain may add metrics.
 */
const Usage = Schema.Struct({ input: Schema.Number, output: Schema.Number, cache_read: Schema.Number, cache_write: Schema.Number })

export const CpRun = Schema.StructWithRest(
  Schema.Struct({
    id: Schema.String,
    conversation: Schema.String,
    status: Schema.Literals(["running", "done", "failed", "cancelled"]),
    started_at: Schema.Number,
    ended_at: Schema.optional(Schema.Number),
    model: Schema.optional(Schema.String),
    usage: Schema.optional(Usage),
    cost_usd: Schema.optional(Schema.Number),
    error: Schema.optional(Schema.String)
  }),
  [Schema.Record(Schema.String, Schema.Unknown)]
)
export type CpRun = typeof CpRun.Type

export const CpStep = Schema.StructWithRest(
  Schema.Struct({
    id: Schema.String,
    kind: Schema.Literals(["talk", "thought", "tool", "note"]),
    status: Schema.optional(Schema.Literals(["running", "done", "failed"])),
    text: Schema.optional(Schema.String),
    tool: Schema.optional(Schema.Record(Schema.String, Schema.Unknown))
  }),
  [Schema.Record(Schema.String, Schema.Unknown)]
)
export type CpStep = typeof CpStep.Type

export const CpNote = Schema.Union([
  Schema.Struct({ jsonrpc: Schema.Literal("2.0"), method: Schema.Literal("run/start"), params: Schema.Struct({ run: CpRun, seq: Schema.Number }) }),
  Schema.Struct({ jsonrpc: Schema.Literal("2.0"), method: Schema.Literal("run/step"), params: Schema.Struct({ run: Schema.String, step: CpStep, seq: Schema.Number }) }),
  Schema.Struct({ jsonrpc: Schema.Literal("2.0"), method: Schema.Literal("run/delta"), params: Schema.Struct({ run: Schema.String, step: Schema.String, kind: Schema.String, text: Schema.String, seq: Schema.Number }) }),
  Schema.Struct({ jsonrpc: Schema.Literal("2.0"), method: Schema.Literal("run/activity"), params: Schema.Struct({ run: Schema.String, line: Schema.String, since: Schema.Number, seq: Schema.Number }) }),
  Schema.Struct({ jsonrpc: Schema.Literal("2.0"), method: Schema.Literal("run/end"), params: Schema.Struct({ run: CpRun, seq: Schema.Number }) })
])
export type CpNote = typeof CpNote.Type
export const decodeNote = Schema.decodeUnknownOption(CpNote)

/** `chief/wake` (host -> brain). */
export interface CpWake {
  readonly wake_id: string
  readonly conversation: string
  readonly cursor: number
  readonly reason: string
}

/** JSON-RPC 2.0 request (brain -> host). */
export const CpRequest = Schema.Struct({ jsonrpc: Schema.Literal("2.0"), id: Schema.Union([Schema.Number, Schema.String]), method: Schema.String, params: Schema.optional(Schema.Unknown) })
export const decodeRequest = Schema.decodeUnknownOption(CpRequest)
