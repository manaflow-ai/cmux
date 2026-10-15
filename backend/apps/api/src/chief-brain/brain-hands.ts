import { Type, type Static } from "@earendil-works/pi-ai"
import type { ToolRegistration } from "@earendil-works/pi-durable"
import { Effect, Layer } from "effect"
import type { Env } from "../env.ts"
import { apiOrigin, handStub, listHands, mintPairCode, resolveHand } from "../hand-api.ts"
import { HandsError, type AgentEvent, type HandCaller, type HandReply } from "../hand-wire.ts"
import { Hands } from "./contract.ts"
import type { StepPatch } from "./brain-runs.ts"

/**
 * The Chief's hands: the live `Hands` service (contract.ts) and two brain tools: `hands` (files and
 * programs on a hand) and `agent` (acpmux agent sessions on a hand: claude, codex, opencode).
 *
 * The caller is the Chief (agent + owner), built by the brain in server code. HandDO checks the
 * Chief's `hands` grant and the hand's owner; the hand checks its own local policy. Agent session
 * events come back while the tool waits and are reported as `step.upsert` (the tool step's text)
 * and `run.activity` (one present-tense line with elapsed time, newest wins), for example
 * `Running codex in sb-3 · 12s`.
 */

const unwrap = <A>(r: HandReply<A>): Effect.Effect<A, HandsError> => (r.ok ? Effect.succeed(r.value) : Effect.fail(new HandsError(r.error.code, r.error.message)))
const rpc = <A>(f: () => Promise<HandReply<A>>) =>
  Effect.flatMap(Effect.tryPromise({ try: f, catch: (e) => new HandsError("hand.unreachable", e instanceof Error ? e.message : String(e)) }), unwrap)

/** The live service for one Chief of one owner. */
export const handsLayer = (env: Env, caller: HandCaller) =>
  Layer.succeed(Hands)(
    Hands.of({
      list: () => rpc(() => listHands(env, caller)),
      pairCode: (name, profile) => rpc(() => mintPairCode(env, caller, name, apiOrigin(env), profile)),
      resolve: (hand) => rpc(() => resolveHand(env, caller, hand)),
      call: (hand, action, params, timeoutMs) => rpc(() => handStub(env, hand).call(caller, action, params, timeoutMs)),
      events: (hand, session, afterSeq, waitMs) => rpc(() => handStub(env, hand).events(caller, session, afterSeq, waitMs))
    })
  )

// --- Reporting (the brain's BrainEvent stream) ---

/** What a hands tool reports while it runs; the brain maps these to BrainEvents of the current run. */
export type HandsReport = { readonly type: "run.activity"; readonly line: string; readonly at: number } | { readonly type: "step.upsert"; readonly step: StepPatch }
export type HandsReporter = (r: HandsReport) => void

const ACTIVITY_MAX = 80
const fit = (line: string) => (line.length <= ACTIVITY_MAX ? line : `${line.slice(0, ACTIVITY_MAX - 1)}…`)
const secs = (ms: number) => `${Math.max(0, Math.round(ms / 1000))}s`

/** `Running codex in sb-3 · 12s`, or the agent's current tool: `codex: Edit src/app.ts in sb-3 · 12s`. */
export const activityLine = (harness: string, handName: string, tool: string | undefined, elapsedMs: number) =>
  fit(tool ? `${harness}: ${tool} in ${handName} · ${secs(elapsedMs)}` : `Running ${harness} in ${handName} · ${secs(elapsedMs)}`)

// --- Agent turn wait ---

export interface TurnSummary {
  readonly session: string
  readonly done: boolean
  readonly stop_reason?: string
  readonly text: string
  readonly tools: ReadonlyArray<string>
  readonly permissions: ReadonlyArray<{ id?: string; title?: string }>
  readonly errors: ReadonlyArray<string>
  readonly last_seq: number
}

/**
 * Follows `session` from `afterSeq` until its turn ends or `budgetMs` passes, reporting activity.
 * Event-driven: each `events` call returns as soon as the hand sends something (HandDO wakes it).
 */
