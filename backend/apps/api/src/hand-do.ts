import { DurableObject } from "cloudflare:workers"
import type { Env } from "./env.ts"
import { createIndexTables, handName, indexGrants, indexList, indexName, indexPut, indexSetGrant } from "./hand-index.ts"
import { callerLabel, isHandAction, PAIR_TTL_MS, sameHex, type AgentEvent, type HandCaller, type HandError, type HandReply, type HandSummary, type Profile, type StoredEvent } from "./hand-wire.ts"

/**
 * HandDO: one object per installed hand (`h:<hand id>`), holding that hand's one hibernating
 * socket, request/reply correlation with timeouts, its policy view, pending owner approvals, the
 * agent events it streamed, and one audit row per request {action, hand, who, at, outcome}.
 * The same class also serves the owner's index (`owner:<user>`, hand-index.ts).
 *
 * Pings are answered by the runtime's auto-response, so an idle hand costs no duration. A pending
 * call keeps the object awake until its reply or its deadline. The Worker authenticates the socket
 * (it hashes the hand's bearer key and passes only the hash); frames never carry identity.
 */

const HAND_TAG = "hand"
const DEFAULT_TIMEOUT_MS = 60_000
const MAX_TIMEOUT_MS = 15 * 60_000
/** A request that waits for the owner's approval gets this long from the approval on. */
const APPROVAL_WINDOW_MS = 11 * 60_000
const KEEP_EVENTS = 5_000
const KEEP_AUDIT = 10_000

interface Pending {
  readonly resolve: (r: HandReply) => void
  timer: ReturnType<typeof setTimeout>
}

type HandRow = {
  hand: string
  owner: string
  name: string
  minted_by: string
  created_at: number
  code_sha: string | null
  key_sha: string | null
  paired_at: number | null
  revoked_at: number | null
  profile: string | null
  hello: string | null
  last_seen: number | null
}

/**
 * JSON of `v` within `max` characters, always parseable: long string fields are cut first, and a
 * value that still does not fit is replaced by a marker.
 */
const capJson = (v: unknown, max: number): string => {
  const whole = JSON.stringify(v ?? null)
  if (whole.length <= max) return whole
  if (v && typeof v === "object" && !Array.isArray(v)) {
    const cut = Object.fromEntries(Object.entries(v as Record<string, unknown>).map(([k, x]) => [k, typeof x === "string" && x.length > max / 4 ? `${x.slice(0, max / 4)}…[cut]` : x]))
    const again = JSON.stringify({ ...cut, truncated: true })
    if (again.length <= max) return again
  }
  return JSON.stringify({ kind: (v as { kind?: unknown } | null)?.kind ?? null, truncated: true })
}

const refuse = (code: string, message: string): { readonly ok: false; readonly error: HandError } => ({ ok: false, error: { code, message } })

