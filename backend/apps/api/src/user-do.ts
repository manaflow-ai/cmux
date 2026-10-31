import type { Domain, EventFrame, OpFrame, OwnerEngine, OwnerFrame, Principal } from "@cmux/ownership"
import { mcpScopesForGrant } from "./mcp-grant.ts"
import { isMachineInstallKind } from "./machine-installs.ts"
import { conversation as homeConversation, inbox as homeInbox, invites, user as homeUser } from "@cmux/home-core"
import { challengeMessagePrefix, type PushTarget } from "@cmux/protocol"
import * as quota from "./home-attachment-quota.ts"
import { deliverKrlNotices, krlDueAt, type KrlRetry } from "./user-krl.ts"
import { emailDomainOf, verifyInstallSignature, type InstallClaims } from "./auth.ts"
import { verifyAttestation, type AttestedKey } from "./app-attest.ts"
import { isCompanyEmail } from "./domains/cloud-plan.ts"
import { admit } from "./domains/common.ts"
import { chiefActive, grantFor, inboxRefusalFor, installActive, grantMigrationsDue, userPathAllowed, jwkThumbprint, makeUserDomain, type UserState } from "./domains/user.ts"
import { appIdHashFor, confirmRead } from "./domains/user-confirm.ts"
import { CHIEF_AGENT_CLASS, chiefList, placedChiefClasses } from "./domains/user-chief.ts"
import { avatarRpc, type AvatarCall } from "./user-avatars.ts"
import type { Env } from "./env.ts"
import { HomePushQueue } from "./home-push.ts"
import { apnsHomePushSender, decideHomePush, drainHomePush, feedHomePushQuiet } from "./home-push-drain.ts"
import { CLOSE_RETRY_MS, flushInstallCloses, markAgentClosing, markInstallClosing, nextCloseAt, registerSocketOwner } from "./socket-registry.ts"
import { OwnerDO, type Attachment, type ReadResult, type SubmitResult } from "./owner-do.ts"
import { SecondaryStream } from "./secondary-stream.ts"
import { pullLargeRows, readInboxOp } from "./user-inbox.ts"
import { checkPresenceKey, type PresenceKeyBody } from "./user-presence-key.ts"
import { homeRateTakeSql, type HomeRateGate, type HomeRateOp } from "./home-rate.ts"

const CHALLENGE_TTL_MS = 2 * 60_000

export type RedeemResult = ({ ok: true } & InstallClaims) | { ok: false; code: "auth.forbidden" | "validation.invalid"; message: string }

/**
 * UserDO: the user's installs, devices, grants and revocation (identity spec
 * section 2). Also verifies install proof of possession for token mint; the
 * one-time challenges live outside the op protocol because they are
 * credentials, not shared entity state.
 */
export type { PresenceKeyBody } from "./user-presence-key.ts"

export class UserDO extends OwnerDO<UserState> {
  /** UserDO is the revocation authority: it closes a revoked install's sockets itself (afterOp). */
  protected override checksInstallRevocation = false
  /** Second stream `inbox:<user>` (lane 15 E2): Home inbox entries, pins, mutes, archive. */
  private readonly inbox: SecondaryStream<homeInbox.InboxHead>
  /** Home push queue (home-push.ts): one row per conversation, the dedupe for redelivered and coalesced bumps. */
  private readonly homePush: HomePushQueue

