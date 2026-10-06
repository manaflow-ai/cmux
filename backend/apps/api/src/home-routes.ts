import { createHash, createHmac } from "node:crypto"
import { conversation as homeConversation, invites } from "@cmux/home-core"
import type { OpFrame, OwnerFrame, Principal } from "@cmux/ownership"
import type { Env } from "./env.ts"
import type { SubmitResult } from "./owner-do.ts"
import { humanTargets, isParticipant, resolveHumanReach } from "./home-reach.ts"
import { HOME_RATE_LIMITED, HOME_USER_NOT_READY, isHomeRateOp, takeHomeRate } from "./home-rate.ts"

/**
 * Worker side of the Home ops (home-messaging.md section 4.1). Clients name a conversation in
 * `conversation`; the Worker routes to that ConversationDO and strips the field. Ids, invite
 * secrets, token hashes and accept proofs are derived here, never sent by clients:
 *
 * - conversation.create: `conv_` + sha256(actor, idempotency key), so a retry reaches the same object.
 * - dm.open: the caller's existing DM with a user peer (inbox `peer` index), else the pair's
 *   deterministic id; an email or phone peer becomes an address participant (HMAC id with
 *   HOME_ADDRESS_KEY) and is invited in the same request.
 * - Ops that add humans carry the reach facts the Worker resolved (home-reach.ts). conversation.create
 *   and participants.add first take one attempt from the caller's hourly budget (home-rate.ts);
 *   a spent budget refuses before any reach RPC or member check.
 * - invite.create: invite id from (conversation, actor, key); the secret is an HMAC of the invite
 *   id with HOME_ADDRESS_KEY (retry-stable, unguessable without the key); token_hash is
 *   sha256(sha256(secret)). The secret goes only to the address's AddressDO stash.
 * - invite.accept: the link code names the conversation; proof = sha256(secret).
 */

const CODE = /^([dg])([0-9A-HJKMNP-TV-Z]{26})$/
const SECRET = /^[0-9A-HJKMNP-TV-Z]{26}$/
const CONVERSATION_ID = /^conv_(dm_)?[0-9A-HJKMNP-TV-Z]{26}$/
const STASH_TTL_MS = 24 * 3_600_000

export type HomeError = { readonly ok: false; readonly code: string; readonly message: string }

export interface ConversationStub {
  submit(entity: string, principal: Principal, frame: OpFrame): Promise<SubmitResult>
  readOp(entity: string, principal: Principal, op: string, params: unknown): Promise<unknown>
  acceptInvite(entity: string, principal: Principal, proof: string, idempotencyKey: string): Promise<SubmitResult>
  card(entity: string): Promise<{ first_name: string; avatar_url: null } | null>
  invitePreview(entity: string, secret: string): Promise<unknown>
  mayInvite(entity: string, principal: Principal): Promise<boolean>
  homeDecided(entity: string, principal: Principal, key: string): Promise<boolean>
}

interface AddressStub {
  stashSecret(address: string, invite: string, secret: string, expiresAt: number, channel?: "email" | "sms", value?: string): Promise<void>
}

export const conversationStub = (env: Env, id: string) => env.CONVERSATION_DO.get(env.CONVERSATION_DO.idFromName(id)) as unknown as ConversationStub
const addressStub = (env: Env, id: string) => env.ADDRESS_DO.get(env.ADDRESS_DO.idFromName(id)) as unknown as AddressStub

/** The conversation id a link code names, or null. */
export const conversationForCode = (code: string): string | null => {
  const m = CODE.exec(code)
  return m ? (m[1] === "d" ? `conv_dm_${m[2]}` : `conv_${m[2]}`) : null
}

const digest26 = (text: string) => invites.crockford(createHash("sha256").update(text).digest(), 26)
/** The id conversation.create gives a group: one per (actor, idempotency key). */
const createdId = (actor: string, key: string) => `conv_${digest26(`conv\u0000${actor}\u0000${key}`)}`
const actorOf = (p: Principal) => homeConversation.actorOf(p) ?? p.identity
const reject = (key: string, code: string, message: string): SubmitResult => ({
  frames: [{ t: "reject", tx: "", idempotency_key: key, code, message, retryable: false, replayed: false } as OwnerFrame]
})
const resultOf = (r: SubmitResult) => r.frames.find((f) => f.t === "result" || f.t === "reject")

