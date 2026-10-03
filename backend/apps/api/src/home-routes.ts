import { createHash, createHmac } from "node:crypto"
import { conversation as homeConversation, invites } from "@cmux/home-core"
import type { OpFrame, OwnerFrame, Principal } from "@cmux/ownership"
import type { Env } from "./env.ts"
import type { SubmitResult } from "./owner-do.ts"

/**
 * Worker side of the Home ops (home-messaging.md section 4.1). Clients name a conversation in
 * `conversation`; the Worker routes to that ConversationDO and strips the field. Ids, invite
 * secrets, token hashes and accept proofs are derived here, never sent by clients:
 *
 * - conversation.create: `conv_` + sha256(actor, idempotency key), so a retry reaches the same object.
 * - dm.open: the pair's deterministic id; an email or phone peer becomes an address participant
 *   (HMAC id with HOME_ADDRESS_KEY) and is invited in the same request.
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

/** A Home ConversationDO mutation from the public API; the principal is already resolved (grant classes). */
export const conversationMutate = async (env: Env, principal: Principal, frame: OpFrame): Promise<SubmitResult> => {
  const params = (frame.params ?? {}) as Record<string, unknown>
  const key = frame.idempotency_key
  switch (frame.op) {
    case "conversation.create": {
      const id = `conv_${digest26(`conv\u0000${actorOf(principal)}\u0000${key}`)}`
      return conversationStub(env, id).submit(id, await withOwnedAgents(env, principal), { ...frame, params: { ...params, id, kind: "group" } })
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
          const res = await conversationStub(env, main).submit(main, principal, { ...frame, params: { id: main, participants: [] } })
          const reply = resultOf(res)
          if (reply?.t !== "result") return reject(key, "chief_main_pending", "the chief's main conversation is being created; retry")
          return { frames: res.frames.map((f) => (f === reply ? { ...reply, value: { ...(reply.value as object), redirected: "chief_main" } } : f)) }
        }
      }
      if (typeof peer === "string") {
        const id = homeConversation.dmConversationId(me, peer)
        const participants = [self, { id: peer, kind: peer.startsWith("agent_") ? "agent" : "human", display_name: peer }]
        return conversationStub(env, id).submit(id, principal, { ...frame, params: { id, participants } })
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
      if (typeof conversation !== "string") return reject(key, "validation.invalid", `${frame.op} needs a conversation`)
      const who = frame.op === "participants.add" ? await withOwnedAgents(env, principal) : principal
      return conversationStub(env, conversation).submit(conversation, who, { ...frame, params: rest })
    }
  }
}

/** A Home ConversationDO read: routed by `conversation`, which is stripped. */
export const conversationRead = async (env: Env, principal: Principal, op: string, params: unknown) => {
  const { conversation, ...rest } = (params ?? {}) as { conversation?: unknown }
  if (typeof conversation !== "string") return { ok: false as const, code: "validation.invalid", message: `${op} needs a conversation` }
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
