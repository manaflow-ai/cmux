import { DurableObject } from "cloudflare:workers"
import type { Env } from "../env.ts"
import { ackWake, chiefPrincipal, typing } from "../chief-brain/brain-io.ts"
import type { Admission } from "../chief-brain/brain-do.ts"
import type { Step } from "../chief-brain/brain-runs.ts"
import { HOLDER, signedFetch } from "../chief-brain/claude-auth.ts"
import { claudeRoute, isMetered } from "../chief-brain/model-routes.ts"
import type { CpNote, CpRun, CpWake } from "./contract.ts"
import { brainModel, hostCall, HostRefused, type Who } from "./host.ts"
import { LiveRuns } from "./live-runs.ts"

/**
 * OpencodeBrainDO, one per Chief (name = the agent id): the Chief Protocol HOST for implementation
 * O. It owns the Chief's one container (an opencode v2 server with the cmux-chief plugin), sleeps it
 * when idle, and is the only path between that brain and the Cloud:
 *
 * - wake: MuxDO forwards each committed wake of a cloud-brain Chief here first. When the Chief's
 *   `brain_impl` is not "opencode" the answer is `{skipped: "impl_pi"}` and MuxDO forwards to the
 *   P brain (ChiefBrainDO) as before. Otherwise the wake is queued per conversation (one turn at a
 *   time per conversation; conversations run in parallel inside the one opencode server).
 * - turn: admission by the P settings object (enabled, live, not placed, daily cap: one source of
 *   profile settings for both brains), container up, event stream open, then `chief/wake` as the
 *   plugin's RPC. The brain pulls (conversation/read), posts (conversation/post) and acks through
 *   `cp()`, which the Worker routes here with the container's token. A CP call is served only while
 *   a turn runs, and only for that turn's conversation.
 * - live: run/start, run/step, run/end become the trajectory wire (cb_turn/cb_step rows, the same
 *   tables and readers as P) and `conversation-run-changed` frames; run/delta is coalesced into the
 *   talk step every 40 ms (no storage write) until ConversationDO gains its stream frame. A run id
 *   maps to its wake row: the conversation of every run frame is the host's, not the brain's.
 * - crash: when the event stream ends before run/end, the DO asks the brain `status`: running means
 *   reopen the stream and wait; unknown (a new container) means send the same wake again (posts are
 *   idempotent by client_msg_id). run/end carries the cursor; the DO acks the wake from it.
 * - gateway (stub until the host model gateway lands): `/gateway/v1/messages` checks admission,
 *   signs the request for the metered Claude route (the same route and holder as P) and streams back.
 */
const PORT = 4096
/** The container sleeps after this long without a turn. */
const IDLE_MS = 10 * 60_000
const READY_MS = 60_000
const TURN_MS = 10 * 60_000
const MAX_ATTEMPTS = 3
const PLUGIN_DIR = "/opt/cmux-chief/plugin"

const SCHEMA = [
  `CREATE TABLE IF NOT EXISTS oc_config (name TEXT PRIMARY KEY, value TEXT NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS oc_wake (n INTEGER PRIMARY KEY AUTOINCREMENT, wake_id TEXT UNIQUE NOT NULL, conversation TEXT NOT NULL, seq INTEGER NOT NULL, reason TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'queued', tries INTEGER NOT NULL DEFAULT 0, run TEXT)`,
  `CREATE TABLE IF NOT EXISTS oc_cursor (conversation TEXT PRIMARY KEY, seq INTEGER NOT NULL)`,
  // The P tables the run readers use (brain-runs.ts): one row per run, one per step.
  `CREATE TABLE IF NOT EXISTS cb_turn (id TEXT PRIMARY KEY, conversation TEXT NOT NULL, trigger_message TEXT NOT NULL, trigger_kind TEXT NOT NULL, trigger_thread_root TEXT, last_seq INTEGER NOT NULL, status TEXT NOT NULL, reason TEXT, model TEXT NOT NULL, started INTEGER NOT NULL, ended INTEGER, submitted INTEGER NOT NULL DEFAULT 0, input TEXT, reply TEXT, post TEXT, posted_message TEXT, turn_key TEXT, post_tries INTEGER NOT NULL DEFAULT 0, post_key INTEGER NOT NULL DEFAULT 0)`,
  `CREATE TABLE IF NOT EXISTS cb_step (turn TEXT NOT NULL, step TEXT NOT NULL, seq INTEGER NOT NULL, body TEXT NOT NULL, PRIMARY KEY (turn, step))`,
  `CREATE TABLE IF NOT EXISTS cb_inbox (n INTEGER PRIMARY KEY AUTOINCREMENT, message TEXT UNIQUE NOT NULL, conversation TEXT NOT NULL, seq INTEGER NOT NULL, kind TEXT NOT NULL, thread_root TEXT, text TEXT NOT NULL, woke INTEGER NOT NULL DEFAULT 0, state TEXT NOT NULL DEFAULT 'queued', turn TEXT)`,
  `CREATE TABLE IF NOT EXISTS oc_run (id TEXT PRIMARY KEY, body TEXT NOT NULL)`
]