const addressFor = (env: Env, input: { email?: string; phone?: string }): { id: string; address: invites.Address } | HomeError => {
  if (!env.HOME_ADDRESS_KEY) return { ok: false, code: "home.not_configured", message: "Home invites are not configured on this deployment" }
  const raw = input.email ?? input.phone
  const address = typeof raw === "string" ? (input.email !== undefined ? invites.normalizeEmail(raw) : invites.normalizePhone(raw)) : "address.invalid"
  if (!invites.isAddress(address)) return { ok: false, code: "invalid_invite", message: address }
  return { id: invites.addressId(env.HOME_ADDRESS_KEY, address), address }
}

/** invite.create with Worker-derived fields; the secret is stashed in the AddressDO before the commit. */
const createInvite = async (
  env: Env,
  principal: Principal,
  conversation: string,
  input: { address: { email?: string; phone?: string }; display_name: string; locale?: string; copy_variant?: string },
  frame: OpFrame
): Promise<SubmitResult> => {
  const resolved = addressFor(env, input.address)
  if ("ok" in resolved) return reject(frame.idempotency_key, resolved.code, resolved.message)
  const invite = `inv_${digest26(`invite\u0000${conversation}\u0000${actorOf(principal)}\u0000${frame.idempotency_key}`)}`
  const secret = invites.crockford(createHmac("sha256", env.HOME_ADDRESS_KEY!).update(`invite-secret\u0000${invite}`).digest(), invites.SECRET_CHARS)
  await addressStub(env, resolved.id).stashSecret(resolved.id, invite, secret, Date.now() + STASH_TTL_MS, resolved.address.channel, resolved.address.value)
  const params = {
    invite_id: invite,
    address: resolved.id,
    channel: resolved.address.channel,
    display_name: input.display_name,
    token_hash: invites.hashInviteSecret(invites.hashInviteSecret(secret)),
    locale: input.locale ?? "en",
    copy_variant: input.copy_variant ?? "A"
  }
  return conversationStub(env, conversation).submit(conversation, principal, { ...frame, op: "invite.create", params })
}

/**
 * The caller's chiefs from UserDO, for ops that add agent participants: ConversationDO's reach
 * policy admits an agent only when it is one of these (conversation-do.ts ownerRecordPolicy).
 */
const withOwnedAgents = async (env: Env, principal: Principal): Promise<Principal> => {
  if (!principal.user || principal.agent) return principal
  const stub = env.USER_DO.get(env.USER_DO.idFromName(principal.user)) as unknown as { readOp(e: string, p: Principal, op: string, params: unknown): Promise<{ ok: boolean; value?: { chiefs?: Array<{ id: string; display_name: string }> } }> }
  const r = await stub.readOp(principal.user, principal, "chief.list", {})
  const chiefs = r.ok ? (r.value?.chiefs ?? []) : []
  return { ...principal, owned_agents: chiefs.map((c) => ({ id: c.id, display_name: c.display_name })) }
}

/** The main conversation of one of the caller's chiefs, or null. */
const ownChiefMain = async (env: Env, principal: Principal, agent: string): Promise<string | null> => {
  if (!principal.user || principal.agent) return null
  const stub = env.USER_DO.get(env.USER_DO.idFromName(principal.user)) as unknown as { readOp(e: string, p: Principal, op: string, params: unknown): Promise<{ ok: boolean; value?: { chiefs?: Array<{ id: string; main_conversation: string | null }> } }> }
  const r = await stub.readOp(principal.user, principal, "chief.list", {})
  return (r.ok ? r.value?.chiefs ?? [] : []).find((c) => c.id === agent)?.main_conversation ?? null
}

/** The caller with the reach facts for the humans among `ids` (home-reach.ts). */
const withReach = async (env: Env, principal: Principal, ids: ReadonlyArray<unknown>) => (await resolveHumanReach(env, principal, humanTargets(actorOf(principal), ids))).principal

const participantIds = (list: unknown): Array<unknown> => (Array.isArray(list) ? list.map((p) => (typeof p === "object" && p !== null ? (p as { id?: unknown }).id : undefined)) : [])