export const followTurn = (hand: string, handName: string, harness: string, session: string, afterSeq: number, budgetMs: number, report: HandsReporter, callId: string) =>
  Effect.gen(function* () {
    const hands = yield* Hands
    const started = Date.now()
    let seq = afterSeq
    let text = ""
    let tool: string | undefined
    const tools: Array<string> = []
    const permissions: Array<{ id?: string; title?: string }> = []
    const errors: Array<string> = []
    let stop: string | undefined
    let done = false
    report({ type: "run.activity", line: activityLine(harness, handName, undefined, 0), at: started })
    while (!done && Date.now() - started < budgetMs) {
      const page = yield* hands.events(hand, session, seq, Math.min(25_000, budgetMs - (Date.now() - started)))
      for (const { event } of page.events as ReadonlyArray<{ event: AgentEvent }>) {
        if (event.kind === "text") text += event.text
        if (event.kind === "tool" && event.title) {
          tool = event.title
          if (!event.update) tools.push(event.title)
        }
        if (event.kind === "permission") permissions.push({ id: event.permission_id, title: event.title })
        if (event.kind === "error") errors.push(event.message ?? "agent error")
        if (event.kind === "turn_end") {
          done = true
          stop = event.stop_reason
        }
      }
      seq = page.last_seq
      const now = Date.now()
      report({ type: "run.activity", line: activityLine(harness, handName, done ? undefined : tool, now - started), at: now })
      if (page.events.length > 0) {
        report({ type: "step.upsert", step: { id: `tool:${callId}`, kind: "tool", status: "running", text: `${harness} in ${handName}: ${tools.length} tool calls${tool ? `, now ${tool}` : ""}` } })
      }
      // A waiting permission stops the agent until someone answers; say so instead of waiting out the budget.
      if (permissions.length > 0 && !done) break
    }
    return { session, done, stop_reason: stop, text: text.slice(-8_000), tools, permissions, errors, last_seq: seq } satisfies TurnSummary
  })

// --- Tools ---

const HandsArgs = Type.Object({
  action: Type.Union([Type.Literal("list"), Type.Literal("pair_code"), Type.Literal("read"), Type.Literal("write"), Type.Literal("edit"), Type.Literal("patch"), Type.Literal("ls"), Type.Literal("glob"), Type.Literal("grep"), Type.Literal("exec")], {
    description: "list: your hands. pair_code: a single-use code + install line for a new machine. read/write/edit/patch/ls/glob/grep: files on a hand. exec: run a program (sandbox hands only)."
  }),
  hand: Type.Optional(Type.String({ description: "Hand id (hand_...) or its name. Required except for list and pair_code." })),
  path: Type.Optional(Type.String({ description: "Absolute path (or relative to cwd)." })),
  cwd: Type.Optional(Type.String({ description: "Folder for relative paths, patch and exec." })),
  text: Type.Optional(Type.String({ description: "write: the whole new file." })),
  edits: Type.Optional(Type.Array(Type.Object({ old: Type.String(), new: Type.String() }), { description: "edit: exact replacements; each old must match exactly once." })),
  expect_sha256: Type.Optional(Type.String({ description: "edit (required) / write: the sha256 from your last read; 'absent' for a new file. Stops you writing over a newer change." })),
  patch: Type.Optional(Type.String({ description: "patch: a unified diff (paths relative to cwd)." })),
  pattern: Type.Optional(Type.String({ description: "glob: e.g. src/**/*.ts. grep: a regex." })),
  glob: Type.Optional(Type.String({ description: "grep: only files matching this glob." })),
  root: Type.Optional(Type.String({ description: "glob/grep: the folder to search." })),
  start_line: Type.Optional(Type.Integer()),
  end_line: Type.Optional(Type.Integer()),
  argv: Type.Optional(Type.Array(Type.String(), { description: "exec: program and arguments (no shell unless you name one)." })),
  timeout_ms: Type.Optional(Type.Integer()),
  name: Type.Optional(Type.String({ description: "pair_code: a name for the new hand." })),
  profile: Type.Optional(Type.Union([Type.Literal("sandbox"), Type.Literal("mac")]))
})
type HandsArgsT = Static<typeof HandsArgs>

const AgentArgs = Type.Object({
  action: Type.Union([Type.Literal("start"), Type.Literal("send"), Type.Literal("wait"), Type.Literal("cancel"), Type.Literal("deny"), Type.Literal("events")], {
    description: "start: a new agent session with a first prompt. send: another prompt. wait: follow the running turn. cancel: stop the turn. deny: refuse a permission the agent asked for. events: raw event page."
  }),
  hand: Type.String({ description: "Hand id (hand_...) or its name." }),
  harness: Type.Optional(Type.Union([Type.Literal("claude"), Type.Literal("codex"), Type.Literal("opencode")])),
  cwd: Type.Optional(Type.String({ description: "start: the project folder on the hand." })),
  prompt: Type.Optional(Type.String()),
  model: Type.Optional(Type.String()),
  effort: Type.Optional(Type.String()),
  session: Type.Optional(Type.String({ description: "send/wait/cancel/deny/events: the session id start returned." })),
  permission_id: Type.Optional(Type.String()),
  after_seq: Type.Optional(Type.Integer({ description: "wait/events: continue after this seq (last_seq of the previous answer)." })),
  wait_seconds: Type.Optional(Type.Integer({ description: "start/send/wait: follow the turn this long (default 120, max 600, 0 = return at once)." }))
})
type AgentArgsT = Static<typeof AgentArgs>

const need = (v: string | undefined, what: string): Effect.Effect<string, HandsError> => (v ? Effect.succeed(v) : Effect.fail(new HandsError("request.invalid", `${what} is required`)))

