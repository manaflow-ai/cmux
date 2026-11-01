import { DurableObject } from "cloudflare:workers"
import type { Env } from "./env.ts"
import { PROVIDERS } from "./hand-providers.ts"
import { LEGACY_HAND_PROVIDER } from "./providers/index.ts"
import { revokeAgentSession } from "./model-gateway/run-token.ts"
import { classify, requestSummary, type Classified } from "./hand-classify.ts"
import { createVerdictTable, listVerdicts, recordVerdict } from "./hand-verdicts.ts"
import { createPresenceEventTable, presenceState, registerPresence, type PresenceInput } from "./hand-presence.ts"
import { approvalMessage, checkApproval, checkRaise, createLevelTables, createPresenceTable, presenceKey, defaultLevel, isLevel, issueChallenge, raises, READ_ACTIONS, type Level, type Proof } from "./hand-levels.ts"
import { createIndexTables, indexDefaultLevel, indexSetDefaultLevel, handName, indexGrants, indexList, indexName, indexPut, indexSetGrant } from "./hand-index.ts"
import { callerLabel, capJson, isHandAction, PAIR_TTL_MS, sameHex, type AgentEvent, type HandCaller, type HandError, type HandReply, type HandSummary, type Profile, type StoredEvent } from "./hand-wire.ts"

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

/** An unacked agent outcome is given up after this long (hand-do.ts sendOutcomes). */
const OUTCOME_GIVE_UP_MS = 6 * 3_600_000
const OUTCOME_MAX_BACKOFF_MS = 10 * 60_000
const HAND_TAG = "hand"
const DEFAULT_TIMEOUT_MS = 60_000
const MAX_TIMEOUT_MS = 15 * 60_000
/** A request that waits for the owner's approval gets this long from the approval on. */
const APPROVAL_WINDOW_MS = 11 * 60_000
const KEEP_EVENTS = 5_000
const KEEP_AUDIT = 10_000
/** A sandbox hand is removed (its VM deleted) this long after it was made. */
const SANDBOX_LIFETIME_MS = 24 * 3600_000
const SANDBOX_DELETE_RETRY_MS = 5 * 60_000

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
  level: string | null
}

/** Mac hands take Cloud requests only where HANDS_MAC_ENABLED is "1" and, when HANDS_MAC_OWNERS lists owners, only for them. */
const macEnabledFor = (env: Env, owner: string): boolean => {
  if (env.HANDS_MAC_ENABLED !== "1") return false
  const only = (env.HANDS_MAC_OWNERS ?? "").split(",").map((x) => x.trim()).filter(Boolean)
  return only.length === 0 || only.includes(owner)
}

const refuse = (code: string, message: string): { readonly ok: false; readonly error: HandError } => ({ ok: false, error: { code, message } })