export class HandDO extends DurableObject<Env> {
  private readonly pending = new Map<string, Pending>()
  private readonly waiters = new Set<() => void>()
  private inserts = 0

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    const sql = ctx.storage.sql
    sql.exec(`CREATE TABLE IF NOT EXISTS hand (id INTEGER PRIMARY KEY CHECK (id = 1), hand TEXT NOT NULL, owner TEXT NOT NULL, name TEXT NOT NULL, minted_by TEXT NOT NULL, created_at INTEGER NOT NULL, code_sha TEXT, key_sha TEXT, paired_at INTEGER, revoked_at INTEGER, profile TEXT, hello TEXT, last_seen INTEGER)`)
    sql.exec(`CREATE TABLE IF NOT EXISTS hand_grant (agent TEXT PRIMARY KEY)`)
    sql.exec(`CREATE TABLE IF NOT EXISTS hand_audit (seq INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL, req TEXT NOT NULL, action TEXT NOT NULL, who TEXT NOT NULL, outcome TEXT NOT NULL, ms INTEGER)`)
    sql.exec(`CREATE TABLE IF NOT EXISTS hand_approval (id TEXT PRIMARY KEY, req TEXT NOT NULL, summary TEXT NOT NULL, at INTEGER NOT NULL, answered_at INTEGER, allow INTEGER, who TEXT)`)
    sql.exec(`CREATE TABLE IF NOT EXISTS hand_event (seq INTEGER PRIMARY KEY AUTOINCREMENT, session TEXT NOT NULL, at INTEGER NOT NULL, body TEXT NOT NULL)`)
    createIndexTables(sql)
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"))
  }

  private row(): HandRow | undefined {
    return this.ctx.storage.sql.exec<HandRow>(`SELECT hand, owner, name, minted_by, created_at, code_sha, key_sha, paired_at, revoked_at, profile, hello, last_seen FROM hand WHERE id = 1`).toArray()[0]
  }

  /** The newest open hand socket (a replaced one may still be closing). */
  private socket(): WebSocket | undefined {
    return this.ctx.getWebSockets(HAND_TAG).filter((ws) => ws.readyState === WebSocket.OPEN).at(-1)
  }

  private summary(r: HandRow): HandSummary {
    return { hand: r.hand, name: r.name, profile: (r.profile as Profile | null) ?? null, created_at: r.created_at, paired_at: r.paired_at, revoked_at: r.revoked_at, last_seen: r.last_seen, online: this.socket() !== undefined }
  }

  private index(user: string) {
    return this.env.HAND_DO.get(this.env.HAND_DO.idFromName(indexName(user)))
  }

  private async publish(r: HandRow): Promise<void> {
    await this.index(r.owner).indexUpdate(this.summary(r))
  }

  // --- Owner index role (`owner:<user>`) ---

  async indexUpdate(summary: HandSummary | { hand: string; removed: true }): Promise<void> {
    indexPut(this.ctx.storage.sql, summary)
  }

  async listHands(): Promise<Array<HandSummary>> {
    return indexList(this.ctx.storage.sql)
  }

  async listGrants(): Promise<Array<string>> {
    return indexGrants(this.ctx.storage.sql)
  }

  /** The owner turns a Chief's `hands` grant on or off; every hand of the owner gets the new list. */
  async setGrant(agent: string, on: boolean): Promise<Array<string>> {
    const sql = this.ctx.storage.sql
    indexSetGrant(sql, agent, on, Date.now())
    const grants = indexGrants(sql)
    await Promise.all(indexList(sql).map((h) => this.env.HAND_DO.get(this.env.HAND_DO.idFromName(handName(h.hand))).setGrants(grants)))
    return grants
  }

  // --- Hand role (`h:<hand>`) ---

  /** A new pairing code's hand: unpaired until `redeem`, deleted at expiry when nobody redeemed it. */
  async mint(hand: string, owner: string, mintedBy: string, codeSha: string, name: string): Promise<{ expires_at: number }> {
    const now = Date.now()
    if (this.row()) throw new Error("hand id already used")
    this.ctx.storage.sql.exec(`INSERT INTO hand (id, hand, owner, name, minted_by, created_at, code_sha) VALUES (1, ?, ?, ?, ?, ?, ?)`, hand, owner, name, mintedBy, now, codeSha)
    const grants = await this.index(owner).listGrants()
    this.setGrantsLocal(grants)
    await this.ctx.storage.setAlarm(now + PAIR_TTL_MS)
    await this.publish(this.row()!)
    return { expires_at: now + PAIR_TTL_MS }
  }

  /** Single use: the first valid redeem sets the key hash and clears the code. */
  async redeem(codeSha: string, keySha: string, info: { name: string; profile: Profile }): Promise<HandReply<{ hand: string; owner: string }>> {
    const r = this.row()
    const now = Date.now()
    if (!r || !r.code_sha || r.paired_at !== null || now > r.created_at + PAIR_TTL_MS || !sameHex(r.code_sha, codeSha)) {
      return { ok: false, error: { code: "hand.pair_invalid", message: "the pairing code is wrong, used or expired" } }
    }
    this.ctx.storage.sql.exec(`UPDATE hand SET code_sha = NULL, key_sha = ?, paired_at = ?, name = ?, profile = ? WHERE id = 1`, keySha, now, info.name || r.name, info.profile)
    await this.ctx.storage.deleteAlarm()
    await this.publish(this.row()!)
    return { ok: true, value: { hand: r.hand, owner: r.owner } }
  }

  override async alarm(): Promise<void> {
    const r = this.row()
    if (r && r.paired_at === null) {
      this.ctx.storage.sql.exec(`DELETE FROM hand WHERE id = 1`)
      await this.index(r.owner).indexUpdate({ hand: r.hand, removed: true })
    }
  }

  async setGrants(agents: ReadonlyArray<string>): Promise<void> {
    this.setGrantsLocal(agents)
  }

  private setGrantsLocal(agents: ReadonlyArray<string>) {
    const sql = this.ctx.storage.sql
    sql.exec(`DELETE FROM hand_grant`)
    for (const a of agents) sql.exec(`INSERT INTO hand_grant (agent) VALUES (?)`, a)
  }

  private authorize(caller: HandCaller, r: HandRow | undefined): string | null {
    if (!r || r.paired_at === null) return "hand.not_found"
    if (caller.user !== r.owner) return "hand.not_found"
    if (r.revoked_at !== null) return "hand.revoked"
    if (caller.kind === "chief") {
      const granted = this.ctx.storage.sql.exec(`SELECT 1 FROM hand_grant WHERE agent = ?`, caller.agent ?? "").toArray().length > 0
      if (!granted) return "hand.no_grant"
    }
    // The Mac trust post (#13742) comes first: until then a mac hand takes no Cloud request.
    if (r.profile === "mac" && this.env.HANDS_MAC_ENABLED !== "1") return "hand.mac_disabled"
    return null
  }

  async info(caller: HandCaller): Promise<HandReply<HandSummary & { hello: unknown }>> {
    const r = this.row()
    const denied = this.authorize(caller, r)
    if (denied && denied !== "hand.mac_disabled" && denied !== "hand.revoked") return refuse(denied, "no such hand")
    return { ok: true, value: { ...this.summary(r!), hello: r!.hello ? JSON.parse(r!.hello) : null } }
  }

  /** One request to the hand; the reply, a refusal, or `hand.timeout`. Writes one audit row. */
  async call(caller: HandCaller, action: string, params: unknown, timeoutMs?: number): Promise<HandReply> {
    const started = Date.now()
    const req = crypto.randomUUID()
    const r = this.row()
    const denied = this.authorize(caller, r) ?? (isHandAction(action) ? null : "hand.bad_action")
    const ws = this.socket()
    const result: HandReply = denied
      ? refuse(denied, denied === "hand.mac_disabled" ? "Cloud requests to a Mac hand are off until the trust review" : `refused: ${denied}`)
      : !ws
        ? refuse("hand.offline", "the hand is not connected")
        : await new Promise<HandReply>((resolve) => {
            const ms = Math.min(Math.max(timeoutMs ?? DEFAULT_TIMEOUT_MS, 1_000), MAX_TIMEOUT_MS)
            const timer = setTimeout(() => this.settle(req, refuse("hand.timeout", `no answer in ${ms} ms`)), ms)
            this.pending.set(req, { resolve, timer })
            try {
              ws.send(JSON.stringify({ t: "req", id: req, action, params: params ?? {} }))
            } catch {
              this.settle(req, refuse("hand.offline", "the hand socket closed"))
            }
          })
    this.audit(req, action, callerLabel(caller), result.ok ? "ok" : result.error.code, Date.now() - started)
    return result
  }

  private settle(req: string, reply: HandReply) {
    const p = this.pending.get(req)
    if (!p) return
    clearTimeout(p.timer)
    this.pending.delete(req)
    p.resolve(reply)
  }

  private audit(req: string, action: string, who: string, outcome: string, ms: number | null) {
    const sql = this.ctx.storage.sql
    sql.exec(`INSERT INTO hand_audit (at, req, action, who, outcome, ms) VALUES (?, ?, ?, ?, ?, ?)`, Date.now(), req, action, who, outcome, ms)
    sql.exec(`DELETE FROM hand_audit WHERE seq <= (SELECT MAX(seq) FROM hand_audit) - ?`, KEEP_AUDIT)
  }

  async auditLog(caller: HandCaller, limit = 100): Promise<HandReply<Array<Record<string, unknown>>>> {
    const denied = this.authorize(caller, this.row())
    if (denied && denied !== "hand.mac_disabled" && denied !== "hand.revoked") return refuse(denied, "no such hand")
    const n = Math.min(Math.max(limit, 1), 1000)
    return { ok: true, value: this.ctx.storage.sql.exec(`SELECT seq, at, req, action, who, outcome, ms FROM hand_audit ORDER BY seq DESC LIMIT ?`, n).toArray() }
  }

  /**
   * Events of `session` after `afterSeq` (the Cloud's own seq). When there are none yet, waits until
   * one arrives or `waitMs` passes: no polling, the socket handler wakes the waiter.
   */
  async events(caller: HandCaller, session: string, afterSeq: number, waitMs = 0): Promise<HandReply<{ events: Array<StoredEvent>; last_seq: number; head_seq: number }>> {
    const denied = this.authorize(caller, this.row())
    if (denied) return refuse(denied, `refused: ${denied}`)
    const read = () =>
      this.ctx.storage.sql
        .exec<{ seq: number; session: string; at: number; body: string }>(`SELECT seq, session, at, body FROM hand_event WHERE session = ? AND seq > ? ORDER BY seq LIMIT 500`, session, afterSeq)
        .toArray()
        .map((e) => ({ seq: e.seq, session: e.session, at: e.at, event: JSON.parse(e.body) as AgentEvent }))
    let rows = read()
    if (rows.length === 0 && waitMs > 0) {
      await new Promise<void>((resolve) => {
        const wake = () => {
          clearTimeout(timer)
          this.waiters.delete(wake)
          resolve()
        }
        const timer = setTimeout(wake, Math.min(waitMs, 30_000))
        this.waiters.add(wake)
      })
      rows = read()
    }
    const head = this.ctx.storage.sql.exec<{ head: number | null }>(`SELECT MAX(seq) AS head FROM hand_event WHERE session = ?`, session).toArray()[0]?.head ?? 0
    return { ok: true, value: { events: rows, last_seq: rows.at(-1)?.seq ?? afterSeq, head_seq: head } }
  }

  async approvals(caller: HandCaller): Promise<HandReply<Array<Record<string, unknown>>>> {
    if (caller.kind !== "owner") return refuse("auth.forbidden", "only the owner answers approvals")
    const r = this.row()
    if (!r || r.owner !== caller.user) return refuse("hand.not_found", "no such hand")
    const rows = this.ctx.storage.sql.exec<{ id: string; req: string; summary: string; at: number }>(`SELECT id, req, summary, at FROM hand_approval WHERE answered_at IS NULL ORDER BY at`).toArray()
    return { ok: true, value: rows.map((a) => ({ ...a, summary: JSON.parse(a.summary) })) }
  }

  /** The owner's answer; one answer per approval. */
  async answer(caller: HandCaller, id: string, allow: boolean): Promise<HandReply<{ id: string; allow: boolean }>> {
    if (caller.kind !== "owner") return refuse("auth.forbidden", "only the owner answers approvals")
    const r = this.row()
    if (!r || r.owner !== caller.user) return refuse("hand.not_found", "no such hand")
    const sql = this.ctx.storage.sql
    const a = sql.exec<{ answered_at: number | null }>(`SELECT answered_at FROM hand_approval WHERE id = ?`, id).toArray()[0]
    if (!a) return refuse("hand.approval_not_found", "no such approval")
    if (a.answered_at !== null) return refuse("hand.approval_answered", "this approval was answered already")
    sql.exec(`UPDATE hand_approval SET answered_at = ?, allow = ?, who = ? WHERE id = ?`, Date.now(), allow ? 1 : 0, callerLabel(caller), id)
    this.audit(id, "approval", callerLabel(caller), allow ? "allow" : "deny", null)
    this.socket()?.send(JSON.stringify({ t: "approval", id, allow }))
    return { ok: true, value: { id, allow } }
  }

  async revoke(caller: HandCaller): Promise<HandReply<{ hand: string }>> {
    const r = this.row()
    if (caller.kind !== "owner" || !r || r.owner !== caller.user) return refuse("hand.not_found", "no such hand")
    this.ctx.storage.sql.exec(`UPDATE hand SET revoked_at = ?, key_sha = NULL WHERE id = 1`, Date.now())
    for (const ws of this.ctx.getWebSockets()) ws.close(4403, "revoked")
    for (const req of [...this.pending.keys()]) this.settle(req, refuse("hand.revoked", "the hand was removed"))
    this.audit(crypto.randomUUID(), "revoke", callerLabel(caller), "ok", null)
    await this.publish(this.row()!)
    return { ok: true, value: { hand: r.hand } }
  }

  /** Socket upgrade. The Worker passes `x-cmux-hand-key-sha256`, the hash of the bearer key. */
  override async fetch(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade") !== "websocket") return new Response("expected websocket", { status: 426 })
    const r = this.row()
    const keySha = request.headers.get("x-cmux-hand-key-sha256") ?? ""
    if (!r || !r.key_sha || r.revoked_at !== null || !sameHex(r.key_sha, keySha)) return new Response("forbidden", { status: 403 })
    const { 0: client, 1: server } = new WebSocketPair()
    // One live socket per hand: a reconnect replaces the old one.
    for (const old of this.ctx.getWebSockets(HAND_TAG)) old.close(4000, "replaced")
    this.ctx.acceptWebSocket(server, [HAND_TAG])
    this.ctx.storage.sql.exec(`UPDATE hand SET last_seen = ? WHERE id = 1`, Date.now())
    return new Response(null, { status: 101, webSocket: client })
  }

  override async webSocketMessage(_ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (typeof message !== "string" || message.length > 4 * 1024 * 1024) return
    let f: Record<string, unknown>
    try {
      f = JSON.parse(message) as Record<string, unknown>
    } catch {
      return
    }
    const sql = this.ctx.storage.sql
    const now = Date.now()
    switch (f.t) {
      case "res": {
        const id = String(f.id ?? "")
        this.settle(id, f.ok === true ? { ok: true, value: f.value } : { ok: false, error: (f.error as { code: string; message: string } | undefined) ?? { code: "hand.error", message: "no error" } })
        return
      }
      case "hello": {
        const profile = f.profile === "mac" ? "mac" : "sandbox"
        sql.exec(`UPDATE hand SET hello = ?, profile = ?, last_seen = ? WHERE id = 1`, capJson(f, 16_000), profile, now)
        const r = this.row()
        if (r) await this.publish(r)
        return
      }
      case "approve": {
        const id = String(f.id ?? "")
        const req = String(f.req ?? "")
        if (!id) return
        sql.exec(`INSERT INTO hand_approval (id, req, summary, at) VALUES (?, ?, ?, ?) ON CONFLICT(id) DO NOTHING`, id, req, capJson(f.summary ?? {}, 16_000), now)
        // The request now waits for a person, not for the machine.
        const p = this.pending.get(req)
        if (p) {
          clearTimeout(p.timer)
          p.timer = setTimeout(() => this.settle(req, refuse("hand.approval_timeout", "the owner did not answer in time")), APPROVAL_WINDOW_MS)
        }
        return
      }
      case "event": {
        const session = String(f.session ?? "")
        if (!session || typeof f.event !== "object") return
        sql.exec(`INSERT INTO hand_event (session, at, body) VALUES (?, ?, ?)`, session, now, capJson(f.event, 64_000))
        if (++this.inserts % 100 === 0) sql.exec(`DELETE FROM hand_event WHERE seq <= (SELECT MAX(seq) FROM hand_event) - ?`, KEEP_EVENTS)
        for (const wake of [...this.waiters]) wake()
        return
      }
    }
  }

  override async webSocketClose(ws: WebSocket, code: number): Promise<void> {
    this.ctx.storage.sql.exec(`UPDATE hand SET last_seen = ? WHERE id = 1`, Date.now())
    if (this.ctx.getWebSockets(HAND_TAG).some((s) => s !== ws)) return
    for (const req of [...this.pending.keys()]) this.settle(req, refuse("hand.offline", `the hand disconnected (${code})`))
    const r = this.row()
    if (r) await this.publish({ ...r })
  }
}