export type BrainImpl = "pi" | "opencode"


/** Constant-time string equality (the container token). */
const sameToken = (a: string, b: string): boolean => {
  const x = new TextEncoder().encode(a)
  const y = new TextEncoder().encode(b)
  if (x.length !== y.length) return false
  let d = 0
  for (let i = 0; i < x.length; i++) d |= x[i]! ^ y[i]!
  return d === 0
}

export class OpencodeBrainDO extends DurableObject<Env> {
  private readonly sql = this.ctx.storage.sql
  private readonly runsView = new LiveRuns({
    env: this.env,
    sql: this.sql,
    tx: (fn) => this.ctx.storage.transactionSync(fn),
    waitUntil: (p) => this.ctx.waitUntil(p),
    get: (n) => this.get(n),
    set: (n, v) => this.set(n, v),
    wakeOf: (r) => this.wakeOf(r)
  })
  private readonly draining = new Map<string, Promise<void>>()
  private streamAbort: AbortController | undefined
  private streaming = false
  private starting: Promise<void> | undefined
  private schemaReady = false

  /** Tables exist only once the Chief picked O (a read of `impl` never creates storage). */
  private schema(): void {
    if (this.schemaReady) return
    for (const q of SCHEMA) this.sql.exec(q)
    this.schemaReady = true
  }
  private hasSchema(): boolean {
    return this.schemaReady || this.sql.exec(`SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'oc_config'`).toArray().length > 0
  }

  // ------------------------------------------------------------------ config
  private get(name: string): string | undefined {
    if (!this.hasSchema()) return undefined
    return this.sql.exec<{ value: string }>(`SELECT value FROM oc_config WHERE name = ?`, name).toArray()[0]?.value
  }
  private set(name: string, value: string): void {
    this.schema()
    this.sql.exec(`INSERT INTO oc_config (name, value) VALUES (?, ?) ON CONFLICT (name) DO UPDATE SET value = excluded.value`, name, value)
  }

  /** The Chief's brain: "pi" (default) or "opencode". */
  async impl(): Promise<BrainImpl> {
    return this.get("impl") === "opencode" ? "opencode" : "pi"
  }
  /** The Worker checked the caller owns the Chief. */
  async setImpl(agent: string, owner: string, impl: BrainImpl): Promise<{ impl: BrainImpl }> {
    const cur = this.get("agent")
    if (cur && cur !== agent) throw new Error("this brain belongs to another chief")
    this.set("agent", agent)
    this.set("owner", owner)
    this.set("impl", impl)
    if (impl === "pi") await this.sleep()
    return { impl }
  }

  private settings(agent: string) {
    return this.env.CHIEF_BRAIN_DO.get(this.env.CHIEF_BRAIN_DO.idFromName(agent))
  }

  /** Sets the alarm to `at` unless an earlier one is already due (one alarm serves retries, turn guards and idle sleep). */
  private async alarmAt(at: number): Promise<void> {
    const cur = await this.ctx.storage.getAlarm()
    if (cur === null || cur > at) await this.ctx.storage.setAlarm(at)
  }