export class HandDO extends DurableObject<Env> {
  private readonly pending = new Map<string, Pending>()
  private readonly waiters = new Set<() => void>()
  private readonly helloWaiters = new Set<() => void>()
  private inserts = 0

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    const sql = ctx.storage.sql
    sql.exec(`CREATE TABLE IF NOT EXISTS hand (id INTEGER PRIMARY KEY CHECK (id = 1), hand TEXT NOT NULL, owner TEXT NOT NULL, name TEXT NOT NULL, minted_by TEXT NOT NULL, created_at INTEGER NOT NULL, code_sha TEXT, key_sha TEXT, paired_at INTEGER, revoked_at INTEGER, profile TEXT, hello TEXT, last_seen INTEGER)`)
    sql.exec(`CREATE TABLE IF NOT EXISTS hand_grant (agent TEXT PRIMARY KEY)`)
    sql.exec(`CREATE TABLE IF NOT EXISTS hand_audit (seq INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL, req TEXT NOT NULL, action TEXT NOT NULL, who TEXT NOT NULL, outcome TEXT NOT NULL, ms INTEGER)`)
    sql.exec(`CREATE TABLE IF NOT EXISTS hand_approval (id TEXT PRIMARY KEY, req TEXT NOT NULL, summary TEXT NOT NULL, at INTEGER NOT NULL, answered_at INTEGER, allow INTEGER, who TEXT)`)
    createVerdictTable(sql)
    sql.exec(`CREATE TABLE IF NOT EXISTS hand_agent (session TEXT PRIMARY KEY, chief TEXT NOT NULL, conversation TEXT NOT NULL, at INTEGER NOT NULL)`)
    // The brain that drove the session last (agent.send / agent.events): its agent turn outcomes go there; the revoke stays with the starter (its ledger).
    if (!sql.exec<{ name: string }>(`PRAGMA table_info(hand_agent)`).toArray().some((c) => c.name === "driver")) sql.exec(`ALTER TABLE hand_agent ADD COLUMN driver TEXT`)
    // Agent turn outcomes not yet acked by their brain (agentOutcome): resent by alarm with backoff, one row per (session, turn).
    sql.exec(`CREATE TABLE IF NOT EXISTS hand_outcome (key TEXT PRIMARY KEY, target TEXT NOT NULL, body TEXT NOT NULL, tries INTEGER NOT NULL DEFAULT 0, first_at INTEGER NOT NULL, next_at INTEGER NOT NULL)`)
    sql.exec(`CREATE TABLE IF NOT EXISTS hand_sandbox (id INTEGER PRIMARY KEY CHECK (id = 1), vm TEXT NOT NULL)`)
    if (!sql.exec<{ name: string }>(`PRAGMA table_info(hand_sandbox)`).toArray().some((c) => c.name === "provider")) sql.exec(`ALTER TABLE hand_sandbox ADD COLUMN provider TEXT`)
    sql.exec(`CREATE TABLE IF NOT EXISTS hand_event (seq INTEGER PRIMARY KEY AUTOINCREMENT, session TEXT NOT NULL, at INTEGER NOT NULL, body TEXT NOT NULL)`)
    createIndexTables(sql)
    createLevelTables(sql)
    createPresenceTable(sql)
    createPresenceEventTable(sql)
    // The level column came after the first hands: add it to an existing table once.
    if (!sql.exec<{ name: string }>(`PRAGMA table_info(hand)`).toArray().some((c) => c.name === "level")) sql.exec(`ALTER TABLE hand ADD COLUMN level TEXT`)
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"))
  }

  private row(): HandRow | undefined {
    return this.ctx.storage.sql.exec<HandRow>(`SELECT hand, owner, name, minted_by, created_at, code_sha, key_sha, paired_at, revoked_at, profile, hello, last_seen, level FROM hand WHERE id = 1`).toArray()[0]
  }

  /** The newest open hand socket (a replaced one may still be closing). */
  private socket(): WebSocket | undefined {
    return this.ctx.getWebSockets(HAND_TAG).filter((ws) => ws.readyState === WebSocket.OPEN).at(-1)
  }

  private summary(r: HandRow): HandSummary {
    const sandbox = this.ctx.storage.sql.exec(`SELECT 1 FROM hand_sandbox WHERE id = 1`).toArray().length > 0
    return { hand: r.hand, name: r.name, profile: (r.profile as Profile | null) ?? null, created_at: r.created_at, paired_at: r.paired_at, revoked_at: r.revoked_at, last_seen: r.last_seen, online: this.socket() !== undefined, sandbox, level: this.level(r), pending_approvals: this.ctx.storage.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM hand_approval WHERE answered_at IS NULL`).toArray()[0]?.n ?? 0 }
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
  /** `profile` is fixed here, by the owner (or Chief) who mints: the hand cannot pick another later. */
  async mint(hand: string, owner: string, mintedBy: string, codeSha: string, name: string, profile: Profile = "sandbox"): Promise<{ expires_at: number }> {
    const now = Date.now()
    if (this.row()) throw new Error("hand id already used")
    const level = (await this.index(owner).ownerDefaultLevel(profile)) ?? defaultLevel(profile)
    this.ctx.storage.sql.exec(`INSERT INTO hand (id, hand, owner, name, minted_by, created_at, code_sha, profile, level) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?)`, hand, owner, name, mintedBy, now, codeSha, profile, level)
    const grants = await this.index(owner).listGrants()
    this.setGrantsLocal(grants)
    await this.ctx.storage.setAlarm(now + PAIR_TTL_MS)
    await this.publish(this.row()!)
    return { expires_at: now + PAIR_TTL_MS }
  }

  /** Single use: the first valid redeem sets the key hash and clears the code. */
  async redeem(codeSha: string, keySha: string, info: { name: string; profile: Profile; os?: string }): Promise<HandReply<{ hand: string; owner: string }>> {
    const r = this.row()
    const now = Date.now()
    if (!r || !r.code_sha || r.paired_at !== null || now > r.created_at + PAIR_TTL_MS || !sameHex(r.code_sha, codeSha)) {
      return { ok: false, error: { code: "hand.pair_invalid", message: "the pairing code is wrong, used or expired" } }
    }
    // The minted profile wins: a code made for a mac hand never pairs a hand that says sandbox.
    if ((r.profile ?? "sandbox") !== info.profile) {
      return { ok: false, error: { code: "hand.pair_profile", message: `this code is for a ${r.profile ?? "sandbox"} hand; pair with --profile ${r.profile ?? "sandbox"}` } }
    }
    // A sandbox code a Chief made never pairs a Mac: that would be a full-permission hand on a person's computer without them.
    if (info.profile === "sandbox" && info.os === "macos" && r.minted_by.startsWith("agent:")) {
      return { ok: false, error: { code: "hand.pair_profile", message: "a Chief's sandbox code does not pair a Mac; the person mints a mac code" } }
    }
    this.ctx.storage.sql.exec(`UPDATE hand SET code_sha = NULL, key_sha = ?, paired_at = ?, name = ? WHERE id = 1`, keySha, now, info.name || r.name)
    // A sandbox lives at most SANDBOX_LIFETIME_MS; any other hand needs no alarm.
    if (this.sandboxVm()) await this.ctx.storage.setAlarm(r.created_at + SANDBOX_LIFETIME_MS)
    else await this.ctx.storage.deleteAlarm()
    await this.rearm()
    await this.publish(this.row()!)
    return { ok: true, value: { hand: r.hand, owner: r.owner } }
  }

  private sandboxVm(): string | undefined {
    return this.ctx.storage.sql.exec<{ vm: string }>(`SELECT vm FROM hand_sandbox WHERE id = 1`).toArray()[0]?.vm
  }

  /** Deletes this hand's sandbox machine by exact id on its provider; keeps the row (and retries by alarm) until the provider confirms. */
  private async dropSandbox(): Promise<boolean> {
    const row = this.ctx.storage.sql.exec<{ vm: string; provider: string | null }>(`SELECT vm, provider FROM hand_sandbox WHERE id = 1`).toArray()[0]
    if (!row) return true
    const provider = PROVIDERS[row.provider ?? LEGACY_HAND_PROVIDER]
    if (!provider) {
      // A provider this deployment no longer knows: nothing can delete it from here; say so once.
      console.error(JSON.stringify({ msg: "hand.sandbox_provider_unknown", provider: row.provider, vm: row.vm }))
      this.ctx.storage.sql.exec(`DELETE FROM hand_sandbox WHERE id = 1`)
      return true
    }
    if (await provider.remove(this.env, row.vm)) {
      this.ctx.storage.sql.exec(`DELETE FROM hand_sandbox WHERE id = 1`)
      return true
    }
    await this.ctx.storage.setAlarm(Date.now() + SANDBOX_DELETE_RETRY_MS)
    await this.rearm()
    return false
  }

  /** Expired pairing code (the hand and its VM go), a sandbox past its lifetime (revoked), or a VM delete to retry. */
  override async alarm(): Promise<void> {
    if (this.ctx.storage.sql.exec(`SELECT 1 FROM hand_outcome LIMIT 1`).toArray().length > 0) await this.sendOutcomes()
    await this.alarmHand()
    await this.rearm()
  }

  private async alarmHand(): Promise<void> {
    const r = this.row()
    if (r && r.paired_at === null && Date.now() >= r.created_at + PAIR_TTL_MS) {
      if (!(await this.dropSandbox())) return
      this.ctx.storage.sql.exec(`DELETE FROM hand WHERE id = 1`)
      await this.index(r.owner).indexUpdate({ hand: r.hand, removed: true })
      return
    }
    if (r && r.revoked_at === null && this.sandboxVm() && Date.now() >= r.created_at + SANDBOX_LIFETIME_MS) {
      await this.revoke({ kind: "owner", user: r.owner }, "lifetime")
      return
    }
    if (r?.revoked_at != null || !r) await this.dropSandbox()
  }

  /** The sandbox VM this hand runs in (hand-sandbox.ts); deleted with the hand. A hand that is gone takes its VM with it now. */
  async setSandbox(vm: string, provider = LEGACY_HAND_PROVIDER): Promise<void> {
    this.ctx.storage.sql.exec(`INSERT INTO hand_sandbox (id, vm, provider) VALUES (1, ?, ?) ON CONFLICT(id) DO UPDATE SET vm = excluded.vm, provider = excluded.provider`, vm, provider)
    const r = this.row()
    if (!r || r.revoked_at !== null) await this.dropSandbox()
    else await this.publish(r)
  }

  /** A sandbox whose install failed: the hand, its code and its VM go now. */
  async discard(): Promise<void> {
    const r = this.row()
    await this.dropSandbox()
    if (!r) return
    this.ctx.storage.sql.exec(`DELETE FROM hand WHERE id = 1`)
    await this.index(r.owner).indexUpdate({ hand: r.hand, removed: true })
  }

  /** True once the hand is connected and said hello; waits up to `ms` (woken by the hello frame). */
  async waitOnline(ms: number): Promise<boolean> {
    const online = () => this.socket() !== undefined && this.row()?.hello != null
    if (online()) return true
    await new Promise<void>((resolve) => {
      const wake = () => {
        clearTimeout(timer)
        this.helloWaiters.delete(wake)
        resolve()
      }
      const timer = setTimeout(wake, Math.min(ms, 60_000))
      this.helloWaiters.add(wake)
    })
    return online()
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
    if (r.profile === "mac" && !macEnabledFor(this.env, r.owner)) return "hand.mac_disabled"
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
    // A caller never sets the verdict: it is the host classifier's alone.
    const { _verdict: _ignored, _level: _ignoredLevel, ...own } = ((params && typeof params === "object" && !Array.isArray(params) ? params : {}) as Record<string, unknown>)
    // A mac hand: the auto-mode classifier's verdict first (hand-classify.ts); every verdict is kept.
    const level = r ? this.level(r) : "read-only"
    const reading = READ_ACTIONS.has(action)
    // A hand from before levels ignores _level: only full and read-only hold there (the Cloud enforces read-only).
    const knowsLevels = (JSON.parse(r?.hello ?? "{}") as { caps?: unknown }).caps instanceof Array && (JSON.parse(r?.hello ?? "{}") as { caps: Array<unknown> }).caps.includes("levels")
    const stale = !knowsLevels && (level === "ask" || level === "auto") && r?.profile !== "mac"
    // auto: the classifier's verdict first; ask: every write, run and session asks (no classifier); full: neither.
    const verdict = !denied && ws && r && level === "auto" ? await this.verdict(req, caller, r.owner, action, own) : level === "ask" && !reading ? { verdict: "ask" as const, reason: "level ask" } : null
    const forwarded = { ...own, _level: level, ...(verdict ? { _verdict: verdict.verdict } : {}) }
    const result: HandReply = denied
      ? refuse(denied, denied === "hand.mac_disabled" ? "Cloud requests to a Mac hand are off until the trust review" : `refused: ${denied}`)
      : !ws
        ? refuse("hand.offline", "the hand is not connected")
        : level === "read-only" && !reading
          ? refuse("hand.read_only", `this hand is read-only (${action})`)
          : stale && !reading
            ? refuse("hand.update_needed", `this hand's version cannot apply level ${level}; reinstall it`)
          : verdict?.verdict === "deny"
          ? refuse("hand.classifier_denied", `refused as destructive: ${verdict.reason}`)
          : await new Promise<HandReply>((resolve) => {
            const ms = Math.min(Math.max(timeoutMs ?? DEFAULT_TIMEOUT_MS, 1_000), MAX_TIMEOUT_MS)
            const timer = setTimeout(() => this.settle(req, refuse("hand.timeout", `no answer in ${ms} ms`)), ms)
            this.pending.set(req, { resolve, timer })
            try {
              ws!.send(JSON.stringify({ t: "req", id: req, action, params: forwarded ?? {} }))
            } catch {
              this.settle(req, refuse("hand.offline", "the hand socket closed"))
            }
          })
    this.audit(req, action, callerLabel(caller), result.ok ? "ok" : result.error.code, Date.now() - started)
    // A Chief's agent session: its gateway tokens are revoked in its conversation when the hand reports its end.
    const session = (result.ok && action === "agent.start" ? (result.value as { session?: unknown } | null)?.session : undefined)
    if (typeof session === "string" && caller.agent && caller.conversation) {
      this.ctx.storage.sql.exec(`INSERT INTO hand_agent (session, chief, conversation, at) VALUES (?, ?, ?, ?) ON CONFLICT(session) DO NOTHING`, session, caller.agent, caller.conversation, Date.now())
    }
    const driven = result.ok && action === "agent.send" ? (params as { session?: unknown } | null)?.session : undefined
    if (typeof driven === "string" && caller.agent && caller.conversation) this.ctx.storage.sql.exec(`UPDATE hand_agent SET driver = ? WHERE session = ?`, `${caller.agent}/${caller.conversation}`, driven)
    return result
  }

  /** The classifier's verdict for one request, logged with the request (hand-verdicts.ts). */
  private async verdict(req: string, caller: HandCaller, owner: string, action: string, params: unknown): Promise<Classified> {
    const v = await classify(this.env, this.row()?.hand ?? "", owner, caller.agent, req, requestSummary(action, params))
    recordVerdict(this.ctx.storage.sql, req, action, callerLabel(caller), v, requestSummary(action, params, true).text)
    return v
  }

  async verdicts(caller: HandCaller, limit = 100): Promise<HandReply<Array<Record<string, unknown>>>> {
    const r = this.row()
    if (caller.kind !== "owner" || !r || r.owner !== caller.user) return refuse("hand.not_found", "no such hand")
    return { ok: true, value: listVerdicts(this.ctx.storage.sql, limit) }
  }

  private level(r: HandRow): Level {
    return isLevel(r.level) ? r.level : defaultLevel(r.profile as Profile | null)
  }

  /** A single-use challenge the owner's app signs to raise this hand's level (hand-levels.ts). */
  async levelChallenge(caller: HandCaller): Promise<HandReply<{ nonce: string; expires_at: number }>> {
    const r = this.row()
    if (caller.kind !== "owner" || !r || r.owner !== caller.user) return refuse("hand.not_found", "no such hand")
    return { ok: true, value: issueChallenge(this.ctx.storage.sql, r.hand) }
  }

  /** Lowers the level (the owner, or a Chief with the hands grant), or raises it (the owner, with the app proof). */
  async setLevel(caller: HandCaller, to: string, proof?: Proof): Promise<HandReply<{ hand: string; level: Level; from: Level }>> {
    const r = this.row()
    if (!r || r.owner !== caller.user || r.revoked_at !== null) return refuse("hand.not_found", "no such hand")
    if (caller.kind === "chief" && this.ctx.storage.sql.exec(`SELECT 1 FROM hand_grant WHERE agent = ?`, caller.agent ?? "").toArray().length === 0) return refuse("hand.no_grant", "this Chief has no hands grant")
    if (!isLevel(to)) return refuse("request.invalid", "level is full, auto, ask or read-only")
    const from = this.level(r)
    if (raises(from, to)) {
      const why = await checkRaise(this.env, this.ctx.storage.sql, caller, r.owner, r.hand, to, proof, (i) => this.index(r.owner).presenceKeyOf(i))
      if (why) {
        this.audit(crypto.randomUUID(), "level", callerLabel(caller), `refused:${from}->${to}`, null)
        return refuse("hand.level_refused", why)
      }
    }
    this.ctx.storage.sql.exec(`UPDATE hand SET level = ? WHERE id = 1`, to)
    this.audit(crypto.randomUUID(), "level", callerLabel(caller), `${from}->${to}`, null)
    await this.publish(this.row()!)
    return { ok: true, value: { hand: r.hand, level: to, from } }
  }

  // --- Owner index role: presence keys and default levels for new hands ---

  async presenceKeyOf(install: string): Promise<JsonWebKey | null> {
    return presenceKey(this.ctx.storage.sql, install)
  }

  /** The count and current thumbprint a replacement signature covers (hand-presence.ts presenceReplacement). */
  async presenceOf(caller: HandCaller, owner: string, install: string): Promise<HandReply<{ install: string; gen: number; thumbprint: string | null }>> {
    if (caller.kind !== "owner" || caller.user !== owner) return refuse("hand.not_found", "no such hand owner")
    return { ok: true, value: { install, ...presenceState(this.ctx.storage.sql, install) } }
  }

  /** A presence key for one of the owner's installs (hand-presence.ts: the first, or a replacement with the current key's signature or a fresh sign-in). */
  async registerPresence(caller: HandCaller, owner: string, input: PresenceInput): Promise<HandReply<{ install: string; by: string; attested: boolean }>> {
    const r = await registerPresence(this.env, this.ctx.storage.sql, caller, owner, input)
    if (!r.ok) {
      this.audit(crypto.randomUUID(), "presence_key", callerLabel(caller), `refused:${input.install}`, null)
      return refuse("hand.presence_refused", r.why)
    }
    this.audit(crypto.randomUUID(), "presence_key", callerLabel(caller), `${r.by}:${input.install}${r.attested ? ":attested" : ""}`, null)
    // The owner's other devices are told of every new key ("a new Touch ID key was registered on <install>").
    if (r.by !== "unchanged") this.ownerFrame(owner, { t: "hand-presence-key", install: input.install, by: r.by, replaced: r.replaced, attested: r.attested, at: Date.now() })
    return { ok: true, value: { install: input.install, by: r.by, attested: r.attested } }
  }

  async ownerDefaultLevel(profile: Profile): Promise<Level | undefined> {
    const l = indexDefaultLevel(this.ctx.storage.sql, profile)
    return isLevel(l) ? l : undefined
  }

  async defaultChallenge(profile: Profile): Promise<{ nonce: string; expires_at: number }> {
    return issueChallenge(this.ctx.storage.sql, `default:${profile}`)
  }

  /** The owner's default level for new `profile` hands; raising it needs the app proof, a Chief may only lower it. */
  async setOwnerDefault(caller: HandCaller, owner: string, profile: Profile, to: string, proof?: Proof): Promise<HandReply<{ profile: Profile; level: Level }>> {
    if (caller.user !== owner) return refuse("auth.forbidden", "not your hands")
    if (!isLevel(to)) return refuse("request.invalid", "level is full, auto, ask or read-only")
    const from = (await this.ownerDefaultLevel(profile)) ?? defaultLevel(profile)
    if (caller.kind === "chief" && !indexGrants(this.ctx.storage.sql).includes(caller.agent ?? "")) return refuse("hand.no_grant", "this Chief has no hands grant")
    if (raises(from, to)) {
      const why = await checkRaise(this.env, this.ctx.storage.sql, caller, owner, `default:${profile}`, to, proof, async (i) => presenceKey(this.ctx.storage.sql, i))
      if (why) return refuse("hand.level_refused", why)
    }
    indexSetDefaultLevel(this.ctx.storage.sql, profile, to)
    this.audit(crypto.randomUUID(), `default_level:${profile}`, callerLabel(caller), `${from}->${to}`, null)
    return { ok: true, value: { profile, level: to } }
  }

  /** The sweep (hand-sweep.ts): "live" (keep) or "gone" (no live hand holds it: delete); the sweep keeps it when this call fails. */
  async ownsVm(vm: string, provider = LEGACY_HAND_PROVIDER): Promise<"live" | "gone" | "unknown"> {
    const r = this.row()
    const held = this.ctx.storage.sql.exec<{ provider: string | null }>(`SELECT provider FROM hand_sandbox WHERE id = 1`).toArray()[0]
    if (held && (held.provider ?? LEGACY_HAND_PROVIDER) !== provider) return "gone"
    // No row: the hand's code expired or its install failed (the VM carries this deployment's tag).
    if (!r) return "gone"
    return r.revoked_at === null && this.sandboxVm() === vm ? "live" : "gone"
  }

  private settle(req: string, reply: HandReply) {
    const p = this.pending.get(req)
    if (!p) return
    // An approval nobody answered ends with its request: it never shows as waiting again.
    const open = this.ctx.storage.sql.exec<{ id: string }>(`SELECT id FROM hand_approval WHERE req = ? AND answered_at IS NULL`, req).toArray()
    this.ctx.storage.sql.exec(`UPDATE hand_approval SET answered_at = ?, allow = 0, who = 'expired' WHERE req = ? AND answered_at IS NULL`, Date.now(), req)
    const r = open.length > 0 ? this.row() : undefined
    if (r) for (const a of open) this.ownerFrame(r.owner, { t: "hand-approval-settled", hand: r.hand, id: a.id, outcome: "expired" })
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
    // A Chief that waits on the session drives it now: its later turn outcomes go to that Chief's brain.
    if (caller.agent && caller.conversation) this.ctx.storage.sql.exec(`UPDATE hand_agent SET driver = ? WHERE session = ?`, `${caller.agent}/${caller.conversation}`, session)
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
    return { ok: true, value: rows.map((a) => ({ ...a, summary: JSON.parse(a.summary), sign: approvalMessage(this.env, r.hand, a.id) })) }
  }

  /**
   * The owner's answer; one answer per approval. A deny needs only the owner's session; an allow
   * also needs the owner's app proof (a signature by an active Mac or iPhone install of the owner
   * over approvalMessage), the same person proof as a level raise.
   */
  async answer(caller: HandCaller, id: string, allow: boolean, proof?: { install?: string; signature?: string }): Promise<HandReply<{ id: string; allow: boolean }>> {
    if (caller.kind !== "owner") return refuse("auth.forbidden", "only the owner answers approvals")
    const r = this.row()
    if (!r || r.owner !== caller.user) return refuse("hand.not_found", "no such hand")
    const sql = this.ctx.storage.sql
    const a = sql.exec<{ answered_at: number | null }>(`SELECT answered_at FROM hand_approval WHERE id = ?`, id).toArray()[0]
    if (!a) return refuse("hand.approval_not_found", "no such approval")
    if (a.answered_at !== null) return refuse("hand.approval_answered", "this approval was answered already")
    if (allow) {
      const why = await checkApproval(this.env, caller, r.owner, r.hand, id, proof?.install, proof?.signature)
      if (why) {
        this.audit(id, "approval", callerLabel(caller), "allow_refused", null)
        return refuse("hand.approval_proof", why)
      }
    }
    // Re-read after the await: another answer may have committed.
    if (sql.exec<{ answered_at: number | null }>(`SELECT answered_at FROM hand_approval WHERE id = ?`, id).toArray()[0]?.answered_at != null) return refuse("hand.approval_answered", "this approval was answered already")
    sql.exec(`UPDATE hand_approval SET answered_at = ?, allow = ?, who = ? WHERE id = ?`, Date.now(), allow ? 1 : 0, callerLabel(caller), id)
    this.audit(id, "approval", callerLabel(caller), allow ? "allow" : "deny", null)
    this.socket()?.send(JSON.stringify({ t: "approval", id, allow }))
    this.ownerFrame(r.owner, { t: "hand-approval-settled", hand: r.hand, id, outcome: allow ? "allowed" : "denied" })
    await this.publish(r)
    return { ok: true, value: { id, allow } }
  }

  async revoke(caller: HandCaller, why = "owner"): Promise<HandReply<{ hand: string }>> {
    const r = this.row()
    if (caller.kind !== "owner" || !r || r.owner !== caller.user) return refuse("hand.not_found", "no such hand")
    this.ctx.storage.sql.exec(`UPDATE hand SET revoked_at = ?, key_sha = NULL WHERE id = 1`, Date.now())
    // A revoked hand's unsent agent outcomes go (decision 1f-S: no delivery after revoke).
    this.ctx.storage.sql.exec(`DELETE FROM hand_outcome`)
    for (const ws of this.ctx.getWebSockets()) ws.close(4403, "revoked")
    for (const req of [...this.pending.keys()]) this.settle(req, refuse("hand.revoked", "the hand was removed"))
    this.audit(crypto.randomUUID(), "revoke", why === "owner" ? callerLabel(caller) : why, "ok", null)
    await this.dropSandbox()
    await this.publish(this.row()!)
    return { ok: true, value: { hand: r.hand } }
  }

  /** An ephemeral frame to the owner's own sockets (UserDO.handFrame); best effort. */
  private ownerFrame(owner: string, frame: { readonly t: "hand-approval-pending" | "hand-approval-settled" | "hand-presence-key" } & Record<string, unknown>) {
    const user = this.env.USER_DO.get(this.env.USER_DO.idFromName(owner)) as unknown as { handFrame(entity: string, f: typeof frame): Promise<void> }
    this.ctx.waitUntil(user.handFrame(owner, frame).catch(() => undefined))
  }

  /**
   * The outcome of a Chief agent session's latest turn (its events since the last turn_start) to the brain
   * object that started it (`<chief>/<conversation>`, a spawn child included): `agentOutcome` there posts it
   * only when the Chief's own agent call did not already see it. Kept in hand_outcome until the brain acks it (sendOutcomes).
   */
  private async agentOutcome(session: string): Promise<void> {
    const sql = this.ctx.storage.sql
    const r = this.row()
    const a = sql.exec<{ chief: string; conversation: string; driver: string | null }>(`SELECT chief, conversation, driver FROM hand_agent WHERE session = ?`, session).toArray()[0]
    if (!r || !a) return
    const rows = sql.exec<{ seq: number; body: string }>(`SELECT seq, body FROM hand_event WHERE session = ? ORDER BY seq DESC LIMIT 400`, session).toArray().reverse()
    const start = rows.map((x) => (JSON.parse(x.body) as AgentEvent).kind).lastIndexOf("turn_start")
    const turn = rows.slice(Math.max(0, start)).map((x) => ({ seq: x.seq, e: JSON.parse(x.body) as AgentEvent }))
    const last = turn.at(-1)
    if (!last) return
    // A session that ended between turns has no new outcome.
    if (last.e.kind === "session_end" && turn.some((x) => x.e.kind === "turn_end")) return
    const text = turn.flatMap((x) => (x.e.kind === "text" ? [x.e.text] : [])).join("").slice(-4_000)
    const tools = [...new Set(turn.flatMap((x) => (x.e.kind === "tool" && x.e.title ? [x.e.title] : [])))].slice(0, 20)
    const errors = turn.flatMap((x) => (x.e.kind === "error" ? [x.e.message ?? "error"] : [])).slice(0, 5)
    // One outcome per turn: keyed by the turn's turn_start event (a repeated turn_end frame posts nothing new).
    const first = turn[0]!
    if (first.e.kind !== "turn_start") return
    const outcome = { hand: r.hand, hand_name: r.name, session, seq: first.seq, end_seq: last.seq, status: last.e.kind === "turn_end" ? "done" : "failed", stop_reason: last.e.kind === "turn_end" ? (last.e.stop_reason ?? "") : last.e.kind === "session_end" ? `session ended${last.e.reason ? `: ${last.e.reason}` : ""}` : "error", text, tools, errors }
    const now = Date.now()
    sql.exec(`INSERT INTO hand_outcome (key, target, body, first_at, next_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT (key) DO NOTHING`, `${session}:${first.seq}`, a.driver ?? `${a.chief}/${a.conversation}`, JSON.stringify(outcome), now, now)
    await this.sendOutcomes()
  }

  /**
   * Sends every due outcome row to its brain; a row goes when the brain acks it (idempotent there on
   * session and turn). A failed send waits 5 s, doubling to 10 min, and is given up after 6 h.
   */
  private async sendOutcomes(): Promise<void> {
    const sql = this.ctx.storage.sql
    const now = Date.now()
    const due = sql.exec<{ key: string; target: string; body: string; tries: number; first_at: number }>(`SELECT key, target, body, tries, first_at FROM hand_outcome WHERE next_at <= ? ORDER BY next_at LIMIT 50`, now).toArray()
    await Promise.all(
      due.map(async (r) => {
        const brain = this.env.CHIEF_BRAIN_DO.get(this.env.CHIEF_BRAIN_DO.idFromName(r.target)) as unknown as { agentOutcome(o: unknown): Promise<unknown> }
        if (await brain.agentOutcome(JSON.parse(r.body)).then(() => true, () => false)) return void sql.exec(`DELETE FROM hand_outcome WHERE key = ?`, r.key)
        if (now - r.first_at > OUTCOME_GIVE_UP_MS) {
          console.error(JSON.stringify({ msg: "hand.agent_outcome_dropped", key: r.key, tries: r.tries + 1 }))
          return void sql.exec(`DELETE FROM hand_outcome WHERE key = ?`, r.key)
        }
        sql.exec(`UPDATE hand_outcome SET tries = tries + 1, next_at = ? WHERE key = ?`, now + Math.min(OUTCOME_MAX_BACKOFF_MS, 5_000 * 2 ** r.tries), r.key)
      })
    )
    await this.rearm()
  }

  /** The alarm at the earliest need: an outcome to resend, the pairing code's expiry, the sandbox's lifetime, or a pending one. */
  private async rearm(): Promise<void> {
    const r = this.row()
    const next = this.ctx.storage.sql.exec<{ at: number | null }>(`SELECT MIN(next_at) AS at FROM hand_outcome`).one().at
    const now = Date.now()
    // A pairing expiry or lifetime already past was just handled (or its work failed): it waits the delete retry, never loops.
    const later = (at: number) => (at <= now ? now + SANDBOX_DELETE_RETRY_MS : at)
    const wants = [next === null ? null : Number(next), r && r.paired_at === null ? later(r.created_at + PAIR_TTL_MS) : null, r && r.revoked_at === null && this.sandboxVm() ? later(r.created_at + SANDBOX_LIFETIME_MS) : null]
    const cur = await this.ctx.storage.getAlarm()
    const at = Math.min(...[...wants, cur !== null && cur > now ? cur : null].filter((v): v is number => v !== null))
    if (Number.isFinite(at) && at !== cur) await this.ctx.storage.setAlarm(at)
  }

  /** The hand says an agent session ended: its agent tokens stop now (model-gateway/run-token.ts). */
  private async sessionEnded(session: string): Promise<void> {
    const r = this.row()
    const a = this.ctx.storage.sql.exec<{ chief: string; conversation: string }>(`SELECT chief, conversation FROM hand_agent WHERE session = ?`, session).toArray()[0]
    if (!r || !a) return
    const answer = await revokeAgentSession(this.env, a.chief, a.conversation, r.hand, session).catch((e: unknown) => ({ ok: false, error: String(e) }))
    this.audit(crypto.randomUUID(), "agent.session_end", "hand", (answer as { ok?: boolean }).ok === false ? "revoke_failed" : "revoked", null)
    this.ctx.storage.sql.exec(`DELETE FROM hand_agent WHERE session = ?`, session)
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
        // The profile is the paired one; a hand that says another (an edited config) is cut off.
        const said = f.profile === "mac" ? "mac" : "sandbox"
        const paired = this.row()?.profile ?? "sandbox"
        if (said !== paired) {
          this.audit(crypto.randomUUID(), "hello", "hand", `profile_mismatch:${said}`, null)
          _ws.close(4403, "profile mismatch")
          return
        }
        sql.exec(`UPDATE hand SET hello = ?, last_seen = ? WHERE id = 1`, capJson(f, 16_000), now)
        const r = this.row()
        for (const wake of [...this.helloWaiters]) wake()
        if (r) await this.publish(r)
        return
      }
      case "approval-expired": {
        // The hand stopped waiting (an agent's prompt, refused at its timeout): the row closes, so a
        // late answer neither shows as waiting nor reads as allowed.
        const id = String(f.id ?? "")
        const open = id ? sql.exec<{ id: string }>(`SELECT id FROM hand_approval WHERE id = ? AND answered_at IS NULL`, id).toArray() : []
        if (open.length === 0) return
        sql.exec(`UPDATE hand_approval SET answered_at = ?, allow = 0, who = 'expired' WHERE id = ? AND answered_at IS NULL`, now, id)
        const owner = this.row()
        if (owner) {
          this.ownerFrame(owner.owner, { t: "hand-approval-settled", hand: owner.hand, id, outcome: "expired" })
          await this.publish(owner)
        }
        return
      }
      case "approve": {
        const id = String(f.id ?? "")
        const req = String(f.req ?? "")
        if (!id) return
        sql.exec(`INSERT INTO hand_approval (id, req, summary, at) VALUES (?, ?, ?, ?) ON CONFLICT(id) DO NOTHING`, id, req, capJson(f.summary ?? {}, 16_000), now)
        {
          const owner = this.row()
          if (owner) {
            this.ownerFrame(owner.owner, { t: "hand-approval-pending", hand: owner.hand, id, summary: JSON.parse(capJson(f.summary ?? {}, 16_000)), at: now, sign: approvalMessage(this.env, owner.hand, id) })
            await this.publish(owner)
          }
        }
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
        const kind = (f.event as { kind?: unknown }).kind
        // A Chief's agent turn ended (or failed, or the session ended mid-turn): its brain gets the outcome, so a
        // result that comes after the Chief's agent call returned (an approval answered later) still reaches it.
        if (kind === "turn_end" || kind === "session_end") this.ctx.waitUntil(this.agentOutcome(session))
        if (kind === "session_end") await this.sessionEnded(session)
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
