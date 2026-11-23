import { envForObject } from "../build-space.ts"
import { DurableObject } from "cloudflare:workers"
import type { Env, RawEnv } from "../env.ts"
import { appendEvents, dropEvents, EVENTS_TABLE, planAppend, readEvents, type EventIn, type EventOut } from "./events.ts"
import { ackInbox, addMessage, dropInbox, INBOX_TABLE, readInbox, sentState, type InboxMessage } from "./inbox.ts"
import { ackAssignment, close, cloudRecord, deliver, edit, fence, keep, leaseDue, machineSet, nextDue, openRecord, release, renew, tick, type LeaseRole, type OpenInput, type Refuse, type RenewInput, type Step } from "./lease.ts"
import { isVm, LEASE_MS, MAX_CHAT_BYTES, MAX_CHUNK_BYTES, MAX_INBOX_PENDING, MAX_WAIT_MS, viewOf, vmHolder, type AutoCaller, type AutoIndexEntry, type AutoMachine, type AutoRecord, type AutoRefusal, type AutoRepo, type AutoResult, type AutoSessionView, type InboxState } from "./model.ts"
import { armIndexRetry, indexState, insertRecord, loadRecord, markIndexed, saveRecord } from "./record-store.ts"
import { acceptSnapshot, chunkNames, CHUNKS_TABLE, dropSnapshots, getChunk, hasChunk, putChunk, readSnapshot, roomForChunk, sha256Hex, SNAPSHOTS_TABLE, weighChunks } from "./snapshots.ts"

/** How soon a chat retries a failed write to its owner's index. */
const INDEX_RETRY_MS = 30_000
/** How soon the alarm looks again after it could not read the owner's Auto machine. */
const ALARM_RETRY_MS = 5_000
const COPY_TABLES = [EVENTS_TABLE, CHUNKS_TABLE, SNAPSHOTS_TABLE, INBOX_TABLE]

const ok = <T>(value: T): AutoResult<T> => ({ ok: true, value })
const NOT_FOUND: AutoRefusal = { ok: false, code: "not_found", message: "Auto chat not found" }
const TOO_LARGE: Refuse = { fail: "auto.too_large", message: "the chat is too large to keep a Cloud copy" }

const indexEntry = (r: AutoRecord, now: number): AutoIndexEntry => ({
  id: r.id,
  owner: r.owner,
  view: viewOf(r, now),
  assignment: r.assignment !== null && isVm(r.holder) && r.machine !== null && r.team !== null ? { kind: r.assignment, machine: r.machine, team: r.team } : null
})

/**
 * AutoSessionDO: one per Auto chat (name = `<owner>/<chat id>`, so no caller reaches another owner's chat). It is
 * the only writer of the chat's record, lease, events, chunks, snapshot and inbox.
 *
 * Every change is one decision and its write in one storage transaction (`apply`): a pure rule of lease.ts reads
 * the record there and answers the next one or a refusal. After a change a viewer can see, it wakes its waits and
 * writes its row in the owner's AutoSessionIndexDO. That row also carries the assignment a machine has not acked,
 * which is how the machine finds its chats and how the index knows to start it.
 *
 * One alarm serves three clocks: a laptop's lease end, a standby that stopped renewing, and the retry of an index
 * write that did not land. The change that moves a clock sets the alarm in the same write.
 */