  // ------------------------------------------------------------------ wake (MuxDO)
  async wake(w: { agent: string; owner: string; conversation: string; seq: number; reason: string }): Promise<{ queued: number } | { skipped: string }> {
    if ((await this.impl()) !== "opencode") return { skipped: "impl_pi" }
    if (this.env.CHIEF_OPENCODE_CONTAINER !== "1" || this.ctx.container === undefined) return { skipped: "no_container" }
    if (this.get("agent") !== w.agent) return { skipped: "other_chief" }
    this.set("owner", w.owner)
    const cursor = this.sql.exec<{ seq: number }>(`SELECT seq FROM oc_cursor WHERE conversation = ?`, w.conversation).toArray()[0]?.seq
    // A conversation this brain never answered starts just before the wake: older history is context, not a question.
    if (cursor === undefined) this.sql.exec(`INSERT INTO oc_cursor (conversation, seq) VALUES (?, ?)`, w.conversation, w.seq - 1)
    const fresh = this.sql.exec(`INSERT INTO oc_wake (wake_id, conversation, seq, reason) VALUES (?, ?, ?, ?) ON CONFLICT (wake_id) DO NOTHING RETURNING n`, `${w.conversation}:${w.seq}`, w.conversation, w.seq, w.reason).toArray()
    this.kick(w.conversation)
    return { queued: fresh.length }
  }

  private kick(conversation: string): void {
    if (this.draining.has(conversation)) return
    const p = this.drain(conversation)
      .catch((e: unknown) => console.warn(JSON.stringify({ msg: "chief_opencode.drain_failed", error: String(e).slice(0, 300) })))
      .finally(() => {
        this.draining.delete(conversation)
        if (this.sql.exec(`SELECT 1 FROM oc_wake WHERE conversation = ? AND state IN ('queued', 'running') LIMIT 1`, conversation).toArray().length > 0) void this.alarmAt(Date.now() + 5_000)
      })
    this.draining.set(conversation, p)
    this.ctx.waitUntil(p)
  }

  private async drain(conversation: string): Promise<void> {
    for (;;) {
      const row = this.sql.exec<{ n: number; seq: number; reason: string; tries: number }>(`SELECT n, seq, reason, tries FROM oc_wake WHERE conversation = ? AND state IN ('running', 'queued') ORDER BY state = 'running' DESC, n LIMIT 1`, conversation).toArray()[0]
      if (!row) return
      // Later wakes of the same conversation ride along: the brain reads everything after the cursor.
      this.sql.exec(`UPDATE oc_wake SET state = 'merged' WHERE conversation = ? AND state = 'queued' AND n > ?`, conversation, row.n)
      await this.turn(conversation, row)
    }
  }

  private async who(): Promise<Who | { refused: string }> {
    const agent = this.get("agent")
    const owner = this.get("owner")
    if (!agent || !owner) return { refused: "unbound" }
    const a = (await this.settings(agent).admit(agent, owner, false)) as Admission
    return a.ok ? { agent, owner, config: { ...a.config, model: brainModel(a.config.model) } } : { refused: a.reason }
  }

  private async turn(conversation: string, row: { n: number; seq: number; reason: string; tries: number }): Promise<void> {
    const agent = this.get("agent")!
    const owner = this.get("owner")!
    const run = `run_${row.n}`
    if (row.tries >= MAX_ATTEMPTS) return this.endWake(row.n, run, "failed", "the brain did not finish the turn")
    const admitted = (await this.settings(agent).admit(agent, owner, row.tries === 0)) as Admission
    if (!admitted.ok) return void this.sql.exec(`UPDATE oc_wake SET state = 'skipped' WHERE n = ?`, row.n)
    // A metered model counts against the deployment's daily Claude cap, as on P (the holder decides).
    const model = brainModel(admitted.config.model)
    if (row.tries === 0 && isMetered(model)) {
      const holder = this.env.CHIEF_BRAIN_DO.get(this.env.CHIEF_BRAIN_DO.idFromName(HOLDER))
      if (!(await holder.claudeTurn(owner, model).catch(() => false))) return this.endWake(row.n, run, "skipped", "the deployment's daily Claude cap is reached")
    }
    this.sql.exec(`UPDATE oc_wake SET state = 'running', run = ?, tries = tries + 1 WHERE n = ?`, run, row.n)
    // An eviction mid-turn loses the in-memory loop: the alarm picks the running row up again.
    await this.alarmAt(Date.now() + TURN_MS + 60_000)
    const cursor = this.sql.exec<{ seq: number }>(`SELECT seq FROM oc_cursor WHERE conversation = ?`, conversation).toArray()[0]?.seq ?? row.seq - 1
    void typing(this.env, conversation, agent, true)
    let ended: CpRun | null = null
    try {
      for (let attempt = 0; attempt < MAX_ATTEMPTS && ended === null; attempt++) {
        if ((await this.impl()) !== "opencode") break
        await this.ensureContainer()
        const live = this.runsView.track(run, conversation)
        const wake: CpWake = { wake_id: String(row.n), conversation, cursor, reason: row.reason }
        const out = (await this.rpc("wake", wake).catch((e: unknown) => (console.warn(JSON.stringify({ msg: "chief_opencode.wake_failed", error: String(e).slice(0, 300) })), null))) as { accepted?: boolean } | null
        // Wait for run/end; a lost stream or a repeated wake asks the brain where the run is.
        for (let waits = 0; out !== null && ended === null && waits < MAX_ATTEMPTS; waits++) {
          let timer: ReturnType<typeof setTimeout> | undefined
          const note = out.accepted === false && waits === 0 ? null : await Promise.race([live.done, new Promise<null>((r) => (timer = setTimeout(() => r(null), TURN_MS)))])
          clearTimeout(timer)
          if (note?.method === "run/end") ended = note.params.run
          if (ended) break
          const status = (await this.rpc("status", { run }).catch(() => null)) as { state?: string; run?: CpRun } | null
          if ((status?.state === "done" || status?.state === "failed") && status.run) ended = status.run
          else if (status?.state !== "running") break
          else if (!this.streaming) await this.openStream().catch(() => undefined)
        }
        this.runsView.untrack(run)
      }
    } finally {
      void typing(this.env, conversation, agent, false)
    }
    if (ended) {
      await this.onRunEnd(ended)
      this.sql.exec(`UPDATE oc_wake SET state = ? WHERE n = ?`, ended.status === "done" ? "done" : "failed", row.n)
    } else if (row.tries + 1 >= MAX_ATTEMPTS) this.endWake(row.n, run, "failed", "the brain did not finish the turn")
    else this.sql.exec(`UPDATE oc_wake SET state = 'queued' WHERE n = ?`, row.n)
    await this.alarmAt(Date.now() + IDLE_MS)
  }

