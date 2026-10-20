import { address as homeAddress, conversation as homeConversation, invites } from "@cmux/home-core"
import type { OwnerFrame, Principal } from "@cmux/ownership"
import type { RequestPreview } from "./conversation-do.ts"
import type { Env } from "./env.ts"
import type { SubmitResult } from "./owner-do.ts"

/**
 * Message requests and email ownership (plans/cmux-next/home-messaging-invites/DESIGN.md):
 *
 * - A signed-in user's Stack-verified email is linked to its AddressDO (`linkVerifiedAddress`,
 *   after user.ensure), so dm.open by that email can reach the account (`linkedUserOf`).
 * - An invite to the address is a message request for the address's verified owner: listed by
 *   `home.requests.list`, accepted without the link by `invite.accept_verified`, hidden (and its
 *   sender blocked) by `request.dismiss`. Only the session whose verified email maps to the
 *   address sees or acts on them; anyone else gets an empty list or `unknown_invite`.
 */

const CONVERSATION_ID = /^conv_(dm_)?[0-9A-HJKMNP-TV-Z]{26}$/

interface AddressRequestStub {
  linkOwner(address: string, user: string, channel: "email" | "sms", value: string): Promise<void>
  linkedUser(address: string): Promise<string | null>
  requests(address: string): Promise<ReadonlyArray<homeAddress.AddressRequest>>
  dismissRequest(address: string, invite: string, block: boolean): Promise<{ ok: boolean; code?: string }>
}
interface ConversationRequestStub {
  requestPreview(entity: string, invite: string, addresses: ReadonlyArray<string>): Promise<RequestPreview | null>
  acceptVerified(entity: string, principal: Principal, idempotencyKey: string): Promise<SubmitResult>
}
interface UserDomainStub {
  homeVerifiedEmailDomain(entity: string): Promise<string | null>
  homeSameDomainReach(entity: string, senderDomain: string): Promise<{ display_name: string; allow_requests_from: homeConversation.AllowRequestsFrom } | null>
}

const addressStub = (env: Env, id: string) => env.ADDRESS_DO.get(env.ADDRESS_DO.idFromName(id)) as unknown as AddressRequestStub
const conversationStub = (env: Env, id: string) => env.CONVERSATION_DO.get(env.CONVERSATION_DO.idFromName(id)) as unknown as ConversationRequestStub
const userStub = (env: Env, id: string) => env.USER_DO.get(env.USER_DO.idFromName(id)) as unknown as UserDomainStub

const reject = (key: string, code: string, message: string): SubmitResult => ({
  frames: [{ t: "reject", tx: "", idempotency_key: key, code, message, retryable: false, replayed: false } as OwnerFrame]
})
const result = (key: string, value: unknown): SubmitResult => ({
  frames: [{ t: "result", tx: "", idempotency_key: key, value, revision: "0", replayed: false } as OwnerFrame]
})

/** The caller's verified email as an address and its id, or null (no key, no verified email, an agent). */
export const verifiedAddress = (env: Env, p: Principal): { id: string; address: invites.Address } | null => {
  if (p.kind !== "session" || p.agent || p.email_verified !== true || !p.email || !env.HOME_ADDRESS_KEY) return null
  const address = invites.normalizeEmail(p.email)
  return invites.isAddress(address) ? { id: invites.addressId(env.HOME_ADDRESS_KEY, address), address } : null
}

/** After user.ensure: the session's verified email now reaches this user (best effort; a failure leaves the old state). */
export const linkVerifiedAddress = async (env: Env, p: Principal): Promise<void> => {
  const mine = verifiedAddress(env, p)
  if (!mine || !p.user) return
  try {
    await addressStub(env, mine.id).linkOwner(mine.id, p.user, mine.address.channel, mine.address.value)
  } catch (e) {
    // Linking only improves reach; the sign-in must not fail on it. No address in the log.
    console.log(JSON.stringify({ msg: "home address link failed", at: new Date().toISOString(), reason: e instanceof Error ? e.name : "error" }))
  }
}

/**
 * DESIGN 2.4, trust same domain by default: adds the `same_domain` reach fact for `target` when
 * the caller's verified email and the target's share a company domain and the target trusts it.
 * Without it the principal is unchanged (the DM falls back to the invite, a message request).
 */