/** The owner frame of a dm.open that creates the pair's DM (the caller and `peer`); the replay path rebuilds the same one. */
const dmCreateFrame = (principal: Principal, frame: OpFrame, peer: string): { id: string; frame: OpFrame } => {
  const me = actorOf(principal)
  const id = homeConversation.dmConversationId(me, peer)
  // No display names in the hashed params: the owner's policy takes the caller's name from the principal
  // and the peer's from its records, so a renamed caller's same-key retry still replays.
  return { id, frame: { ...frame, params: { id, participants: [{ id: me, kind: principal.agent ? "agent" : "human" }, { id: peer, kind: peer.startsWith("agent_") ? "agent" : "human" }] } } }
}
/** The owner frame of a dm.open that reopens an existing DM (no participants: it never creates one). */
const dmReopenFrame = (frame: OpFrame, id: string): OpFrame => ({ ...frame, params: { id, participants: [] } })

/**
 * The ConversationDO and the owner frame a rate-gated op becomes (the same mapping the op's case
 * below submits), or null: conversation.create (a group per actor and key), dm.open with a user
 * peer (the pair's DM), participants.add (its conversation, which the frame leaves out).
 */
const ownerTarget = (principal: Principal, frame: OpFrame): { id: string; frame: OpFrame } | null => {
  const params = (frame.params ?? {}) as Record<string, unknown>
  const me = actorOf(principal)
  if (frame.op === "conversation.create") {
    const id = createdId(me, String(frame.idempotency_key))
    return { id, frame: { ...frame, params: { ...params, id, kind: "group" } } }
  }
  if (frame.op === "dm.open" && typeof params.peer === "string" && params.peer.startsWith("user_")) return dmCreateFrame(principal, frame, params.peer)
  const { conversation, ...rest } = params
  return typeof conversation === "string" && CONVERSATION_ID.test(conversation) ? { id: conversation, frame: { ...frame, params: rest } } : null
}

/**
 * A rate-gated op whose key is already decided in its target conversation: the ledger answers it
 * (its stored result, or idempotency.conflict for other params) from identity and key alone, so it
 * goes straight to submit with the plain principal, with no charge and no reach RPC. Asked before
 * the budget (one RPC to the target conversation). A dm.open whose existing DM has another id
 * (from an accepted invite) is not found here.
 */
const replayDecided = async (env: Env, principal: Principal, frame: OpFrame): Promise<SubmitResult | null> => {
  const target = ownerTarget(principal, frame)
  if (!target || typeof frame.idempotency_key !== "string") return null
  const stub = conversationStub(env, target.id)
  if (!(await stub.homeDecided(target.id, principal, frame.idempotency_key))) return null
  const res = await stub.submit(target.id, principal, target.frame)
  // A dm.open key decided on the pair's DM may have been a reopen (no participants): its params differ, so try that shape once.
  const conflict = res.frames.some((f) => f.t === "reject" && (f as { code?: string }).code === "idempotency.conflict")
  return frame.op === "dm.open" && conflict ? stub.submit(target.id, principal, dmReopenFrame(frame, target.id)) : res
}

/**
 * dm.open with a user peer after a budget refusal: the caller's existing DM with that peer (inbox
 * `peer` index, one RPC to the caller's own UserDO) still opens, with no charge and no reach; the
 * owner answers an existing id with its summary and writes nothing. Null when there is none.
 */
const reopenDm = async (env: Env, principal: Principal, frame: OpFrame): Promise<SubmitResult | null> => {
  const peer = (frame.params as { peer?: unknown } | undefined)?.peer
  // A chief never reopens through its owner's inbox (as resolveHumanReach): forbidden vs home.rate_limited would tell it whether the owner has that DM.
  if (frame.op !== "dm.open" || typeof peer !== "string" || !peer.startsWith("user_") || !principal.user || principal.agent) return null
  const inbox = env.USER_DO.get(env.USER_DO.idFromName(principal.user)) as unknown as { readInbox(e: string, p: Principal, op: string, params: unknown): Promise<{ ok: boolean; value?: { conversation?: string | null } }> }
  const found = await inbox.readInbox(principal.user, principal, "inbox.dm_peer", { peer })
  const id = found.ok ? found.value?.conversation : null
  return id ? conversationStub(env, id).submit(id, principal, dmReopenFrame(frame, id)) : null
}