  private endWake(n: number, run: string, state: string, reason: string): void {
    this.sql.exec(`UPDATE oc_wake SET state = ? WHERE n = ?`, state, n)
    this.sql.exec(`UPDATE cb_turn SET status = 'failed', reason = ?, ended = ? WHERE id = ? AND status = 'running'`, reason, Date.now(), run)
  }

  /** The cursor the brain read up to (run/end): moved here, and the wake acked, even when the brain's own chief/ack was lost. */
  private async onRunEnd(r: CpRun): Promise<void> {
    const wake = this.wakeOf(r.id)
    const cursor = Number((r as { cursor?: unknown }).cursor ?? 0)
    const agent = this.get("agent")
    const owner = this.get("owner")
    if (!wake || !agent || !owner || !(cursor > 0)) return
    this.sql.exec(`UPDATE oc_cursor SET seq = MAX(seq, ?) WHERE conversation = ?`, cursor, wake.conversation)
    await ackWake(this.env, agent, chiefPrincipal(agent, owner), wake.conversation, cursor).catch(() => undefined)
  }

  private wakeOf(run: string): { n: number; conversation: string; state: string } | undefined {
    const m = /^run_([0-9]{1,15})$/.exec(run)
    if (!m) return undefined
    return this.sql.exec<{ n: number; conversation: string; state: string }>(`SELECT n, conversation, state FROM oc_wake WHERE n = ?`, Number(m[1])).toArray()[0]
  }

  // ------------------------------------------------------------------ container
  private async ensureContainer(): Promise<void> {
    if (this.ctx.container!.running && this.streaming) return
    if (!this.starting) this.starting = this.start().finally(() => (this.starting = undefined))
    await this.starting
  }

  private async start(): Promise<void> {
    const c = this.ctx.container!
    const agent = this.get("agent")!
    if (!c.running) {
      const password = crypto.randomUUID()
      const token = crypto.randomUUID() + crypto.randomUUID()
      this.set("password", password)
      this.set("token", token)
      const origin = (this.env.CLOUD_API_ORIGIN ?? "").replace(/\/+$/, "")
      const base = `${origin}/v1/chief-opencode/${agent}`
      const config = {
        plugins: [{ package: PLUGIN_DIR, options: { host: `${base}/cp`, gateway: this.env.CHIEF_OPENCODE_GATEWAY_URL || `${base}/gateway/v1`, tokenEnv: "CMUX_CHIEF_TOKEN", cacheTtl: "1h" } }]
      }
      c.start({
        enableInternet: true,
        env: { OPENCODE_SERVER_PASSWORD: password, CMUX_CHIEF_TOKEN: token, OPENCODE_CONFIG_CONTENT: JSON.stringify(config), OPENCODE_DISABLE_PROJECT_CONFIG: "1" }
      })
      this.ctx.waitUntil(c.monitor().catch(() => undefined).finally(() => this.streamAbort?.abort()))
    }
    // Readiness: the plugin's RPC answers (bounded; the container reports no other ready signal).
    const t0 = Date.now()
    for (let delay = 100; ; delay = Math.min(delay * 2, 2_000)) {
      if (await this.rpc("status", { run: "ready" }).then(() => true, () => false)) break
      if (Date.now() - t0 > READY_MS) throw new Error("the brain container did not become ready")
      await new Promise((r) => setTimeout(r, delay))
    }
    this.set("ready_ms", String(Date.now() - t0))
    await this.openStream()
  }