  /** Sends one Home alert (APNs, as FeedDO); tests replace it inside the object. */
  protected homePushSender = apnsHomePushSender(this.env)

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env, makeUserDomain(appIdHashFor(env.IOS_APP_ID)), "user")
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS auth_challenges (nonce TEXT PRIMARY KEY, install TEXT NOT NULL, expires_at INTEGER NOT NULL)`)
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS auth_team_challenges (nonce TEXT PRIMARY KEY, install TEXT NOT NULL, team TEXT NOT NULL, expires_at INTEGER NOT NULL)`)
    this.homePush = new HomePushQueue(this.sqlStore)
    this.inbox = new SecondaryStream(ctx, this.sqlStore, {
      prefix: "inbox",
      tablePrefix: "inbox_",
      // Params arrive as untrusted JSON; the inbox reducer validates them (validBump, userOp).
      domain: homeInbox.inboxDomain as Domain<homeInbox.InboxHead>,
      // Entries are unordered rows (n = null): snapshots carry the head; clients page with inbox.list.
      // The list order index is derived owner data: its writes never reach subscribers.
      engine: { rowMode: { snapshotTable: homeInbox.TABLE_ENTRY, snapshotTail: 0 }, redact: { privateTables: homeInbox.INBOX_PRIVATE_TABLES } },
      owns: (op) => op.startsWith("inbox."),
      // A chief token (principal.agent) never reads the owner's inbox: it holds the owner's DM previews (cx-59n8.11).
      maySubscribe: (_head, principal, entity) => principal.user === entity && principal.agent === undefined && !isMachineInstallKind(principal.install_kind) && !(principal.install !== undefined && isMachineInstallKind(this.existing()?.currentState.installs[principal.install]?.kind))
    }, (ws, a) => this.socketLive(ws, a))
  }

  /** The inbox engine of the bound user, opened on first use (also after hibernation). */
  private boundInbox() {
    const engine = this.existing()
    return engine ? this.inbox.open(engine.stream.slice("user:".length)) : undefined
  }

  protected override routeFrame(ws: WebSocket, a: Attachment, frame: { readonly t?: string; readonly stream?: unknown; readonly op?: unknown } & Record<string, unknown>): boolean {
    // A chief token never changes the owner's account (installs, grants, chiefs, inbox, presence): refused here too.
    if (frame.t === "op" && a.principal.agent !== undefined) {
      try {
        ws.send(JSON.stringify({ t: "reject", tx: "", idempotency_key: frame.idempotency_key ?? "", code: "auth.forbidden", message: "a chief token cannot change the owner's account", retryable: false, replayed: false }))
      } catch {}
      return true
    }
    // Ops the Worker gates on team policy (agents.allowedClasses, P17-4) never run from the socket.
    if (frame.t === "op" && frame.op === "chief.create") {
      try {
        ws.send(JSON.stringify({ t: "reject", tx: "", idempotency_key: frame.idempotency_key ?? "", code: "validation.invalid", message: "chief.create goes through POST /v1/ops", retryable: false, replayed: false }))
      } catch {}
      return true
    }
    if (!this.inbox.handles(frame)) return false
    const engine = this.existing()
    if (!engine) return false
    this.inbox.onFrame(ws, a, engine.stream.slice("user:".length), frame)
    this.scheduleAlarm()
    return true
  }

  /** One-time grant migrations (idempotent; nothing to do = no op): old iPhone grants get cloud-link (CLOUD-LINK-FOLLOWUPS decision 2); old Mac grants lose execute (cx-wb5.64). */
  protected override bind(entity: string) {
    const engine = super.bind(entity)
    for (const [op, key] of grantMigrationsDue(engine.currentState)) this.submitSystem(op, {}, `${key}:${engine.currentSeq}`)
    return engine
  }

  protected override systemEngine(op: string, entity: string) {
    if (!op.startsWith("inbox.")) return super.systemEngine(op, entity)
    return { engine: this.inbox.open(entity) as OwnerEngine<unknown>, publish: (f: OwnerFrame) => this.inbox.publish(f) }
  }

  protected override nextWakeAt(): number | null {
    this.boundInbox()
    const inbox = this.inbox.nextWakeAt()
    const pending = krlDueAt(this.boundEngine?.currentState, this.krlRetry, Date.now())
    const closes = nextCloseAt(this.ctx.storage.sql, this.closeRetryAt)
    const times = [inbox, pending, closes, this.homePush.nextDueAt()].filter((t): t is number => t !== null)
    return times.length ? Math.min(...times) : null
  }

  /**
   * RPC for the DM reach rule (spec 16.7): every team this user belongs to (role and kind), from the
   * index each TeamDO keeps in step (user.team_index). Never creates an object.
   */
  async homeTeamsOf(entity: string): Promise<Array<{ team: string; role: string; kind: string }>> {
    if (!this.isBound(entity)) return []
    return Object.entries(this.bind(entity).currentState.team_index ?? {})
      .map(([team, v]) => ({ team, role: v.role, kind: v.kind }))
      .sort((a, b) => (a.team < b.team ? -1 : 1))
  }

  /** A chief token never changes the owner's account (security review P2): every UserDO mutation from one is refused. */
  override async submit(entity: string, principal: Principal, frame: OpFrame): Promise<SubmitResult> {
    if (principal.agent === undefined) return super.submit(entity, principal, frame)
    const key = typeof frame.idempotency_key === "string" ? frame.idempotency_key : ""
    return { frames: [{ t: "reject", tx: "", idempotency_key: key, code: "auth.forbidden", message: "a chief token cannot change the owner's account", retryable: false, replayed: false },
      { t: "request-settled", tx: "", idempotency_key: key, stream: `user:${entity}`, sequence: 0, ok: false }] }
  }
  /** A Chief's own chief.create / chief.update from its Cloud brain (brain-chiefs.ts; DO RPC, no route reaches it): user-chief.ts `viaChief`. */
  async chiefManage(entity: string, agent: string, frame: OpFrame): Promise<SubmitResult> { return super.submit(entity, { identity: `agent:${agent} via chief`, kind: "agent", agent, user: entity }, frame) }

  private closeRetryAt: number | null = null // Retry time of a socket close that failed (socket-registry.ts); memory only.

  /** Closes a revoked install's sockets on every other owner (instant revocation). */
  private async flushCloses(now: number): Promise<void> {
    if (this.closeRetryAt !== null && now < this.closeRetryAt) return
    const failed = await flushInstallCloses(this.ctx.storage.sql, this.env, now)
    this.closeRetryAt = failed ? now + CLOSE_RETRY_MS : null
  }

  /**
   * RPC from an owner that accepted a socket of one of this user's installs (socket-gate.ts).
   * False when the install (with this grant) is not active: the owner closes the socket at once,
   * which closes the race between the Worker's check and a revoke.
   */
  async registerSocket(entity: string, install: string, grant: string | undefined, cls: string, name: string, expiresAt: number, agent?: string): Promise<boolean> {
    if (!this.isBound(entity)) return false
    const state = this.bind(entity).currentState
    if (!installActive(state, { identity: install, kind: "install", user: entity, install, ...(grant ? { grant } : {}), ...(agent ? { agent } : {}) })) return false
    registerSocketOwner(this.ctx.storage.sql, install, agent, cls, name, expiresAt, Date.now())
    return true
  }

  /** Backoff after a failed KRL notice (user-krl.ts; in memory: a restart retries at once). */
  private readonly krlRetry: KrlRetry = { at: null, attempts: 0 }

  /**
   * Delivers pending KRL notices for revoked installs to each team's TeamDO and clears each one
   * when every team confirmed (S4). TeamDO's side is idempotent, so a retry after a crash is safe.
   */
  protected override async onWake(now: number): Promise<void> {
    // Each step runs even when an earlier one throws; a failure is logged, then rethrown after all
    // ran, so OwnerDO.alarm still backs off (no hot loop on past-due work) and still reschedules.
    let failure: unknown
    for (const [step, run] of [["closes", () => this.flushCloses(now)], ["home_push", () => this.drainHomePush(now)], ["krl", () => this.deliverKrlNotices(now)]] as const) {
      try {
        await run()
      } catch (e) {
        console.error(JSON.stringify({ msg: "user wake step failed", step, error: String(e).slice(0, 200) }))
        failure ??= e
      }
    }
    if (failure !== undefined) throw failure
  }

  /** Home push decides from each delivered `inbox.bump` in the same storage batch (home-push-drain.ts decideHomePush). */
  protected override afterOp(principal: Principal, op: string, frames: ReadonlyArray<OwnerFrame>, params?: unknown) {
    super.afterOp(principal, op, frames, params)
    this.closeRevoked(op, frames)
    const engine = op === "inbox.bump" && principal.kind === "system" ? this.existing() : undefined
    if (engine) decideHomePush(this.homePush, engine.stream.slice("user:".length), frames, params)
  }

  /** Sends due Home pushes (home-push-drain.ts); tests call it with an explicit time. */
  private async drainHomePush(now: number): Promise<void> {
    const engine = this.existing()
    if (!engine) return
    const entity = engine.stream.slice("user:".length)
    const inbox = this.inbox.open(entity)
    await drainHomePush({
      queue: this.homePush,
      entity,
      entry: (conversation) => inbox.rows.get<homeInbox.InboxEntry>(homeInbox.TABLE_ENTRY, conversation)?.row,
      pushTargets: (e) => this.pushTargets(e),
      quiet: (e) => feedHomePushQuiet(this.env, e),
      send: (targets, message, at) => this.homePushSender(targets, message, at),
      dropPushTarget: (e, token, reason) => this.dropPushTarget(e, token, reason)
    }, now)
  }

  private async deliverKrlNotices(now: number): Promise<void> {
    await deliverKrlNotices(this.env, this.existing()?.currentState, this.krlRetry, now, (install, at, teams) => this.submitSystem("install.ssh_revoke_done", { install, teams }, `ssh-revoke-done:${install}:${at}:${[...teams].sort().join(",")}`))
  }

  protected override onPrune(): void {
    this.boundInbox()
    this.inbox.prune(Date.now())
  }

  /** RPC: an inbox op (pin, mute, archive, mark unread) from the user's session or install. */
  async submitInbox(entity: string, principal: Principal, frame: OpFrame): Promise<SubmitResult> {
    const refused = principal.agent !== undefined ? { code: "auth.forbidden", message: "a chief token cannot change the owner's inbox" } : this.inboxRefusal(entity, principal, frame.op)
    if (refused) return { frames: [{ t: "reject", tx: "", idempotency_key: frame.idempotency_key, code: refused.code, message: refused.message, retryable: false, replayed: false } as OwnerFrame] }
    this.inbox.open(entity)
    const frames: Array<OwnerFrame> = []
    this.inbox.submit(principal, frame, (f) => frames.push(f))
    this.scheduleAlarm()
    return { frames }
  }

  async avatar(call: AvatarCall) { return avatarRpc(this.ctx, this.env, this.existing()?.currentState, call) } // RPC: participant avatars (user-avatars.ts)

  /** RPC: inbox reads. `inbox.list` pages the entries; `inbox.dm_peer` finds an existing DM with a peer (design Q2). */
  async readInbox(entity: string, principal: Principal, op: string, params: Record<string, unknown>): Promise<ReadResult> {
    // A chief token never reads the owner's inbox (DM previews); a future chief that needs it gets an explicit grant (cx-59n8.11).
    if (principal.agent !== undefined) return { ok: false, code: "auth.forbidden", message: "a chief token cannot read the owner's inbox" }
    const refused = this.inboxRefusal(entity, principal, op)
    if (refused) return { ok: false, code: refused.code, message: refused.message }
    const result = readInboxOp(this.inbox, entity, op, params, () => this.scheduleAlarm())
    return op === "inbox.list" ? pullLargeRows(this.env, entity, result) : result
  }

  /** RPC for the Worker's reach check (home-reach.ts, home-messaging.md section 16): only the user's
   *  `allow_requests_from`, never the discovery flags; an object that never served this user answers the default without binding. */
  async homeAllowRequestsFrom(entity: string): Promise<homeConversation.AllowRequestsFrom> {
    if (this.boundEntity() !== entity) return homeUser.DEFAULT_HOME_SETTINGS.allow_requests_from
    return homeUser.homeSettingsOf(this.bind(entity).currentState.home_settings).allow_requests_from
  }

  /**
   * RPC from the Worker before an op that resolves human reach: takes one attempt from `actor`'s
   * hourly budget for `op` (home-rate.ts homeRateTakeSql). An object that never served this user
   * (no user.ensure yet) creates no storage and answers `not_ready`.
   */
  async homeRateTake(entity: string, actor: string, op: HomeRateOp): Promise<HomeRateGate> {
    if (!this.isBound(entity)) return { ok: false, not_ready: true }
    return homeRateTakeSql(this.sqlStore, actor, op, Date.now())
  }

  /**
   * RPC for the Worker's reach check of a chief caller (CHIEF-DONE autonomy rule): when the
   * caller's agent class is `mux` and `agent` is one of this user's active chiefs, the user's DM
   * with each target from the inbox `peer` index (the chief acts under its owner's reach); null
   * for any other class (an automation run that carries a chief's id), an unknown or archived
   * chief, or an object that never served the user. Never creates storage.
   */
  async homeChiefDms(entity: string, agent: string, agentClass: string, targets: ReadonlyArray<string>): Promise<Array<string | null> | null> {
    if (agentClass !== CHIEF_AGENT_CLASS) return null
    if (this.boundEntity() !== entity) return null
    const record = this.bind(entity).currentState.chiefs?.[agent]
    if (!record || record.archived_at !== null || record.owner_user !== entity) return null
    const engine = this.inbox.open(entity)
    return targets.map((target) => homeInbox.dmPeer(engine.rows, target))
  }

  /**
   * POST /v1/presence-key (home-messaging.md section 21): an owner device registers the
   * Secure Enclave key that later signs level lowering. The caller is the install itself.
   * Both platforms: the install key signs `cmux-presence-key-v1\n<environment>\n<user>\n<install>\n<thumbprint>`.
   * iOS also sends an App Attest attestation whose client data is the presence key's thumbprint,
   * verified against Apple's root for this deployment's IOS_APP_ID. Then the system op
   * `user.presence_key.register` commits (usable after 24 h; every device and the email are told).
   */
  async registerPresenceKey(entity: string, principal: Principal, body: PresenceKeyBody): Promise<SubmitResult | { error: { code: string; message: string } }> {
    const checked = await checkPresenceKey(this.env, entity, principal, () => this.bind(entity).currentState, body)
    if ("error" in checked) return checked
    return this.submitSystem("user.presence_key.register", checked.params, checked.key, `system:user:${entity}`)
  }

  /**
   * RPC from TeamDO only (team-vm-plan.md 3c, decision SSH-1): a presence challenge on one of
   * this user's devices, bound to one full-shell SSH certificate request of `team`. The challenge
   * lives in the text confirmation state (same keys, nonces and cooldown as a lowering).
   */
  async presenceChallenge(
    entity: string,
    team: string,
    install: string,
    purpose: unknown
  ): Promise<{ ok: true; value: { sign: unknown; message: string; expires_at: number } } | { ok: false; code: string; message: string }> {
    const engine = this.existing()
    if (!engine || engine.currentState.user?.id !== entity) return { ok: false, code: "selector.not_found", message: "unknown user" }
    const res = this.submitSystem("user.presence.challenge", { install, purpose }, `presence-challenge:${crypto.randomUUID()}`, `system:team:${team}`)
    const reply = res.frames.find((f) => f.t === "result" || f.t === "reject")
    if (!reply || reply.t !== "result") return { ok: false, code: reply && reply.t === "reject" ? reply.code : "owner.unreachable", message: reply && reply.t === "reject" ? reply.message : "no reply" }
    return { ok: true, value: reply.value as { sign: unknown; message: string; expires_at: number } }
  }

  /**
   * RPC from TeamDO only: checks the signed proof for that request and spends its nonce. The
   * ledger key is the nonce, so a TeamDO retry after a crash gets the same answer, and the same
   * nonce with another request is an idempotency conflict (never a second approval).
   */
  async presenceAssert(
    entity: string,
    team: string,
    proof: { install: string; nonce: string; signature: string; app_attest?: string },
    purpose: unknown
  ): Promise<{ asserted: boolean; code?: string; expires_at?: number }> {
    const engine = this.existing()
    if (!engine || engine.currentState.user?.id !== entity) return { asserted: false, code: "selector.not_found" }
    const params = { install: proof.install, nonce: proof.nonce, purpose, presence_sig: proof.signature, ...(proof.app_attest ? { app_attest: proof.app_attest } : {}) }
    const res = this.submitSystem("user.presence.assert", params, `presence-assert:${proof.nonce}`, `system:team:${team}`)
    const reply = res.frames.find((f) => f.t === "result" || f.t === "reject")
    if (!reply || reply.t !== "result") return { asserted: false, code: reply && reply.t === "reject" ? reply.code : "owner.unreachable" }
    return reply.value as { asserted: boolean; code?: string; expires_at?: number }
  }

  /** Inbox calls: this user only, through an active install whose grant covers the op (domains/user.ts). */
  private inboxRefusal(entity: string, principal: Principal, op: string) {
    return principal.user !== entity ? { code: "auth.forbidden", message: "not this user's inbox" } : inboxRefusalFor(this.bind(entity).currentState, entity, principal, op)
  }

  protected read(state: UserState, op: string, params: unknown, principal: Principal): ReadResult {
    if (state.user && principal.user !== state.user.id) return { ok: false, code: "auth.forbidden", message: "not this user" }
    // A revoked install's still-valid token reads nothing (it would otherwise read until the token expires).
    if (!userPathAllowed(state, principal)) return { ok: false, code: "auth.forbidden", message: "install revoked or unknown" }
    if (op === "chief.list") {
      const refused = admit("cloud:UserDO", op, principal, (p) => grantFor(state, p), Date.now())
      return refused ? { ok: false, ...refused } : { ok: true, value: chiefList(state, Date.now(), (params as { include_archived?: unknown } | null)?.include_archived === true), revision: "" }
    }
    if (op === "user.text_confirm.get" || op === "user.presence_key.list") return confirmRead(op, state, principal, () => admit("cloud:UserDO", op, principal, (p) => grantFor(state, p), Date.now()))
    if (op !== "install.list") return { ok: false, code: "validation.invalid", message: `unknown read ${op}` }
    return { ok: true, value: { user: state.user, installs: Object.values(state.installs), grants: Object.values(state.grants) }, revision: "" }
  }

  /** Device push tokens reach only the user's session and the install that owns each token. */
  protected override subscriberView(state: UserState, principal: Principal): unknown {
    if (principal.kind === "session" || !state.push_targets) return state
    const own = Object.fromEntries(Object.entries(state.push_targets).filter(([, t]) => t.install === principal.install))
    return { ...state, push_targets: own }
  }

  /** Push-target events carry a device token: only the session and the install that owns it receive them. */
  protected override mayReceive(_state: UserState, event: EventFrame, principal: Principal): boolean {
    if (!event.op.startsWith("push.target.")) return true
    return principal.kind === "session" || (principal.install !== undefined && event.actor.install === principal.install)
  }

  protected maySubscribe(state: UserState, principal: Principal): boolean {
    return (!state.user || state.user.id === principal.user) && userPathAllowed(state, principal)
  }

  /** RPC from other owners (OwnerDO.runInstallChecks): which of these installs (with the token's grant) are active. Never creates an object. */
  async installsActive(entity: string, list: ReadonlyArray<{ install: string; grant: string | undefined; agent?: string }>): Promise<ReadonlyArray<boolean>> {
    // One answer per entry, in order (two sockets of one install may hold different grants).
    if (!this.isBound(entity)) return list.map(() => false)
    const state = this.bind(entity).currentState
    return list.map((x) => installActive(state, { identity: x.install, kind: "install", user: entity, install: x.install, ...(x.grant ? { grant: x.grant } : {}), ...(x.agent ? { agent: x.agent } : {}) }))
  }

  /** A revoked install loses its open sockets at once, not at token expiry. */
  private closeRevoked(op: string, frames: ReadonlyArray<OwnerFrame>) {
    const result = frames.find((f) => f.t === "result")
    // An archived or deleted chief's token stops at once: its sockets here and on every other owner close.
    if ((op === "chief.archive" || op === "chief.delete") && result && result.t === "result") {
      const agent = (result.value as { id?: string }).id
      if (!agent) return
      this.closeSockets((p) => p.agent === agent, op === "chief.delete" ? "chief deleted" : "chief archived")
      // Its sandboxes pause (archive: a restore resumes them) or are deleted (delete), and their Freestyle identity
      // (tokens and grants) is revoked (chief-brain-cc/sandbox.ts).
      const sandboxes = this.env.CHIEF_BRAIN_DO.get(this.env.CHIEF_BRAIN_DO.idFromName(`${agent}/sandboxes`)) as unknown as { ccSandboxRetire(): Promise<unknown>; ccSandboxPurge(): Promise<unknown> }
      this.ctx.waitUntil((op === "chief.delete" ? sandboxes.ccSandboxPurge() : sandboxes.ccSandboxRetire()).catch(() => undefined))
      if (markAgentClosing(this.ctx.storage.sql, agent, Date.now()) > 0) this.ctx.waitUntil(this.flushCloses(Date.now()).finally(() => this.scheduleAlarm()))
      return
    }
    if (op !== "install.revoke" && op !== "install.revoke_by_team" && op !== "user.team_left") return
    const v = result && result.t === "result" ? (result.value as { id?: string; revoked?: Array<string>; sso_dropped?: Array<string> }) : undefined
    // One install, or every install bound to a team the user left (cx-44j.47), and the ones that lost its SSO: their sockets
    // carry the old principal, so they close and reconnect through the gate. Other owners' sockets close too; failures retry.
    let marked = 0
    for (const revoked of [...(v?.revoked ?? (v?.id ? [v.id] : [])), ...(v?.sso_dropped ?? [])]) [this.closeSockets((p) => p.install === revoked, "install revoked"), (marked += markInstallClosing(this.ctx.storage.sql, revoked, Date.now()))]
    if (marked > 0) this.ctx.waitUntil(this.flushCloses(Date.now()).finally(() => this.scheduleAlarm()))
  }

  /**
   * RPC from TeamDO only (plans/cmux-next/server.md 6.5): the team revoked a
   * server whose install is bound to it. Revokes the grant and closes the
   * install's sockets in the same commit; refuses an install not bound to `team`.
   */
  async revokeByTeam(entity: string, team: string, install: string, by: string, idempotencyKey: string): Promise<{ ok: true } | { ok: false; code: string; message: string }> {
    const engine = this.existing()
    if (!engine || engine.currentState.user?.id !== entity) return { ok: false, code: "selector.not_found", message: "unknown user" }
    const res = this.submitSystem("install.revoke_by_team", { install, team, by }, idempotencyKey, `system:team:${team}`)
    const reply = res.frames.find((f) => f.t === "result" || f.t === "reject")
    return reply && reply.t === "result" ? { ok: true } : { ok: false, code: reply && reply.t === "reject" ? reply.code : "owner.unreachable", message: reply && reply.t === "reject" ? reply.message : "no reply" }
  }

  /** Home attachment quota (home-attachment-quota.ts): every upload slot is charged; refunds and stored bytes by key. */
  async takeAttachmentQuota(entity: string, key: string, bytes: number): Promise<quota.TakeResult> {
    return this.attachmentSql(entity) ? quota.take(this.ctx.storage.sql, key, bytes, Date.now()) : quota.FORBIDDEN
  }

  async refundAttachmentQuota(entity: string, key: string): Promise<void> {
    if (this.attachmentSql(entity)) quota.refund(this.ctx.storage.sql, key)
  }

  async recordAttachmentStorage(entity: string, objectKey: string, bytes: number): Promise<void> {
    if (this.attachmentSql(entity)) quota.recordStored(this.ctx.storage.sql, objectKey, bytes)
  }

  async releaseAttachmentStorage(entity: string, objectKey: string): Promise<void> {
    if (this.attachmentSql(entity)) quota.releaseStored(this.ctx.storage.sql, objectKey)
  }

  /** Attachment counter tables of a bound user; false (no write) for an id this object never served. */
  private attachmentSql(entity: string): boolean {
    const engine = this.existing()
    if (!engine || engine.stream !== `user:${entity}`) return false
    quota.ensureTables(this.ctx.storage.sql)
    return true
  }

  /** Bound user state, or undefined for an id this object never served (no storage is created). */
  private existing() {
    const row = this.boundRow()
    return row ? this.bind(row.entity) : undefined
  }

  /** For FeedDO and Home push: the user's push targets whose install is still active (feed.md 7.3). */
  async pushTargets(entity: string): Promise<ReadonlyArray<PushTarget>> {
    const engine = this.existing()
    if (!engine || engine.stream !== `user:${entity}`) return []
    const state = engine.currentState
    return Object.values(state.push_targets ?? {}).filter((t) => state.installs[t.install]?.revoked_at === null)
  }

  /** For FeedDO and Home push: APNs rejected this token (unregistered or bad); the owner drops it in its own op. */
  async dropPushTarget(entity: string, token: string, reason: string): Promise<void> {
    const engine = this.existing()
    if (!engine || engine.stream !== `user:${entity}`) return
    this.submitSystem("push.target.drop", { token, reason }, `drop:${token}:${engine.currentSeq}`)
  }

  /** Message request trust (home-routes.ts): the domain of this user's verified email, or null. Never the address itself. */
  async homeVerifiedEmailDomain(entity: string): Promise<string | null> {
    const u = this.existing()?.currentState.user
    return u && u.id === entity && u.email_verified ? invites.emailDomain(u.email) : null
  }
  /**
   * Same-domain reach (home-routes.ts dm.open by email, DESIGN 2.4): when this user's verified
   * email has `senderDomain`, that domain is a company domain, and `trust_same_domain` is on,
   * the reach fact for the sender (this user's name and `allow_requests_from`); else null.
   */
  async homeSameDomainReach(entity: string, senderDomain: string): Promise<{ display_name: string; allow_requests_from: homeConversation.AllowRequestsFrom } | null> {
    const engine = this.existing()
    const u = engine?.currentState.user
    if (!engine || !u || u.id !== entity || u.email_verified !== true) return null
    const settings = homeUser.homeSettingsOf(engine.currentState.home_settings)
    if (!settings.trust_same_domain || !invites.requestTrusted(senderDomain, invites.emailDomain(u.email))) return null
    return { display_name: u.display_name, allow_requests_from: settings.allow_requests_from }
  }
  /** CloudDO (cloud-entitlements.ts): whether this user's verified email is a company account (cloud-plan.ts isCompanyEmail). Never the address itself. */
  async cloudCompanyAccount(entity: string): Promise<boolean> {
    const u = this.existing()?.currentState.user
    return Boolean(u && u.id === entity && u.email_verified === true && isCompanyEmail(u.email))
  }
  async stackUserOf(entity: string): Promise<string | null> { const u = this.existing()?.currentState.user; return u && u.id === entity ? u.stack_user_id : null } // CloudDO: the owner's Stack user id (cloud-coderouter-edge.ts)
  /** TeamDO's identity check only: an active daemon's public key, scoped to its existing team and grant. */
  async serverKey(entity: string, install: string, grant: string, team: string): Promise<JsonWebKey | null> {
    const engine = this.existing()
    if (!engine || engine.stream !== `user:${entity}`) return null
    const state = engine.currentState, inst = state.installs[install], held = state.grants[grant]
    if (!state.user || !inst || inst.kind !== "daemon" || inst.bound_team !== team || inst.revoked_at !== null || inst.grant !== grant
      || !held || held.revoked_at !== null || (held.expires_at !== null && held.expires_at <= Date.now()) || !held.op_classes.includes("mutate-own")) return null
    return inst.public_jwk as JsonWebKey
  }
  /** Public identity only, pinned to the calling client's exact current grant. */
  async deviceKey(entity: string, install: string, grant: string): Promise<JsonWebKey | null> {
    const engine = this.existing()
    if (!engine || engine.stream !== `user:${entity}`) return null
    const state = engine.currentState, inst = state.installs[install], held = state.grants[grant]
    if (!state.user || !inst || !["mac", "ios", "cli"].includes(inst.kind) || inst.revoked_at !== null || inst.grant !== grant
      || !held || held.revoked_at !== null || (held.expires_at !== null && held.expires_at <= Date.now()) || !held.op_classes.includes("mutate-own")) return null
    return inst.public_jwk as JsonWebKey
  }
  /** For other owners (TeamDO): is this install active, and what does its grant allow? */
  async installGrant(entity: string, install: string, grant: string, agent?: string): Promise<{ ok: true; op_classes: ReadonlyArray<string>; kind: string; email: string | null; email_verified: boolean; bound_machine?: string; sso_team?: string } | { ok: false }> {
    const engine = this.existing()
    if (!engine || engine.stream !== `user:${entity}`) return { ok: false }
    const state = engine.currentState
    const inst = state.installs[install]
    const g = state.grants[grant]
    if (!inst || inst.revoked_at !== null || inst.grant !== grant || !g || g.revoked_at !== null || (g.expires_at !== null && g.expires_at <= Date.now())) return { ok: false }
    const op_classes = agent === undefined ? g.op_classes : await placedChiefClasses(state, inst, install, agent, g.op_classes, (team, host) => this.env.TEAM_DO.get(this.env.TEAM_DO.idFromName(team)).serverPlacementActive(team, host, install), () => engine.currentState)
    if (!op_classes) return { ok: false } // unknown or archived chief, or a placed server TeamDO no longer confirms (G8, revoke race)
    return { ok: true, op_classes, kind: inst.kind, email: state.user?.email ?? null, email_verified: state.user?.email_verified === true, ...(inst.bound_machine ? { bound_machine: inst.bound_machine } : {}), ...(inst.sso_team ? { sso_team: inst.sso_team } : {}) }
  }

  async challenge(entity: string, install: string, team?: string): Promise<{ ok: true; nonce: string; expires_at: number } | { ok: false; message: string }> {
    const engine = this.existing()
    // One answer for every refusal, so the endpoint does not reveal which users or installs exist.
    if (!engine || engine.stream !== `user:${entity}`) return { ok: false, message: "challenge refused" }
    const inst = engine.currentState.installs[install]
    if (!inst || inst.revoked_at !== null) return { ok: false, message: "challenge refused" }
    if (team !== undefined && (!/^team_[0-9a-f]{20}$/.test(team) || !isClientInstall(inst.kind))) return { ok: false, message: "challenge refused" }
    const now = Date.now()
    const nonce = crypto.randomUUID().replace(/-/g, "") + crypto.randomUUID().replace(/-/g, "")
    const sql = this.ctx.storage.sql
    sql.exec(`DELETE FROM auth_challenges WHERE expires_at < ?`, now)
    sql.exec(`DELETE FROM auth_team_challenges WHERE expires_at < ?`, now)
    if (team === undefined) sql.exec(`INSERT INTO auth_challenges (nonce, install, expires_at) VALUES (?, ?, ?)`, nonce, install, now + CHALLENGE_TTL_MS)
    else sql.exec(`INSERT INTO auth_team_challenges (nonce, install, team, expires_at) VALUES (?, ?, ?, ?)`, nonce, install, team, now + CHALLENGE_TTL_MS)
    return { ok: true, nonce, expires_at: now + CHALLENGE_TTL_MS }
  }

  /**
   * A hand's ephemeral frames (hand-do.ts: `hand-approval-pending`, `hand-approval-settled`) to this
   * person's own subscribed sockets: a person's session or app install, never a Chief token or a
   * machine install. Never committed (GET /v1/hands/<hand>/approvals is the read after a reconnect).
   */
  async handFrame(entity: string, frame: { readonly t: "hand-approval-pending" | "hand-approval-settled" } & Record<string, unknown>): Promise<void> {
    const text = JSON.stringify(frame)
    for (const ws of this.ctx.getWebSockets()) {
      const a = ws.deserializeAttachment() as Attachment | null
      if (!a?.subscribed || a.principal.user !== entity || a.principal.agent !== undefined || isMachineInstallKind(a.principal.install_kind)) continue
      if (!this.socketLive(ws, a)) continue
      try {
        ws.send(text)
      } catch {}
    }
  }

  /** The key of one of this person's active app installs (mac or ios), for a person proof (hand-levels.ts); null otherwise. */
  async personKey(entity: string, install: string): Promise<JsonWebKey | null> {
    const engine = this.existing()
    if (!engine || engine.stream !== `user:${entity}`) return null
    const state = engine.currentState
    const inst = state.installs[install]
    if (!state.user || !inst || inst.revoked_at !== null || (inst.kind !== "mac" && inst.kind !== "ios")) return null
    const grant = state.grants[inst.grant]
    return grant && grant.revoked_at === null ? (inst.public_jwk as JsonWebKey) : null
  }

  /** Live membership authority used only after the caller proves possession of its install key. */
  protected tokenTeamMember = (team: string, user: string): Promise<string | null> =>
    this.env.TEAM_DO.get(this.env.TEAM_DO.idFromName(team)).memberRole(team, user)

  /** One-time challenge + ES256 signature by the install key + revocation check. */
  async redeem(entity: string, install: string, nonce: string, signature: string, agent?: string): Promise<RedeemResult> {
    const engine = this.existing()
    if (!engine || engine.stream !== `user:${entity}`) return { ok: false, code: "auth.forbidden", message: "challenge unknown, used or expired" }
    const sql = this.ctx.storage.sql
    const row = sql.exec<{ install: string; expires_at: number; team: string | null }>(`SELECT install, expires_at, NULL AS team FROM auth_challenges WHERE nonce = ? UNION ALL SELECT install, expires_at, team FROM auth_team_challenges WHERE nonce = ?`, nonce, nonce).toArray()[0]
    // Consume first: a nonce is single use even when the signature fails.
    sql.exec(`DELETE FROM auth_challenges WHERE nonce = ?`, nonce)
    sql.exec(`DELETE FROM auth_team_challenges WHERE nonce = ?`, nonce)
    if (!row || row.install !== install || row.expires_at < Date.now()) return { ok: false, code: "auth.forbidden", message: "challenge unknown, used or expired" }
    const state = engine.currentState
    const inst = state.installs[install]
    if (!inst || inst.revoked_at !== null || !state.user) return { ok: false, code: "auth.forbidden", message: "install unknown or revoked" }
    const grant = state.grants[inst.grant]
    if (!grant || grant.revoked_at !== null || (grant.expires_at !== null && grant.expires_at <= Date.now())) return { ok: false, code: "auth.forbidden", message: "grant revoked or expired" }
    if (row.team !== null && (!isClientInstall(inst.kind) || agent !== undefined)) return { ok: false, code: "auth.forbidden", message: "a scoped challenge requires a client install" }
    const ok = await verifyInstallSignature(inst.public_jwk, `${challengeMessagePrefix(this.env.ENVIRONMENT, install, row.team ?? undefined)}${nonce}`, signature)
    if (!ok) return { ok: false, code: "auth.forbidden", message: "bad signature" }
    // Membership is checked only after proof of possession; the nonce, not a request header, selects the team.
    if (row.team !== null && row.team !== state.user.personal_team) {
      const role = await this.tokenTeamMember(row.team, entity)
      if (!role) return { ok: false, code: "auth.forbidden", message: "not a member of this team" }
    }
    // Re-read after all awaits: revocation, expiry or replacement may have committed during verification or membership lookup.
    const now = engine.currentState
    const current = now.installs[install]
    const held = now.grants[grant.id]
    if (!current || current.revoked_at !== null || current.grant !== grant.id || current.public_jwk.x !== inst.public_jwk.x || current.public_jwk.y !== inst.public_jwk.y || !held || held.revoked_at !== null || (held.expires_at !== null && held.expires_at <= Date.now()) || row.expires_at <= Date.now() || !now.user) return { ok: false, code: "auth.forbidden", message: "install unknown or revoked" }
    // A chief token only for an unarchived chief of this user.
    if (agent !== undefined && (!chiefActive(now, agent) || isMachineInstallKind(current.kind))) return { ok: false, code: "auth.forbidden", message: "agent unknown or archived" }
    const emailDomain = emailDomainOf(now.user.email)
    if (row.team !== null && !isClientInstall(current.kind)) return { ok: false, code: "auth.forbidden", message: "a scoped challenge requires a client install" }
    const team = row.team ?? ((isMachineInstallKind(current.kind) || current.kind === "daemon") && current.bound_team ? current.bound_team : now.user.personal_team)
    // Existing proof-of-possession mint: no separate hosted token endpoint. Agent/chief and
    // non-CLI credentials cannot acquire MCP authority by supplying a scope in the request.
    const scopes = this.env.PLATFORM_AGENT_GATEWAY === "on" && ["development", "test"].includes(this.env.ENVIRONMENT) && agent === undefined
      ? mcpScopesForGrant(current.kind, held.op_classes) : []
    return { ok: true, user: now.user.id, team, install, grant: grant.id, ...(scopes.length ? { scope: scopes.join(" ") } : {}), ...(current.sso_team ? { sso_team: current.sso_team } : {}), ...(emailDomain ? { email_domain: emailDomain } : {}), ...(agent ? { agent } : {}), ...(current.kind === "vm" ? { vm: true as const } : {}), ...(current.kind === "team-vm" ? { team_vm: true as const } : {}) }
  }
}

const isClientInstall = (kind: string) => kind === "mac" || kind === "ios" || kind === "cli"