/** A Home ConversationDO mutation from the public API; the principal is already resolved (grant classes). */
export const conversationMutate = async (env: Env, principal: Principal, frame: OpFrame): Promise<SubmitResult> => {
  const params = (frame.params ?? {}) as Record<string, unknown>
  const key = frame.idempotency_key
  // dm.open with a user peer may create a conversation and resolves reach: it spends the conversation.create budget.
  const rateOp = isHomeRateOp(frame.op) ? frame.op : frame.op === "dm.open" && typeof params.peer === "string" && !params.peer.startsWith("agent_") ? "conversation.create" : null
  if (rateOp) {
    // A decided key replays first: no unit, no reach, and the exact frame the first call sent.
    const replayed = await replayDecided(env, principal, frame)
    if (replayed) return replayed
    const gate = await takeHomeRate(env, principal, actorOf(principal), rateOp)
    if (!gate.ok && "not_ready" in gate) return reject(key, HOME_USER_NOT_READY, "call user.ensure once before Home conversation ops")
    if (!gate.ok) {
      const reopened = await reopenDm(env, principal, frame)
      if (reopened) return reopened
      const message = `too many ${frame.op} requests; retry in ${Math.ceil(gate.retry_after_ms / 1000)} s`
      return { frames: [{ t: "reject", tx: "", idempotency_key: key, code: HOME_RATE_LIMITED, message, retryable: true, replayed: false, details: { retry_after_ms: gate.retry_after_ms } } as OwnerFrame] }
    }
  }
  switch (frame.op) {
    case "conversation.create": {
      const target = ownerTarget(principal, frame)!
      const who = await withReach(env, await withOwnedAgents(env, principal), participantIds(params.participants))
      return conversationStub(env, target.id).submit(target.id, who, target.frame)
    }
    case "dm.open": {
      const me = actorOf(principal)
      const self = { id: me, kind: principal.agent ? "agent" : "human", display_name: principal.display_name ?? "Someone" }
      const peer = params.peer
      // A DM with your own chief is that chief's main conversation (one place per chief).
      if (typeof peer === "string" && peer.startsWith("agent_")) {
        const main = await ownChiefMain(env, principal, peer)
        if (main) {
          // dm.open on an existing conversation id answers its full summary (no write). With no
          // participants it can never create one: a main conversation still in the outbox is a retryable reject.
          const res = await conversationStub(env, main).submit(main, principal, dmReopenFrame(frame, main))
          const reply = resultOf(res)
          if (reply?.t !== "result") return reject(key, "chief_main_pending", "the chief's main conversation is being created; retry")
          return { frames: res.frames.map((f) => (f === reply ? { ...reply, value: { ...(reply.value as object), redirected: "chief_main" } } : f)) }
        }
      }
      if (typeof peer === "string") {
        const reach = await resolveHumanReach(env, principal, humanTargets(me, [peer]))
        // An existing DM with this user (also one whose id came from an accepted invite, section 17 Q2) answers as is.
        const existing = reach.dms.get(peer)
        if (existing) return conversationStub(env, existing).submit(existing, principal, dmReopenFrame(frame, existing))
        const created = dmCreateFrame(principal, frame, peer)
        return conversationStub(env, created.id).submit(created.id, reach.principal, created.frame)
      }
      const resolved = addressFor(env, (peer ?? {}) as { email?: string; phone?: string })
      if ("ok" in resolved) return reject(key, resolved.code, resolved.message)
      const id = homeConversation.dmConversationId(me, resolved.id)
      const shown = invites.maskAddress(resolved.address)
      const opened = await conversationStub(env, id).submit(id, principal, { ...frame, params: { id, participants: [self, { id: resolved.id, kind: "address", display_name: shown }] } })
      const reply = resultOf(opened)
      if (reply?.t !== "result") return opened
      // An address peer is invited in the same request; an open invite to it already is not an error.
      const invited = resultOf(await createInvite(env, principal, id, { address: peer as { email?: string; phone?: string }, display_name: shown }, { ...frame, idempotency_key: `${key}:invite` }))
      const invite = invited?.t === "result" ? { ok: true } : { ok: false, code: invited?.t === "reject" ? invited.code : "owner.unreachable" }
      return { frames: opened.frames.map((f) => (f === reply ? { ...reply, value: { ...(reply.value as object), invite } } : f)) }
    }
    case "invite.create": {
      const { conversation, ...rest } = params as { conversation: string } & Parameters<typeof createInvite>[3]
      if (typeof conversation !== "string" || !CONVERSATION_ID.test(conversation)) return reject(key, "validation.invalid", "invite.create needs a conversation id")
      // Before any AddressDO is touched: only a participant of an existing conversation invites.
      if (!(await conversationStub(env, conversation).mayInvite(conversation, principal))) return reject(key, "forbidden", "not a participant of this conversation")
      return createInvite(env, principal, conversation, rest, frame)
    }
    case "conversation.import": {
      // First call: the id is derived from the signed-in user and the source (never a client field).
      const source = params.source as { host?: unknown; local_id?: unknown } | null | undefined
      if (source !== undefined) {
        if (!source || typeof source !== "object" || typeof source.host !== "string" || typeof source.local_id !== "string") return reject(key, "validation.invalid", "source needs host and local_id")
        const id = homeConversation.importConversationId(actorOf(principal), source.host, source.local_id)
        const res = await conversationStub(env, id).submit(id, await withOwnedAgents(env, principal), { ...frame, params: { ...params, id } })
        // The caller learns the derived id here; continuations and the commit name it.
        return { frames: res.frames.map((f) => (f.t === "result" ? { ...f, value: { ...(f.value as object), id } } : f)) }
      }
      if (typeof params.id !== "string" || !CONVERSATION_ID.test(params.id)) return reject(key, "validation.invalid", "a continuation names its id")
      return conversationStub(env, params.id).submit(params.id, principal, frame)
    }
    case "conversation.import.commit": {
      if (typeof params.id !== "string" || !CONVERSATION_ID.test(params.id)) return reject(key, "validation.invalid", "commit names its id")
      return conversationStub(env, params.id).submit(params.id, principal, frame)
    }
    case "invite.accept": {
      const id = conversationForCode(String(params.code ?? ""))
      const secret = String(params.secret ?? "")
      if (!id || !SECRET.test(secret)) return reject(key, "unknown_invite", "the invite link is not valid")
      return conversationStub(env, id).acceptInvite(id, principal, invites.hashInviteSecret(secret), key)
    }
    default: {
      const { conversation, ...rest } = params as { conversation?: unknown }
      if (typeof conversation !== "string" || !CONVERSATION_ID.test(conversation)) return reject(key, "validation.invalid", `${frame.op} needs a conversation id`)
      const added = (rest as { participant?: { id?: unknown } }).participant
      // Reach facts only for a current participant: anyone else is refused by the owner without
      // RPCs to other owners, and cannot probe a target's setting through any conversation id.
      const member = frame.op === "participants.add" && (await isParticipant(env, conversation, principal))
      const who = frame.op === "participants.add" ? (member ? await withReach(env, await withOwnedAgents(env, principal), [added?.id]) : await withOwnedAgents(env, principal)) : principal
      return conversationStub(env, conversation).submit(conversation, who, { ...frame, params: rest })
    }
  }
}