export class AutoSessionDO extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, raw: RawEnv) {
    super(ctx, envForObject(ctx, raw))
  }

  private readonly waiters = new Set<() => void>()
  /** Alarm runs in order, one at a time; a test waits on it. */
  alarmIdle: Promise<void> = Promise.resolve()

  private get sql(): SqlStorage {
    return this.ctx.storage.sql
  }

  /**
   * The chat, when `by` may reach it. An owner reaches their own chats. A machine reaches a chat it holds; for a
   * write, also one it held last, so it is told `auto.stale_epoch` rather than that the chat is gone.
   */
  private admitted(by: AutoCaller, write: boolean): AutoRecord | undefined {
    const r = loadRecord(this.sql)
    if (!r || r.owner !== by.owner) return undefined
    if (by.kind === "owner" || r.holder === vmHolder(by.machine)) return r
    return write && r.machine === by.machine ? r : undefined
  }

  private autoMachine(owner: string): Promise<AutoMachine | null> {
    const ns = this.env.AUTO_SESSION_INDEX_DO!
    return ns.get(ns.idFromName(owner)).machine()
  }

  /** Sets the alarm to the nearest clock, or clears it. Call it before any await after a write, so the alarm commits with the write. */
  private async schedule(notBefore = 0): Promise<void> {
    const r = loadRecord(this.sql)
    if (!r) return
    const { indexed, retryAt } = indexState(this.sql)
    const times = [nextDue(r), indexed < r.version && retryAt > 0 ? retryAt : null].filter((t): t is number => t !== null)
    if (times.length === 0) return this.ctx.storage.deleteAlarm()
    await this.ctx.storage.setAlarm(Math.max(Math.min(...times), notBefore))
  }

  /** After a change a viewer can see: wake the waits, write the owner's index. The change armed the retry, so a write lost here is tried again. */
  private async changed(): Promise<void> {
    for (const wake of [...this.waiters]) wake()
    const r = loadRecord(this.sql)!
    if (indexState(this.sql).indexed >= r.version) return
    let set: AutoMachine | null = null
    try {
      const ns = this.env.AUTO_SESSION_INDEX_DO!
      set = await ns.get(ns.idFromName(r.owner)).put(indexEntry(r, Date.now()))
      markIndexed(this.sql, r.version)
    } catch (e) {
      console.warn(JSON.stringify({ msg: "auto_sessions.index_put_failed", error: String(e).slice(0, 200) }))
      armIndexRetry(this.sql, Date.now() + INDEX_RETRY_MS)
    }
    await this.schedule()
    // To a chat that waits for an Auto machine the index answers the one the owner has. So a machine set while
    // this chat was being parked, or whose word did not reach this chat, is not missed.
    if (set) await this.machineSet(r.owner, set)
  }

  /**
   * One decision and its write, in one transaction: `decide` reads the record there and answers the record to
   * write, an answer with no write, or a refusal. A write a viewer can see (`loud`) takes the next version and arms
   * the index retry in the same transaction; a quiet one (a renewal that changes nothing a viewer sees, a chunk)
   * moves no version, so no wait wakes for it.
   */
  private async apply<T>(decide: (r: AutoRecord, now: number) => Step<T>): Promise<AutoResult<{ readonly out: T; readonly session: AutoSessionView }>> {
    const now = Date.now()
    const done = this.ctx.storage.transactionSync((): { readonly refused: AutoRefusal } | { readonly out: T; readonly rec: AutoRecord; readonly wrote: boolean; readonly loud: boolean } => {
      const r = loadRecord(this.sql)!
      const step = decide(r, now)
      if ("fail" in step) return { refused: { ok: false, code: step.fail, message: step.message, session: viewOf(r, now), ...(step.extra ? { extra: step.extra } : {}) } }
      if (!step.rec) return { out: step.out, rec: r, wrote: false, loud: false }
      const loud = step.loud === true
      const rec: AutoRecord = loud ? { ...step.rec, version: r.version + 1, updatedAt: now } : step.rec
      saveRecord(this.sql, rec)
      if (loud) armIndexRetry(this.sql, now + INDEX_RETRY_MS)
      return { out: step.out, rec, wrote: true, loud }
    })
    if ("refused" in done) return done.refused
    if (done.wrote) await this.schedule()
    if (done.loud) await this.changed()
    return ok({ out: done.out, session: viewOf(done.rec, now) })
  }

  override alarm(): Promise<void> {
    return (this.alarmIdle = this.alarmIdle.then(() => this.due()))
  }

  /** The alarm: a laptop's lease that ran out, standbys that lapsed, an index write to try again. Never throws: a failure looks again shortly. */
  private async due(): Promise<void> {
    let notBefore = 0
    try {
      const r = loadRecord(this.sql)
      if (!r) return
      const now = Date.now()
      if ((nextDue(r) ?? Infinity) <= now) {
        // The Auto machine is read only for a lease that ran out; nothing else changed if that read was not needed.
        const machine = leaseDue(r, now) ? await this.autoMachine(r.owner) : null
        await this.apply<null>((current) => {
          const next = tick(current, machine, now)
          return next ? { out: null, rec: next, loud: true } : { out: null }
        })
      }
      const { indexed, retryAt } = indexState(this.sql)
      if (indexed < loadRecord(this.sql)!.version && retryAt <= Date.now()) await this.changed()
    } catch (e) {
      console.warn(JSON.stringify({ msg: "auto_sessions.alarm_failed", error: String(e).slice(0, 200) }))
      notBefore = Date.now() + ALARM_RETRY_MS
    }
    await this.schedule(notBefore).catch(() => undefined)
  }

  private async create(rec: AutoRecord, also: () => void): Promise<AutoResult<AutoSessionView>> {
    this.ctx.storage.transactionSync(() => {
      insertRecord(this.sql, rec, COPY_TABLES)
      also()
      armIndexRetry(this.sql, rec.createdAt + INDEX_RETRY_MS)
    })
    await this.schedule()
    await this.changed()
    return ok(viewOf(loadRecord(this.sql)!, Date.now()))
  }

  /**
   * `PUT /v1/auto-sessions/:id`. With `input`: the first call makes the chat, held by the laptop that sent it, at
   * epoch 1; later calls update what it names, and open a closed chat again. Without (`auto: false`): the chat closes.
   */
  async open(owner: string, id: string, team: string | null, input: OpenInput | null): Promise<AutoResult<AutoSessionView>> {
    const existing = loadRecord(this.sql)
    if (existing && existing.owner !== owner) return NOT_FOUND
    if (!existing) return input ? this.create(openRecord(id, owner, team, input, Date.now()), () => undefined) : NOT_FOUND
    const r = await this.apply<null>((current, now) => {
      if (input) return edit(current, input, now)
      const step = close(current)
      if (!("fail" in step) && step.rec) {
        dropEvents(this.sql)
        dropSnapshots(this.sql)
        dropInbox(this.sql)
      }
      return step
    })
    return r.ok ? ok(r.value.session) : r
  }

  /** `POST /v1/auto-sessions`: a chat started with no laptop. The Auto machine holds it and has to create it; its first message waits in the inbox. */
  async createCloud(owner: string, id: string, input: { readonly title: string; readonly harness: string; readonly repo: AutoRepo; readonly message: { readonly id: string; readonly text: string } }): Promise<AutoResult<AutoSessionView>> {
    const seen = loadRecord(this.sql)
    if (seen) return seen.owner === owner ? ok(viewOf(seen, Date.now())) : NOT_FOUND
    const machine = await this.autoMachine(owner)
    if (!machine) return { ok: false, code: "auto.no_machine", message: "no Auto machine is set" }
    // A repeat of the same request may have made it while the machine was read.
    const again = loadRecord(this.sql)
    if (again) return ok(viewOf(again, Date.now()))
    const now = Date.now()
    return this.create(cloudRecord(id, owner, machine, input, now), () => addMessage(this.sql, 1, input.message.id, input.message.text, "resuming", now))
  }

  async get(by: AutoCaller): Promise<AutoResult<AutoSessionView>> {
    const r = this.admitted(by, false)
    return r ? ok(viewOf(r, Date.now())) : NOT_FOUND
  }

  /** The chat once its version is past `after`, once it is closed, or at the deadline (at most MAX_WAIT_MS). No timer outlives its request. */
  async wait(owner: string, after: number, waitMs: number): Promise<AutoResult<AutoSessionView>> {
    const deadline = Date.now() + Math.max(0, Math.min(waitMs, MAX_WAIT_MS))
    for (;;) {
      const r = this.admitted({ kind: "owner", owner }, false)
      if (!r) return NOT_FOUND
      if (r.version > after || !r.auto || Date.now() >= deadline) return ok(viewOf(r, Date.now()))
      await new Promise<void>((resolve) => {
        const done = () => (clearTimeout(timer), this.waiters.delete(done), resolve())
        const timer = setTimeout(done, Math.max(0, deadline - Date.now()))
        this.waiters.add(done)
      })
    }
  }

  async lease(by: AutoCaller, input: RenewInput): Promise<AutoResult<{ readonly session: AutoSessionView; readonly role: LeaseRole; readonly leaseMs: number }>> {
    if (!this.admitted(by, true)) return NOT_FOUND
    const r = await this.apply((current, now) => renew(current, by, input, now))
    return r.ok ? ok({ session: r.value.session, role: r.value.out.role, leaseMs: LEASE_MS }) : r
  }

  async release(by: AutoCaller, holder: string, epoch: number): Promise<AutoResult<AutoSessionView>> {
    if (!this.admitted(by, true)) return NOT_FOUND
    const machine = await this.autoMachine(by.owner)
    const r = await this.apply((current, now) => release(current, by, holder, epoch, machine, now))
    return r.ok ? ok(r.value.session) : r
  }

  async ackAssignment(by: AutoCaller, holder: string, epoch: number): Promise<AutoResult<AutoSessionView>> {
    if (!this.admitted(by, true)) return NOT_FOUND
    const r = await this.apply((current, now) => ackAssignment(current, by, holder, epoch, now))
    return r.ok ? ok(r.value.session) : r
  }

  async keep(owner: string, keepInCloud: boolean): Promise<AutoResult<AutoSessionView>> {
    if (!this.admitted({ kind: "owner", owner }, true)) return NOT_FOUND
    const r = await this.apply((current) => keep(current, keepInCloud))
    return r.ok ? ok(r.value.session) : r
  }

  /** The owner set their Auto machine: a chat that was waiting for one, or was given to another that never picked it up, goes to it. */
  async machineSet(owner: string, machine: AutoMachine): Promise<void> {
    if (!this.admitted({ kind: "owner", owner }, true)) return
    await this.apply<null>((current) => {
      const next = machineSet(current, machine)
      return next ? { out: null, rec: next, loud: true } : { out: null }
    })
  }

  /** `POST events`: new events go on from the last stored one. A repeat of stored seqs changes nothing; a hole is refused with the last seq stored. */
  async appendEvents(by: AutoCaller, holder: string, epoch: number, events: ReadonlyArray<EventIn>): Promise<AutoResult<{ readonly lastSeq: number }>> {
    if (!this.admitted(by, true)) return NOT_FOUND
    const r = await this.apply<number>((current) => {
      const refused = fence(current, by, holder, epoch)
      if (refused) return refused
      const plan = planAppend(current.lastSeq, events)
      if ("gap" in plan) return { fail: "auto.seq_gap", message: `event ${plan.gap} does not follow ${current.lastSeq}`, extra: { lastSeq: current.lastSeq } }
      const last = plan.fresh.at(-1)
      if (!last) return { out: current.lastSeq }
      const bytes = plan.fresh.reduce((sum, e) => sum + e.record.length, 0)
      if (current.eventBytes + bytes > MAX_CHAT_BYTES) return TOO_LARGE
      appendEvents(this.sql, plan.fresh)
      return { out: last.seq, loud: true, rec: { ...current, lastSeq: last.seq, eventBytes: current.eventBytes + bytes } }
    })
    return r.ok ? ok({ lastSeq: r.value.out }) : r
  }

  async events(by: AutoCaller, after: number, limit: number): Promise<AutoResult<{ readonly events: ReadonlyArray<EventOut>; readonly lastSeq: number }>> {
    const r = this.admitted(by, false)
    return r ? ok({ events: readEvents(this.sql, after, limit), lastSeq: r.lastSeq }) : NOT_FOUND
  }

  /** `PUT chunks/:sha256`: the bytes are kept only under the name that is their SHA-256. A chunk already stored is accepted again as it is. */
  async putChunk(by: AutoCaller, holder: string, epoch: number, sha: string, bytes: ArrayBuffer): Promise<AutoResult<null>> {
    if (!this.admitted(by, true)) return NOT_FOUND
    const oversize = bytes.byteLength > MAX_CHUNK_BYTES
    const named = oversize || (await sha256Hex(bytes)) === sha
    const r = await this.apply<null>((current, now) => {
      const refused = fence(current, by, holder, epoch)
      if (refused) return refused
      if (oversize) return { fail: "auto.too_large", message: `a chunk is at most ${MAX_CHUNK_BYTES} bytes` }
      if (!named) return { fail: "auto.chunk_mismatch", message: "the bytes do not hash to the chunk's name" }
      if (hasChunk(this.sql, sha)) return { out: null }
      if (!roomForChunk(this.sql, bytes.byteLength, now)) return TOO_LARGE
      putChunk(this.sql, sha, bytes, now)
      return { out: null }
    })
    return r.ok ? ok(null) : r
  }

  async chunk(by: AutoCaller, sha: string): Promise<AutoResult<ArrayBuffer>> {
    if (!this.admitted(by, false)) return NOT_FOUND
    const bytes = getChunk(this.sql, sha)
    return bytes ? ok(bytes) : { ok: false, code: "not_found", message: "chunk not found" }
  }

  /**
   * `POST snapshot`: the manifest (its JSON text, and the `lastSeq` it names) becomes the chat's snapshot only when
   * every chunk it names is stored; the one before it and the chunks it does not name are dropped. It counts as
   * covering the chat only through the events that are stored: a manifest that names a later `lastSeq` than the
   * chat's must not let a machine's hand-back skip events the machine stores after it.
   */
  async putSnapshot(by: AutoCaller, holder: string, epoch: number, manifest: string, lastSeq: number): Promise<AutoResult<{ readonly snapshot: number }>> {
    if (!this.admitted(by, true)) return NOT_FOUND
    const names = chunkNames(JSON.parse(manifest))
    const r = await this.apply<number>((current, now) => {
      const refused = fence(current, by, holder, epoch)
      if (refused) return refused
      if (!names) return TOO_LARGE
      const { missing, bytes } = weighChunks(this.sql, names)
      if (missing.length > 0) return { fail: "auto.snapshot_incomplete", message: `${missing.length} of the manifest's chunks are not stored`, extra: { missing } }
      if (bytes > MAX_CHAT_BYTES) return TOO_LARGE
      const n = current.snapshot + 1
      acceptSnapshot(this.sql, n, manifest, names, now)
      return { out: n, loud: true, rec: { ...current, snapshot: n, snapshotSeq: Math.min(lastSeq, current.lastSeq) } }
    })
    return r.ok ? ok({ snapshot: r.value.out }) : r
  }

  async snapshot(by: AutoCaller): Promise<AutoResult<{ readonly snapshot: number; readonly manifest: string }>> {
    if (!this.admitted(by, false)) return NOT_FOUND
    const found = readSnapshot(this.sql)
    return found ? ok(found) : { ok: false, code: "auto.no_snapshot", message: "the chat has no snapshot" }
  }

  /** `POST inbox`: a message for the chat from any of the owner's devices. The same id again answers what the first answered. */
  async post(owner: string, message: { readonly id: string; readonly text: string }): Promise<AutoResult<{ readonly state: InboxState; readonly session: AutoSessionView }>> {
    if (!this.admitted({ kind: "owner", owner }, true)) return NOT_FOUND
    const machine = await this.autoMachine(owner)
    const r = await this.apply<InboxState>((current, now) => {
      if (!current.auto) return { fail: "auto.closed", message: "Auto is off for this chat" }
      const sent = sentState(this.sql, message.id)
      if (sent) return { out: sent }
      if (current.inbox - current.inboxAcked >= MAX_INBOX_PENDING) return { fail: "auto.too_large", message: "too many messages are waiting for this chat" }
      const { rec, state } = deliver({ ...current, inbox: current.inbox + 1 }, machine, now)
      addMessage(this.sql, rec.inbox, message.id, message.text, state, now)
      return { out: state, rec, loud: true }
    })
    return r.ok ? ok({ state: r.value.out, session: r.value.session }) : r
  }

  async inbox(by: AutoCaller, after: number): Promise<AutoResult<{ readonly messages: ReadonlyArray<InboxMessage> }>> {
    const r = this.admitted(by, false)
    return r ? ok({ messages: readInbox(this.sql, after, r.inboxAcked) }) : NOT_FOUND
  }

  async ackInbox(by: AutoCaller, holder: string, epoch: number, through: number): Promise<AutoResult<AutoSessionView>> {
    if (!this.admitted(by, true)) return NOT_FOUND
    const r = await this.apply<null>((current) => {
      const refused = fence(current, by, holder, epoch)
      if (refused) return refused
      const acked = Math.min(through, current.inbox)
      if (acked <= current.inboxAcked) return { out: null }
      ackInbox(this.sql, acked)
      return { out: null, loud: true, rec: { ...current, inboxAcked: acked } }
    })
    return r.ok ? ok(r.value.session) : r
  }
}
