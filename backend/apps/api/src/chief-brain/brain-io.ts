import type { OwnerFrame, Principal } from "@cmux/ownership"
import type { conversation } from "@cmux/home-core"
import type { Env } from "../env.ts"

/**
 * The Chief brain's only ways out: reads and ops on the ConversationDO and MuxDO of its chief, as
 * the chief itself (an agent principal built here, in server code; the Worker never takes one from
 * a request). Every reply goes through the normal `message.send`, so the reducer's rules (loop
 * guard, membership, thread rules) apply and every client sees it through the usual events.
 */
type Head = NonNullable<conversation.ConversationState>
type Message = conversation.Message

interface OwnerStub {
  submit(entity: string, principal: Principal, frame: { t: "op"; op: string; params: unknown; idempotency_key: string; origin: "script" }): Promise<{ frames: ReadonlyArray<OwnerFrame> }>
  readOp(entity: string, principal: Principal, op: string, params: unknown): Promise<{ ok: true; value: unknown } | { ok: false; code: string; message: string }>
}

/**
 * The grant a chief acts with: what a placed chief token holds (read, mutate-own, mutate-shared;
 * user-chief.ts chiefGrantClasses). This brain is the chief's placement in the cloud; the owner turned
 * it on, and every turn and post first checks the chief record is live and not placed on a server.
 */
const CHIEF_GRANT = ["read", "mutate-own", "mutate-shared"]

export const chiefPrincipal = (agent: string, owner: string): Principal => ({ identity: `agent:${agent}`, kind: "agent", agent, user: owner, grant_classes: CHIEF_GRANT })

const conv = (env: Env, id: string) => env.CONVERSATION_DO.get(env.CONVERSATION_DO.idFromName(id)) as unknown as OwnerStub & { agentFrame(entity: string, agent: string, f: { typing: boolean } | { run: unknown; steps: ReadonlyArray<unknown> }): Promise<void> }
const mux = (env: Env, agent: string) => env.MUX_DO.get(env.MUX_DO.idFromName(agent)) as unknown as OwnerStub

export interface ConversationView {
  readonly head: Head
  /** The newest messages, ascending by seq (at most `tail`). */
  readonly messages: ReadonlyArray<Message>
}

/** The head and the newest messages, as the chief sees them (members only, history floor applied). */
export const readConversation = async (env: Env, id: string, principal: Principal, tail = 50): Promise<ConversationView | { refused: string }> => {
  const r = await conv(env, id).readOp(id, principal, "conversation.snapshot", { tail })
  if (!r.ok) return { refused: r.code }
  const snap = r.value as { state: Head | null; rows?: { rows: ReadonlyArray<{ row: Message }> } }
  if (!snap.state) return { refused: "unknown_conversation" }
  return { head: snap.state, messages: (snap.rows?.rows ?? []).map((x) => x.row).sort((a, b) => a.seq - b.seq) }
}

export type SendOutcome = { readonly ok: true; readonly message: string | null; readonly seq?: number } | { readonly ok: false; readonly code: string; readonly message: string }

const outcome = (frames: ReadonlyArray<OwnerFrame>): SendOutcome => {
  const f = frames.find((x) => x.t === "result" || x.t === "reject")
  if (!f) return { ok: false, code: "owner.unreachable", message: "no reply from the owner" }
  if (f.t === "reject") return { ok: false, code: f.code, message: f.message }
  const value = (f as { value?: { message_id?: string; seq?: number } }).value
  return { ok: true, message: value?.message_id ?? null, ...(typeof value?.seq === "number" ? { seq: value.seq } : {}) }
}

export interface Reply {
  readonly conversation: string
  readonly text: string
  /** The run reference: a `work` part naming the run (trajectory), shown under the reply. */
  readonly run: { readonly id: string; readonly host: string; readonly steps: number }
  readonly reply_to?: string
  readonly thread_root?: string
  /** Idempotency key and client message id: one per run and refused try (a retry after no answer reuses it, so it commits once). */
  readonly key: string
}

const preview = (steps: number) => `${steps} step${steps === 1 ? "" : "s"}`

export const postReply = async (env: Env, principal: Principal, r: Reply): Promise<SendOutcome> => {
  const params = {
    conversation: r.conversation,
    client_msg_id: r.key,
    parts: [
      { type: "text", text: r.text },
      { type: "work", session: r.run.id, host: r.run.host, status: "done", preview: preview(r.run.steps) }
    ],
    ...(r.reply_to ? { reply_to: { message_id: r.reply_to, part_index: 0 } } : {}),
    ...(r.thread_root ? { thread_root: r.thread_root } : {})
  }
  const res = await conv(env, r.conversation).submit(r.conversation, principal, { t: "op", op: "message.send", params, idempotency_key: r.key, origin: "script" })
  return outcome(res.frames)
}

/**
 * A subagent's report as the chief: a text-less `work` card (session = the child run), so the loop
 * guard's turn budget and 2 s gap do not apply (home-core budget.ts); idempotent by `key`.
 */