/** A Home ConversationDO read: routed by `conversation`, which is stripped. */
export const conversationRead = async (env: Env, principal: Principal, op: string, params: unknown) => {
  const { conversation, ...rest } = (params ?? {}) as { conversation?: unknown }
  if (typeof conversation !== "string" || !CONVERSATION_ID.test(conversation)) return { ok: false as const, code: "validation.invalid", message: `${op} needs a conversation id` }
  return conversationStub(env, conversation).readOp(conversation, principal, op, rest)
}

/** GET /v1/invites/card/<code>: the inviter's first name for the Open Graph card (open invites only). */
export const handleInviteCard = async (env: Env, code: string): Promise<Response> => {
  const id = conversationForCode(code)
  const card = id ? await conversationStub(env, id).card(id) : null
  if (!card) return Response.json({ error: "not found" }, { status: 404, headers: { "cache-control": "public, max-age=60" } })
  return Response.json(card, { headers: { "cache-control": "public, max-age=300" } })
}

/** POST /v1/invites/preview {code, secret}: who invited the holder of the link (no account needed). */
export const handleInvitePreview = async (request: Request, env: Env): Promise<Response> => {
  if (request.method !== "POST") return new Response("method not allowed", { status: 405 })
  const body = (await request.json().catch(() => null)) as { code?: unknown; secret?: unknown } | null
  const id = conversationForCode(String(body?.code ?? ""))
  const secret = String(body?.secret ?? "")
  const headers = { "cache-control": "private, no-store" }
  if (!id || !SECRET.test(secret)) return Response.json({ state: "invalid" }, { headers })
  return Response.json(await conversationStub(env, id).invitePreview(id, secret), { headers })
}
