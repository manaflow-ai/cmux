/**
 * cmux-chief: the opencode v2 Effect plugin that makes an opencode server a Chief BRAIN of the
 * Chief Protocol (CP v0, hq-1f PROTOCOL.md). Implementation O of the Cloud Chief.
 *
 * Roles. The HOST owns conversations, identity, grants, credits, hands and the model gateway (in
 * the Cloud: OpencodeBrainDO in front of ConversationDO, MuxDO, UserDO). This plugin is the BRAIN:
 * it owns the loop (one opencode session per conversation), the prompt and the model calls.
 *
 * Transport (one opencode server per Chief, in a container the host starts):
 *   host -> brain  `chief/wake` as the opencode RPC `POST /api/rpc/cmux-chief/wake` (also `status`, `cancel`)
 *   brain -> host  requests (initialize, conversation/read, conversation/post, chief/ack, chiefs/*,
 *                  hands/list, hand/call) as JSON-RPC 2.0 over HTTP POST to `host.url`, chief token auth
 *   brain -> host  notifications (run/start, run/step, run/delta, run/activity, run/end) as the
 *                  opencode RPC event `rpc.cmux-chief.cp` ({jsonrpc, method, params}); the host reads
 *                  them from the server's `/api/event` stream (no round trip per token)
 *
 * The brain PULLS: a wake names a conversation and a cursor; the brain reads what the host lets this
 * Chief see (conversation/read), answers, posts (conversation/post, idempotent by client_msg_id =
 * the run id) and acks (chief/ack). A restarted brain repeats a wake and cannot double-post.
 *
 * Models: one provider, `cmux-gateway`, Anthropic Messages shape toward the host's model gateway
 * (the host holds keys, credits and caps; chief-token auth). Every Claude or OpenRouter model goes
 * through it. The `http.request` hook gives each `cache_control` mark a 1 h TTL. The `context`
 * hook gives Chief sessions the Chief's system prompt and only the cmux tools (no shell, no files).
 */
import { appendFileSync } from "node:fs"
import { Plugin, Rpc } from "@opencode/plugin/effect"
import { Effect, Schedule, Schema, Stream } from "effect"
import { readOptions, GATEWAY, EFFORTS, KNOWN, modelInfo, isNoReply, clip, oneLine, systemPrompt, formatMessage, toolActivity } from "./chief.ts"
import type { Json, Usage, Read, Initialized } from "./chief.ts"

// ---------------------------------------------------------------- RPC (host -> brain)

/** `chief/wake` (CP v0). */
const Wake = Schema.Struct({
  wake_id: Schema.String,
  conversation: Schema.String,
  cursor: Schema.Number,
  reason: Schema.String
})
type Wake = typeof Wake.Type

const ChiefRpc = Rpc.define({
  id: "cmux-chief",
  methods: {
    wake: { input: Wake, output: Schema.Struct({ run: Schema.String, accepted: Schema.Boolean }) },
    status: { input: Schema.Struct({ run: Schema.String }), output: Schema.Struct({ state: Schema.Literals(["running", "done", "failed", "unknown"]), run: Schema.optional(Schema.Record(Schema.String, Schema.Unknown)) }) },
    cancel: { input: Schema.Struct({ run: Schema.String }), output: Schema.Struct({ cancelled: Schema.Boolean }) }
  },
  events: { cp: { schema: { type: "object" } as const } }
})

// ---------------------------------------------------------------- run state

interface RunState {
  readonly run: string
  readonly wake: Wake
  readonly session: string
  readonly model: string
  readonly started: number
  firstAny?: number
  firstText?: number
  seq: number
  usage: Usage
  cost: number
  steps: number
  calls: number
  readonly perCall: Array<Usage>
  readonly tools: Map<string, string>
  lastTalk: string
  activityAt: number
  status: "running" | "done" | "failed"
  error?: string
  /** The newest message the turn read: the host's cursor after the ack. */
  cursor: number
  answers: Array<string>
  replyTo?: { message: string; thread_root?: string; kind: string; shared?: boolean }
}

class HostError extends Schema.TaggedError<HostError>()("HostError", { method: Schema.String, message: Schema.String }) {}

/** Success or the host's error as a value (a failed host call becomes tool text or a failed run, never a defect). */
const attempt = <A>(e: Effect.Effect<A, HostError>) =>
  e.pipe(
    Effect.map((value) => ({ ok: true as const, value })),
    Effect.catch((error: HostError) => Effect.succeed({ ok: false as const, error }))
  )