export const postWork = async (env: Env, principal: Principal, w: { conversation: string; key: string; session: string; host: string; status: "done" | "failed"; preview: string; thread_root?: string }): Promise<SendOutcome> => {
  const params = { conversation: w.conversation, client_msg_id: w.key, parts: [{ type: "work", session: w.session, host: w.host, status: w.status, preview: w.preview }], ...(w.thread_root ? { thread_root: w.thread_root } : {}) }
  const res = await conv(env, w.conversation).submit(w.conversation, principal, { t: "op", op: "message.send", params, idempotency_key: w.key, origin: "script" })
  return outcome(res.frames)
}

/** One live frame (contract.ts LiveFrame) for every member's socket, outside a turn's model stream. Best effort. */
export const liveFrame = (env: Env, conversation: string, agent: string, frame: unknown): Promise<void> =>
  (conv(env, conversation) as unknown as { agentFrame(e: string, a: string, f: { live: unknown }): Promise<void> }).agentFrame(conversation, agent, { live: frame }).catch(() => undefined)

/** A plain text message as the chief (a notice: the out-of-credits line), idempotent by `key`. */
export const postText = async (env: Env, principal: Principal, conversation: string, text: string, key: string): Promise<SendOutcome> => {
  const res = await conv(env, conversation).submit(conversation, principal, { t: "op", op: "message.send", params: { conversation, client_msg_id: key, parts: [{ type: "text", text }] }, idempotency_key: key, origin: "script" })
  return outcome(res.frames)
}

/** Moves the chief's wake cursor in this conversation (MuxDO `mux.ack`). */
export const ackWake = async (env: Env, agent: string, principal: Principal, conversation: string, seq: number): Promise<SendOutcome> => {
  const res = await mux(env, agent).submit(agent, principal, { t: "op", op: "mux.ack", params: { agent, conversation, seq }, idempotency_key: `brain-ack:${conversation}:${seq}`, origin: "script" })
  return outcome(res.frames)
}

/** The ephemeral typing frame other members see while a turn runs (never stored). Best effort. */
export const typing = (env: Env, conversation: string, agent: string, on: boolean): Promise<void> => conv(env, conversation).agentFrame(conversation, agent, { typing: on }).catch(() => undefined)

/** A run change for every member's socket (`conversation-run-changed {conversation, run, steps}`), never stored there. Best effort. */
export const runChanged = (env: Env, conversation: string, agent: string, run: unknown, steps: ReadonlyArray<unknown>): Promise<void> =>
  conv(env, conversation).agentFrame(conversation, agent, { run, steps }).catch(() => undefined)

/** The owner (the chief's owner_user) and agent of a MuxDO, or null when the caller is not its owner. */
export const chiefOwnedBy = async (env: Env, agent: string, principal: Principal): Promise<{ owner: string } | null> => {
  const r = await mux(env, agent).readOp(agent, principal, "mux.queue", {})
  if (!r.ok) return null
  const head = r.value as { agent: string | null; owner_user: string | null }
  return head.agent === agent && head.owner_user !== null && head.owner_user === principal.user && principal.agent === undefined ? { owner: head.owner_user } : null
}

/** The chief's record as its owner's UserDO holds it (chief.list, as the owner), or null for an unknown or archived chief. */
type ChiefRecord = { display_name: string; brain_place: unknown } | null
const records = new Map<string, { at: number; record: ChiefRecord }>()
/** How long a turn admission may reuse a chief record it read: an archive or a placement stops new turns within this time. */
const RECORD_MS = 10_000
/**
 * chiefRecord, reused for RECORD_MS inside this object (the wake and the turn of one message both ask;
 * one UserDO round trip less on the wake path). A failed read is never reused.
 */
export const chiefRecordFresh = async (env: Env, owner: string, agent: string, now = Date.now()): Promise<ChiefRecord> => {
  const key = `${owner}/${agent}`
  const hit = records.get(key)
  if (hit && now - hit.at < RECORD_MS) return hit.record
  const record = await chiefRecord(env, owner, agent)
  records.set(key, { at: now, record })
  if (records.size > 64) records.delete(records.keys().next().value!)
  return record
}

export const chiefRecord = async (env: Env, owner: string, agent: string): Promise<ChiefRecord> => {
  const stub = env.USER_DO.get(env.USER_DO.idFromName(owner)) as unknown as OwnerStub
  const r = await stub.readOp(owner, { identity: `session:${owner}`, kind: "session", user: owner }, "chief.list", {})
  if (!r.ok) return null
  const chiefs = (r.value as { chiefs?: Array<{ id: string; display_name: string; archived_at: string | null; brain_place?: unknown }> }).chiefs ?? []
  const c = chiefs.find((x) => x.id === agent && x.archived_at === null)
  return c ? { display_name: c.display_name, brain_place: c.brain_place ?? null } : null
}