const WIRE: Readonly<Record<string, string>> = { read: "fs.read", write: "fs.write", edit: "fs.edit", patch: "fs.patch", ls: "fs.list", glob: "fs.glob", grep: "fs.grep", exec: "exec" }

export const handsProgram = (a: HandsArgsT) =>
  Effect.gen(function* () {
    const hands = yield* Hands
    if (a.action === "list") return yield* hands.list()
    if (a.action === "pair_code") return yield* hands.pairCode(a.name ?? "hand", a.profile ?? "sandbox")
    const hand = yield* hands.resolve(yield* need(a.hand, "hand"))
    const { action: _a, hand: _h, ...params } = a
    if (a.action === "glob" || a.action === "grep") (params as Record<string, unknown>).root ??= a.cwd ?? a.path
    // The hand enforces timeout_ms on the program; the Cloud waits a little longer for the answer.
    const wait = a.action === "exec" ? Math.min(a.timeout_ms ?? 120_000, 600_000) + 15_000 : 60_000
    return yield* hands.call(hand, WIRE[a.action]!, params, wait)
  })

export const agentProgram = (a: AgentArgsT, report: HandsReporter, callId: string) =>
  Effect.gen(function* () {
    const hands = yield* Hands
    const hand = yield* hands.resolve(a.hand)
    const handName = (yield* hands.list()).find((h) => h.hand === hand)?.name ?? hand
    const budget = Math.min(Math.max(a.wait_seconds ?? 120, 0), 600) * 1000
    const harness = a.harness ?? "agent"
    if (a.action === "start") {
      const started = (yield* hands.call(hand, "agent.start", { harness: yield* need(a.harness, "harness"), cwd: yield* need(a.cwd, "cwd"), prompt: yield* need(a.prompt, "prompt"), model: a.model, effort: a.effort }, 60_000)) as { session: string }
      if (budget === 0) return started
      return yield* followTurn(hand, handName, harness, started.session, 0, budget, report, callId)
    }
    const session = yield* need(a.session, "session")
    // Follow from where the session is now, so an earlier turn's end is not read again.
    const head = a.after_seq ?? (yield* hands.events(hand, session, 0, 0)).head_seq
    if (a.action === "send") {
      const sent = yield* hands.call(hand, "agent.send", { session, prompt: yield* need(a.prompt, "prompt") })
      if (budget === 0) return sent
      return yield* followTurn(hand, handName, harness, session, head, budget, report, callId)
    }
    if (a.action === "wait") return yield* followTurn(hand, handName, harness, session, head, budget || 120_000, report, callId)
    if (a.action === "cancel") return yield* hands.call(hand, "agent.cancel", { session })
    if (a.action === "deny") return yield* hands.call(hand, "agent.deny", { session, permission_id: yield* need(a.permission_id, "permission_id") })
    return yield* hands.events(hand, session, a.after_seq ?? 0, 0)
  })

const asText = (v: unknown) => (typeof v === "string" ? v : JSON.stringify(v, null, 2))
const run = <A>(env: Env, caller: HandCaller | null, program: Effect.Effect<A, HandsError, Hands>): Promise<string> =>
  caller === null
    ? Promise.resolve("hands: this brain has no chief yet")
    : Effect.runPromise(
        program.pipe(
          Effect.map(asText),
          Effect.catch((e: HandsError) => Effect.succeed(`hands error ${e.code}: ${e.message}`)),
          Effect.provide(handsLayer(env, caller))
        )
      )

/**
 * The `hands` and `agent` tools for a brain whose `who()` names its chief and owner. `report` sends
 * activity and step updates of the current run (the brain hook maps them to BrainEvents).
 */
export const handsTools = (
  env: Env,
  who: () => { agent: string | null; owner: string | null },
  report: HandsReporter = () => undefined
): [ToolRegistration<typeof HandsArgs>, ToolRegistration<typeof AgentArgs>] => {
  const caller = (): HandCaller | null => {
    const { agent, owner } = who()
    return agent && owner ? { kind: "chief", user: owner, agent } : null
  }
  return [
    {
      name: "hands",
      description:
        "Files and programs on your hands (machines that run cmux-hand: sandboxes, and later the person's Mac). Read a file to get its sha256, then edit with exact {old,new} pairs and that expect_sha256; a stale sha means someone changed the file: read again.",
      parameters: HandsArgs,
      replay: "unsafe",
      execute: async (args) => ({ content: [{ type: "text", text: await run(env, caller(), handsProgram(args as HandsArgsT)) }] })
    },
    {
      name: "agent",
      description:
        "Coding agents (claude, codex, opencode) on a hand, through acpmux with the hand's own permission policy. start returns when the turn ends or wait_seconds passes, with the agent's last text, its tool calls and any permission it waits for; continue with wait (after_seq = last_seq).",
      parameters: AgentArgs,
      replay: "unsafe",
      execute: async (args, api) => ({ content: [{ type: "text", text: await run(env, caller(), agentProgram(args as AgentArgsT, report, api.callId)) }] })
    }
  ]
}