  /** Idle or switched to P: the container stops and its token dies with it. */
  private async sleep(): Promise<void> {
    this.streamAbort?.abort()
    if (this.ctx.container?.running) await this.ctx.container.destroy().catch(() => undefined)
    if (this.hasSchema()) this.sql.exec(`DELETE FROM oc_config WHERE name IN ('token', 'password')`)
  }

  private auth(): string {
    return `Basic ${btoa(`opencode:${this.get("password") ?? ""}`)}`
  }

  private async rpc(method: string, input: unknown): Promise<unknown> {
    const port = this.ctx.container!.getTcpPort(PORT)
    const r = await port.fetch(`http://brain/api/rpc/cmux-chief/${method}`, { method: "POST", headers: { authorization: this.auth(), "content-type": "application/json" }, body: JSON.stringify({ input }) })
    const text = await r.text()
    if (!r.ok) throw new Error(`rpc ${method} ${r.status}: ${text.slice(0, 300)}`)
    return (JSON.parse(text) as { output?: unknown }).output
  }

  /** One event stream per container; its CP notifications feed the live runs. */
  private async openStream(): Promise<void> {
    this.streamAbort?.abort()
    const ac = new AbortController()
    this.streamAbort = ac
    const res = await this.ctx.container!.getTcpPort(PORT).fetch("http://brain/api/event", { headers: { authorization: this.auth(), accept: "text/event-stream" }, signal: ac.signal })
    if (!res.ok || !res.body) throw new Error(`event stream ${res.status}`)
    this.streaming = true
    const reader = res.body.getReader()
    const dec = new TextDecoder()
    let buf = ""
    const pump = (async () => {
      try {
        for (;;) {
          const { value, done } = await reader.read()
          if (done) break
          buf += dec.decode(value, { stream: true })
          for (let i = buf.indexOf("\n\n"); i >= 0; i = buf.indexOf("\n\n")) {
            const frame = buf.slice(0, i)
            buf = buf.slice(i + 2)
            const data = frame.split("\n").filter((l) => l.startsWith("data:")).map((l) => l.slice(5).trimStart()).join("\n")
            if (!data.includes("rpc.cmux-chief.cp")) continue
            try {
              const ev = JSON.parse(data) as { type?: string; data?: unknown }
              if (ev.type === "rpc.cmux-chief.cp") this.runsView.onNote(ev.data)
            } catch {
              /* a frame that is not JSON */
            }
          }
        }
      } catch {
        /* aborted, or the container died */
      } finally {
        // Only the current stream speaks for the container: a replaced one ends quietly.
        if (this.streamAbort === ac) {
          this.streaming = false
          this.runsView.endAll()
        }
      }
    })()
    this.ctx.waitUntil(pump)
  }

  // ------------------------------------------------------------------ reads (the Worker checked membership)
  async runs(conversation: string, before: number | undefined, limit: number): Promise<{ runs: Array<Record<string, unknown>>; has_more: boolean }> {
    return this.hasSchema() ? this.runsView.runs(conversation, before, limit) : { runs: [], has_more: false }
  }
  async run(id: string, afterSeq = 0, limit = 500): Promise<{ run: Record<string, unknown>; steps: Array<Step>; has_more: boolean } | null> {
    return this.hasSchema() ? this.runsView.run(id, afterSeq, limit) : null
  }