// ---------------------------------------------------------------- the plugin

export default Plugin.define({
  id: "cmux-chief",
  effect: Effect.fn(function* (ctx) {
    const opts = readOptions(ctx.options)
    const token = process.env[opts.tokenEnv ?? "CMUX_CHIEF_TOKEN"] ?? ""
    const bySession = new Map<string, RunState>()
    const byRun = new Map<string, RunState>()
    const chiefSessions = new Map<string, string>()
    const models = new Set<string>(Object.keys(KNOWN))
    let me: { chief: Initialized["chief"]; at: number } | undefined

    // ------------------------------------------------ brain -> host requests
    let nextId = 0
    const host = <T>(method: string, params: unknown): Effect.Effect<T, HostError> =>
      Effect.tryPromise({
        try: async () => {
          if (!opts.host) throw new Error("no host configured")
          const r = await fetch(opts.host, {
            method: "POST",
            headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
            body: JSON.stringify({ jsonrpc: "2.0", id: ++nextId, method, params })
          })
          const body = (await r.json()) as { result?: T; error?: { message?: string } }
          if (body.error || !r.ok) throw new Error(body.error?.message ?? `HTTP ${r.status}`)
          return body.result as T
        },
        catch: (e) => new HostError({ method, message: e instanceof Error ? e.message : String(e) })
      })

    // ------------------------------------------------ the gateway provider
    yield* ctx.provider.transform((editor) => {
      if (!opts.gateway) return
      editor.add({
        info: { id: GATEWAY, name: "cmux model gateway", activation: "enabled", package: "@opencode/ai/providers/anthropic", settings: { baseURL: opts.gateway, apiKey: token || "none" } } as never,
        models: [...models].map((id) => modelInfo(id, opts.modelIds?.[id] ?? id))
      })
    })
    yield* ctx.model.transform((editor) => {
      if (opts.gateway) editor.default.set(GATEWAY, "claude-opus-5-5")
    })

    // ------------------------------------------------ brain -> host notifications
    const reg = yield* ctx.rpc.register(ChiefRpc, {
      wake: (input) => wake(input),
      status: ({ run }) => status(run),
      cancel: ({ run }) => cancel(run)
    })
    const notify = (s: RunState, method: string, params: Record<string, Json>) => {
      s.seq += 1
      return reg.events.emit("cp", { jsonrpc: "2.0", method, params: { ...params, seq: s.seq } }).pipe(Effect.ignore)
    }

    const runJson = (s: RunState, now: number): Record<string, Json> => ({
      id: s.run,
      conversation: s.wake.conversation,
      status: s.status,
      started_at: s.started,
      ...(s.status === "running" ? {} : { ended_at: now }),
      answers: s.answers,
      ...(s.replyTo?.thread_root ? { thread_root: s.replyTo.thread_root } : {}),
      model: s.model,
      harness: "opencode",
      session: { kind: "opencode", id: s.session },
      step_count: s.steps,
      usage: { ...s.usage },
      cost_usd: Math.round(s.cost * 1e6) / 1e6,
      ...(s.error ? { error: s.error.slice(0, 2000) } : {}),
      /** The newest message seq this turn read: the host moves the Chief's cursor to it. */
      cursor: s.cursor,
      metrics: {
        first_token_ms: s.firstAny === undefined ? null : s.firstAny - s.started,
        first_text_ms: s.firstText === undefined ? null : s.firstText - s.started,
        turn_ms: s.status === "running" ? null : now - s.started,
        model_calls: s.calls,
        per_call: s.perCall.map((u) => ({ ...u })),
        cache_hit: s.usage.cache_read + s.usage.cache_write + s.usage.input === 0 ? null : Math.round((1000 * s.usage.cache_read) / (s.usage.cache_read + s.usage.cache_write + s.usage.input)) / 10
      }
    })
    const activity = (s: RunState, what: string) =>
      Effect.suspend(() => {
        s.activityAt = Date.now()
        return notify(s, "run/activity", { run: s.run, line: oneLine(what, 80), since: s.started })
      })
    const step = (s: RunState, body: Record<string, Json>) => notify(s, "run/step", { run: s.run, step: body })

    // ------------------------------------------------ wake: pull, prompt, stream
    const sessionFor = (conversation: string, ref: { providerID: string; id: string; variant: string }) =>
      Effect.gen(function* () {
        if (!models.has(ref.id)) {
          models.add(ref.id)
          yield* ctx.provider.reload()
        }
        const key = `session:${conversation}`
        const known = yield* ctx.storage.get(key)
        if (typeof known === "string") {
          const alive = yield* ctx.session.get({ sessionID: known as never }).pipe(Effect.as(true), Effect.orElseSucceed(() => false))
          if (alive) {
            yield* ctx.session.switchModel({ sessionID: known as never, model: ref as never }).pipe(Effect.ignore)
            return { id: known, fresh: false }
          }
        }
        const made = yield* ctx.session.create({ title: `cmux ${conversation}`, model: ref as never }).pipe(Effect.orDie)
        yield* ctx.storage.set(key, made.id)
        return { id: String(made.id), fresh: true }
      })

    const wake = (w: Wake) =>
      Effect.gen(function* () {
        const run = `run_${w.wake_id}`
        // A repeated wake (the host lost the answer, or the brain restarted) attaches to the same run.
        if (byRun.has(run)) return { run, accepted: false }
        // The profile (model, role, instructions) is read again at most once a minute: an owner's edit reaches the next turn.
        if (!me || Date.now() - me.at > 60_000) me = { chief: (yield* host<Initialized>("initialize", { protocol: 1, brain: { impl: "opencode", version: "cmux-chief/0" }, capabilities: { stream: true, thinking: true, resume: true } })).chief, at: Date.now() }
        const chief = me.chief
        const effort = EFFORTS.includes((chief.effort ?? "low") as (typeof EFFORTS)[number]) ? (chief.effort ?? "low") : "low"
        const ref = { providerID: GATEWAY, id: chief.model ?? "claude-opus-5-5", variant: effort }
        const session = yield* sessionFor(w.conversation, ref)
        // A turn still running in this session (the host gave up on it) ends now, so its events cannot land on the new run.
        const stale = bySession.get(session.id)
        if (stale) {
          yield* ctx.session.interrupt({ sessionID: session.id as never }).pipe(Effect.ignore)
          yield* finish(stale, "failed", "superseded by a newer wake")
        }
        chiefSessions.set(session.id, systemPrompt(chief))
        const now = Date.now()
        const s: RunState = {
          run, wake: w, session: session.id, model: ref.id, started: now, seq: 0,
          usage: { input: 0, output: 0, cache_read: 0, cache_write: 0 }, cost: 0, steps: 0, calls: 0, perCall: [], tools: new Map(),
          lastTalk: "", activityAt: now, status: "running", cursor: w.cursor, answers: []
        }
        bySession.set(session.id, s)
        byRun.set(run, s)
        if (byRun.size > 500) byRun.delete(byRun.keys().next().value!)
        yield* pull(s, session.fresh).pipe(Effect.catch((e: HostError) => finish(s, "failed", `${e.method}: ${e.message}`)))
        return { run, accepted: true }
      }).pipe(Effect.catch((e: HostError) => Effect.die(new Error(`${e.method}: ${e.message}`))))

    /** Read the conversation after the cursor (further back for a new session) and prompt the session. */
    const pull = (s: RunState, freshSession: boolean) =>
      Effect.gen(function* () {
        const w = s.wake
        const now = s.started
        // A new session (first wake, or a new container) reads back further: the conversation is the memory of record.
        const read = yield* host<Read>("conversation/read", { _turn_wake: w.wake_id, conversation: w.conversation, after: freshSession ? Math.max(0, w.cursor - 40) : w.cursor, limit: freshSession ? 50 : 20 })
        const fresh = read.messages.filter((m) => m.seq > w.cursor && m.author.kind !== "self")
        const older = read.messages.filter((m) => m.seq <= w.cursor)
        s.cursor = Math.max(w.cursor, ...read.messages.map((m) => m.seq))
        s.answers = fresh.map((m) => m.id)
        const last = fresh.at(-1)
        if (last) s.replyTo = { message: last.id, kind: read.conversation.kind, ...(read.conversation.shared ? { shared: true } : {}), ...(last.thread_root ? { thread_root: last.thread_root } : {}) }
        yield* notify(s, "run/start", { run: runJson(s, now) })
        if (fresh.length === 0) return yield* finish(s, "done")
        yield* activity(s, "Thinking")
        const text = [
          ...(older.length > 0 ? [`Earlier in this conversation (for context):\n${older.map((m) => formatMessage(read.conversation, m)).join("\n")}\n\nNew:`] : []),
          fresh.map((m) => formatMessage(read.conversation, m)).join("\n\n")
        ].join("\n")
        yield* ctx.session.prompt({ sessionID: s.session as never, text, metadata: { cmux_run: s.run }, delivery: "queue" }).pipe(
          Effect.catchCause((cause) => finish(s, "failed", `prompt refused: ${String(cause).slice(0, 300)}`))
        )
      })

    const status = (run: string) =>
      Effect.gen(function* () {
        const s = byRun.get(run)
        if (s) return { state: s.status, run: runJson(s, Date.now()) as Record<string, unknown> }
        const stored = yield* ctx.storage.get(`run:${run}`)
        return stored && typeof stored === "object" ? (stored as never) : { state: "unknown" as const }
      })

    const cancel = (run: string) =>
      Effect.gen(function* () {
        const s = byRun.get(run)
        if (!s || s.status !== "running") return { cancelled: false }
        yield* ctx.session.interrupt({ sessionID: s.session as never }).pipe(Effect.ignore)
        return { cancelled: true }
      })

    /** Post (idempotent by client_msg_id = run id), end the run, ack the wake. */
    const finish = (s: RunState, status: "done" | "failed", error?: string) =>
      Effect.gen(function* () {
        if (s.status !== "running") return
        s.status = status
        if (error) s.error = error
        const reply = s.lastTalk.trim()
        let outcome: "answered" | "skipped" | "failed" = status === "done" ? "skipped" : "failed"
        if (status === "done" && reply && !isNoReply(reply)) {
          const posted = yield* host<{ message: string | null }>("conversation/post", {
            _turn_wake: s.wake.wake_id, conversation: s.wake.conversation, client_msg_id: `chief-reply:${s.run}`, body: reply, run: s.run,
            // A shared Chief conversation (several people): the reply quotes the message it answers, on the main timeline.
            ...(s.replyTo && s.replyTo.kind !== "chief" && s.replyTo.kind !== "dm" ? { reply_to: s.replyTo.message, thread_root: s.replyTo.thread_root ?? s.replyTo.message } : s.replyTo?.thread_root || s.replyTo?.shared ? { reply_to: s.replyTo.message, ...(s.replyTo.thread_root ? { thread_root: s.replyTo.thread_root } : {}) } : {})
          }).pipe(attempt)
          if (!posted.ok) {
            s.status = "failed"
            s.error = `conversation/post: ${posted.error.message}`
          } else outcome = "answered"
        }
        const run = runJson(s, Date.now())
        yield* notify(s, "run/end", { run })
        bySession.delete(s.session)
        yield* ctx.storage.set(`run:${s.run}`, { state: s.status, run } as never).pipe(Effect.ignore)
        yield* host("chief/ack", { _turn_wake: s.wake.wake_id, wake_id: s.wake.wake_id, outcome: s.status === "failed" ? "failed" : outcome, cursor: s.cursor }).pipe(Effect.ignore)
      })

    // ------------------------------------------------ opencode events -> run/*
    const onEvent = (ev: { type: string; data?: unknown }) =>
      Effect.gen(function* () {
        const d = (ev.data ?? {}) as Record<string, unknown>
        const s = typeof d.sessionID === "string" ? bySession.get(d.sessionID) : undefined
        if (!s) return
        const now = Date.now()
        const key = (prefix: string) => `${prefix}:${String(d.assistantMessageID)}:${String(d.ordinal ?? 0)}`
        switch (ev.type) {
          case "session.step.started":
            s.calls += 1
            return
          case "session.reasoning.delta":
            if (s.firstAny === undefined) s.firstAny = now
            yield* notify(s, "run/delta", { run: s.run, step: key("thought"), kind: "thought", text: String(d.delta ?? "") })
            if (now - s.activityAt > 1000) yield* activity(s, "Thinking")
            return
          case "session.reasoning.ended":
            if (!String(d.text ?? "").trim()) return
            s.steps += 1
            return yield* step(s, { id: key("thought"), kind: "thought", text: clip(String(d.text)) })
          case "session.text.delta":
            if (s.firstAny === undefined) s.firstAny = now
            if (s.firstText === undefined) s.firstText = now
            return yield* notify(s, "run/delta", { run: s.run, step: key("talk"), kind: "talk", text: String(d.delta ?? "") })
          case "session.text.ended": {
            const text = String(d.text ?? "")
            if (!text.trim()) return
            s.lastTalk = text
            s.steps += 1
            return yield* step(s, { id: key("talk"), kind: "talk", text: clip(text) })
          }
          case "session.tool.input.started": {
            const name = String(d.name ?? "tool")
            s.tools.set(String(d.id), name)
            s.steps += 1
            return yield* step(s, { id: `tool:${String(d.id)}`, kind: "tool", status: "running", tool: { name, started_at: now } })
          }
          case "session.tool.called": {
            const name = s.tools.get(String(d.id)) ?? "tool"
            const input = (d.input ?? {}) as Record<string, unknown>
            yield* step(s, { id: `tool:${String(d.id)}`, kind: "tool", status: "running", tool: { name, input: input as Json } })
            return yield* activity(s, toolActivity(name, input))
          }
          case "session.tool.success":
          case "session.tool.failed": {
            const parts = (d.content ?? []) as ReadonlyArray<{ type: string; text?: string }>
            const out = parts.filter((p) => p.type === "text").map((p) => p.text ?? "").join("")
            const err = ev.type === "session.tool.failed" ? String((d.error as { message?: string } | undefined)?.message ?? "failed") : undefined
            yield* step(s, { id: `tool:${String(d.id)}`, kind: "tool", status: err ? "failed" : "done", tool: { output: clip(err ? `${err}\n${out}`.trim() : out), ended_at: now } })
            return yield* activity(s, "Thinking")
          }
          case "session.step.ended":
          case "session.step.failed": {
            const t = d.tokens as { input?: number; output?: number; reasoning?: number; cache?: { read?: number; write?: number } } | undefined
            if (t) {
              const u = { input: t.input ?? 0, output: (t.output ?? 0) + (t.reasoning ?? 0), cache_read: t.cache?.read ?? 0, cache_write: t.cache?.write ?? 0 }
              s.perCall.push(u)
              s.usage.input += u.input
              s.usage.output += u.output
              s.usage.cache_read += u.cache_read
              s.usage.cache_write += u.cache_write
            }
            if (typeof d.cost === "number") s.cost += d.cost
            return
          }
          case "session.execution.succeeded":
            return yield* finish(s, "done")
          case "session.execution.failed":
            return yield* finish(s, "failed", String((d.error as { message?: string } | undefined)?.message ?? "the turn failed"))
          case "session.execution.interrupted":
            return yield* finish(s, "failed", `interrupted (${String(d.reason ?? "unknown")})`)
          default:
            return
        }
      })

    // The feed fails a slow subscriber: subscribe again (events in the gap are missed; the host asks `status`).
    yield* ctx.event.subscribe().pipe(
      Stream.runForEach((ev) => onEvent(ev as { type: string; data?: unknown }).pipe(Effect.catchCause((cause) => Effect.logWarning("cmux-chief event mapping failed", { cause })))),
      Effect.catchCause((cause) => Effect.logWarning("cmux-chief event feed ended", { cause })),
      Effect.repeat(Schedule.spaced("1 second")),
      Effect.forkScoped
    )

    // ------------------------------------------------ request shaping
    yield* ctx.session.hook("context", (event) =>
      Effect.sync(() => {
        const system = chiefSessions.get(String(event.sessionID))
        if (system === undefined) return
        event.system = [{ type: "text", text: system }] as never
        for (const name of Object.keys(event.tools)) if (!name.startsWith("cmux_")) delete event.tools[name]
      })
    )

    // 1 h cache marks: opencode's cache policy places the marks (tools, system, conversation tail);
    // this hook sets their lifetime. (`model.request` carries only the base URL and headers.)
    yield* ctx.session.hook(
      "http.request",
      (event) =>
        Effect.gen(function* () {
          const req = event.request
          if (req.method !== "POST" || !(req.headers.get("content-type") ?? "").includes("json")) return
          const text = yield* Effect.promise(() => req.clone().text())
          let body: unknown
          try {
            body = JSON.parse(text)
          } catch {
            return
          }
          let changed = false
          const marks: Array<string> = []
          const walk = (v: unknown): void => {
            if (Array.isArray(v)) return v.forEach(walk)
            if (!v || typeof v !== "object") return
            const o = v as Record<string, unknown>
            const cc = o.cache_control as Record<string, unknown> | undefined
            if (cc && typeof cc === "object" && cc.type === "ephemeral") {
              if (opts.cacheTtl === "1h" && cc.ttl !== "1h") {
                cc.ttl = "1h"
                changed = true
              }
              marks.push(String(cc.ttl ?? "5m"))
            }
            for (const k of Object.keys(o)) if (k !== "cache_control") walk(o[k])
          }
          walk(body)
          if (opts.traceRequests) appendFileSync(opts.traceRequests, `${JSON.stringify({ at: Date.now(), url: req.url, kind: event.kind, marks })}\n`)
          if (!changed) return
          const headers = new Headers(req.headers)
          headers.delete("content-length")
          event.request = new Request(req.url, { method: req.method, headers, body: JSON.stringify(body), signal: req.signal })
        }),
      { providerID: GATEWAY }
    )

    // ------------------------------------------------ tools: CP service calls to the host
    const toolCall = (method: string, params: (s: RunState | undefined, input: Record<string, unknown>, callID: string) => unknown) => (args: unknown, context: { sessionID: unknown; id: unknown }) =>
      Effect.gen(function* () {
        const s = bySession.get(String(context.sessionID))
        const request = params(s, (args ?? {}) as Record<string, unknown>, String(context.id))
        const r = yield* host<unknown>(method, { ...(request as Record<string, unknown>), _turn_wake: s?.wake.wake_id }).pipe(attempt)
        const content = !r.ok ? `Error: ${r.error.message}` : typeof r.value === "string" ? r.value : JSON.stringify(r.value, null, 2)
        return { content }
      })
    const tool = (name: string, description: string, input: Schema.Top, execute: ReturnType<typeof toolCall>) => ({ name, description, input, options: { namespace: "cmux", codemode: false }, execute })

    yield* ctx.tool.transform((editor) => {
      editor.namespace({ name: "cmux", description: "This Chief's conversation, its other Chiefs, its hands and agents." })
      editor.add(
        tool("post", "Post a message in the current conversation now, before your final reply (a progress note, a question, a link). Your final reply is posted for you; do not repeat it here.", Schema.Struct({ text: Schema.String }),
          toolCall("conversation/post", (s, i, callID) => ({ conversation: s?.wake.conversation, client_msg_id: `chief-note:${s?.run}:${callID}`, body: i.text, run: s?.run }))) as never
      )
      editor.add(
        tool("chiefs", "See, make and edit the person's other Chiefs. action list returns every Chief; get returns one (chief: its id or name). create makes a new Chief (display_name required; role, personality, instructions). update changes another Chief. You cannot give a Chief more than you hold or delete a Chief.",
          Schema.Struct({ action: Schema.Literals(["list", "get", "create", "update"]), chief: Schema.optional(Schema.String), display_name: Schema.optional(Schema.String), role: Schema.optional(Schema.String), personality: Schema.optional(Schema.String), instructions: Schema.optional(Schema.String), model: Schema.optional(Schema.String) }),
          toolCall("chiefs/manage", (s, i, callID) => ({ ...i, key: `${s?.run}:${callID}` }))) as never
      )
      editor.add(
        tool("hands", "Use a hand: a machine of the person (their Mac or a sandbox) paired with this Chief. action list shows the hands; call sends one request {method: fs.read|fs.write|fs.edit|fs.list|fs.grep|exec, params} to hand `hand`.",
          Schema.Struct({ action: Schema.Literals(["list", "call"]), hand: Schema.optional(Schema.String), method: Schema.optional(Schema.String), params: Schema.optional(Schema.Record(Schema.String, Schema.Unknown)) }),
          (args, context) => (((args ?? {}) as { action?: string }).action === "call" ? toolCall("hand/call", (_s, i) => ({ hand: i.hand, method: i.method, params: i.params ?? {} })) : toolCall("hands/list", () => ({})))(args, context)) as never
      )
      editor.add(
        tool("agents", "Start and follow coding agents (claude, codex, opencode) on a hand. action start {hand, harness, cwd, prompt}; send {hand, session, text}; cancel {hand, session}.",
          Schema.Struct({ action: Schema.Literals(["start", "send", "cancel"]), hand: Schema.String, harness: Schema.optional(Schema.Literals(["claude", "codex", "opencode"])), cwd: Schema.optional(Schema.String), prompt: Schema.optional(Schema.String), session: Schema.optional(Schema.String), text: Schema.optional(Schema.String) }),
          toolCall("hand/call", (_s, i) => {
            const { action, hand, ...params } = i
            return { hand, method: `agent.${String(action)}`, params }
          })) as never
      )
    })
  })
})