export const withSameDomainReach = async (env: Env, principal: Principal, target: string): Promise<Principal> => {
  if (principal.agent || principal.email_verified !== true) return principal
  const mine = invites.emailDomain(principal.email)
  if (!mine) return principal
  const fact = await userStub(env, target).homeSameDomainReach(target, mine).catch(() => null)
  if (!fact) return principal
  const others = (principal.home_reach ?? []).filter((r) => r.user !== target)
  const prior = (principal.home_reach ?? []).find((r) => r.user === target)
  const reach: homeConversation.HumanReach = prior
    ? { ...prior, same_domain: true }
    : { user: target, display_name: fact.display_name, shared_team: false, connected: false, same_domain: true, allow_requests_from: fact.allow_requests_from }
  return { ...principal, home_reach: [...others, reach] }
}

/** The account an address id is linked to, or null. */
export const linkedUserOf = (env: Env, address: string): Promise<string | null> => addressStub(env, address).linkedUser(address)

/** One row of `home.requests.list`. */
export interface HomeRequest extends Omit<RequestPreview, "inviter_user"> {
  readonly conversation: string
  /** Same verified company domain as the recipient (DESIGN 2.4): may notify and sit in the main list. */
  readonly trusted: boolean
}

/** `home.requests.list`: the caller's open message requests, newest first. */
export const listRequests = async (env: Env, p: Principal): Promise<{ ok: true; value: { requests: ReadonlyArray<HomeRequest> }; revision: string }> => {
  const mine = verifiedAddress(env, p)
  if (!mine) return { ok: true, value: { requests: [] }, revision: "0" }
  const open = await addressStub(env, mine.id).requests(mine.id)
  const recipientDomain = invites.emailDomain(mine.address.value)
  const rows = await Promise.all(
    open.map(async (r) => {
      const preview = await conversationStub(env, r.conversation).requestPreview(r.conversation, r.invite, [mine.id])
      if (!preview) return null
      const senderDomain = await userStub(env, preview.inviter_user).homeVerifiedEmailDomain(preview.inviter_user).catch(() => null)
      const { inviter_user: _sender, ...shown } = preview
      return { conversation: r.conversation, ...shown, trusted: invites.requestTrusted(senderDomain, recipientDomain) }
    })
  )
  // One row per conversation (a group can invite the same address twice over time).
  const seen = new Set<string>()
  const requests = rows.filter((r): r is HomeRequest => r !== null && !seen.has(r.conversation) && (seen.add(r.conversation), true))
  return { ok: true, value: { requests }, revision: "0" }
}

/** `invite.accept_verified {conversation}`: the request's recipient joins without the link. */
export const acceptRequest = async (env: Env, p: Principal, params: Record<string, unknown>, key: string): Promise<SubmitResult> => {
  const conversation = params.conversation
  if (typeof conversation !== "string" || !CONVERSATION_ID.test(conversation)) return reject(key, "validation.invalid", "invite.accept_verified needs a conversation id")
  if (!verifiedAddress(env, p)) return reject(key, "unknown_invite", "there is no invite for you here")
  return conversationStub(env, conversation).acceptVerified(conversation, p, key)
}

/** `request.dismiss {conversation, block?}`: hides the request from the recipient; silent to the sender. */
export const dismissRequest = async (env: Env, p: Principal, params: Record<string, unknown>, key: string): Promise<SubmitResult> => {
  const { conversation, block } = params
  if (typeof conversation !== "string" || !CONVERSATION_ID.test(conversation) || (block !== undefined && typeof block !== "boolean")) {
    return reject(key, "validation.invalid", "request.dismiss needs a conversation id and an optional block flag")
  }
  const mine = verifiedAddress(env, p)
  const request = mine ? (await addressStub(env, mine.id).requests(mine.id)).find((r) => r.conversation === conversation) : undefined
  if (!mine || !request) return reject(key, "unknown_invite", "there is no request for you here")
  const done = await addressStub(env, mine.id).dismissRequest(mine.id, request.invite, block === true)
  return done.ok ? result(key, { dismissed: true, blocked: block === true }) : reject(key, done.code ?? "unknown_invite", "the request could not be dismissed")
}