  // ------------------------------------------------------------------ container -> host (the Worker routes /v1/chief-opencode/<agent>/{cp,gateway})
  async fetch(request: Request): Promise<Response> {
    const token = this.get("token")
    const given = (request.headers.get("authorization") ?? request.headers.get("x-api-key") ?? "").replace(/^Bearer\s+/i, "")
    if (!token || !given || !sameToken(given, token)) return Response.json({ jsonrpc: "2.0", id: null, error: { code: -32001, message: "bad chief token" } }, { status: 401 })
    const path = new URL(request.url).pathname
    if (path.endsWith("/cp")) return this.cp(request)
    if (path.endsWith("/gateway/v1/messages")) return this.gateway(request)
    return new Response("not found", { status: 404 })
  }

  private async cp(request: Request): Promise<Response> {
    const body = (await request.json().catch(() => null)) as { id?: unknown; method?: unknown; params?: unknown } | null
    const id = (body?.id ?? null) as string | number | null
    const reply = (r: { result: unknown } | { error: { code: number; message: string } }) => Response.json({ jsonrpc: "2.0", id, ...r })
    if (!body || typeof body.method !== "string") return reply({ error: { code: -32600, message: "invalid request" } })
    // Brain requests are served only for a running turn, and only for that turn's conversation.
    const running = new Set(this.sql.exec<{ conversation: string }>(`SELECT conversation FROM oc_wake WHERE state = 'running'`).toArray().map((r) => r.conversation))
    let params = (body.params ?? {}) as Record<string, unknown>
    if (body.method !== "initialize" && running.size === 0) return reply({ error: { code: -32003, message: "no turn is running" } })
    if ("conversation" in params && !running.has(String(params.conversation))) return reply({ error: { code: -32003, message: "not this turn's conversation" } })
    const who = await this.who()
    if ("refused" in who) return reply({ error: { code: -32003, message: who.refused } })
    if (body.method === "chief/ack") {
      // The wake id names the conversation; the brain reports the newest message it read.
      const wake = this.sql.exec<{ conversation: string; state: string }>(`SELECT conversation, state FROM oc_wake WHERE n = ?`, Number(params.wake_id)).toArray()[0]
      if (!wake || wake.state !== "running") return reply({ result: {} })
      const cursor = Number(params.cursor ?? 0)
      this.sql.exec(`UPDATE oc_cursor SET seq = MAX(seq, ?) WHERE conversation = ?`, cursor, wake.conversation)
      params = { conversation: wake.conversation, cursor }
    }
    try {
      return reply({ result: await hostCall(this.env, who, body.method, params) })
    } catch (e) {
      return reply({ error: { code: e instanceof HostRefused ? e.code : -32000, message: e instanceof Error ? e.message.slice(0, 500) : String(e) } })
    }
  }

  /**
   * Stub of the host model gateway (Anthropic Messages in, SSE out) until the shared gateway lands:
   * admission first (a Chief turned off stops spending at once), then the metered Claude route with
   * the holder's sign-in, exactly the route P uses today. Credits (UsageMeterDO reserve/settle) go
   * here, the one place every O model call passes.
   */
  private async gateway(request: Request): Promise<Response> {
    const who = await this.who()
    if ("refused" in who) return Response.json({ type: "error", error: { type: "permission_error", message: who.refused } }, { status: 403 })
    const holder = this.env.CHIEF_BRAIN_DO.get(this.env.CHIEF_BRAIN_DO.idFromName(HOLDER))
    // The P brain's Claude route, from the same configuration (url, stack or bearer auth, models, cache TTL).
    const route = claudeRoute(this.env)
    const f = signedFetch(() => holder.claudeAuth(), () => holder.claudeInvalidate(), { auth: route.auth, models: route.models, effortBody: route.effortBody, ...(this.env.CHIEF_BRAIN_CACHE_TTL ? { ttl: this.env.CHIEF_BRAIN_CACHE_TTL } : {}) })
    return f(`${route.url.replace(/\/+$/, "")}/v1/messages`, { method: "POST", headers: request.headers, body: await request.text() }).catch((e: unknown) => Response.json({ type: "error", error: { type: "api_error", message: e instanceof Error ? e.message : "gateway failed" } }, { status: 502 }))
  }

  // ------------------------------------------------------------------ retries, turn guard and idle sleep
  async alarm(): Promise<void> {
    if (!this.hasSchema()) return
    const pending = this.sql.exec<{ conversation: string }>(`SELECT DISTINCT conversation FROM oc_wake WHERE state IN ('queued', 'running')`).toArray()
    for (const p of pending) this.kick(p.conversation)
    if (pending.length > 0) return
    await this.sleep()
  }
}
