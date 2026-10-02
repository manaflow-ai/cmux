import type { Domain, OutboxItem, Principal, Reject, ReduceResult } from "../conversation/engine-types.ts"
import { takeAddressQuota, type AddressWindow } from "../invites/limits.ts"
import type { Suppression } from "../invites/policy.ts"
import { confirmLink, EMPTY_LINK_STATE, noteInbound, requestLink, unlink, type LinkState } from "./text-link.ts"

/**
 * AddressDO, one per address (home-messaging.md sections 3, 4.3 and 9): the
 * only copy of the raw address, its suppression, the per-recipient limits
 * and the delivery record. The provider call is an external effect done by
 * the adapter after `address.deliver` commits (`send: true`), through
 * `deliverInvite`, and recorded with `address.delivery.record`, which reports
 * to the invite's ConversationDO. The state is small, so it is one JSON value.
 */
export type DeliveryState = "sending" | "sent" | "delivered" | "indeterminate" | "failed" | "bounced" | "complained" | "suppressed" | "refused_env" | "disabled" | "repeat" | "recipient_limited"

export interface DeliveryRecord {
  readonly invite: string
  readonly conversation: string
  readonly inviter: string
  readonly state: DeliveryState
  readonly provider_id: string | null
  readonly at: number
}

export interface AddressHead {
  readonly id: string | null
  readonly channel: "email" | "sms" | null
  readonly value: string | null
  readonly linked_user: string | null
  readonly suppression: { readonly reason: Suppression; readonly at: number } | null
  readonly window: AddressWindow
  /** Newest last; at most MAX_DELIVERIES. */
  readonly deliveries: ReadonlyArray<DeliveryRecord>
  /** True once a text went to this number (the STOP line goes only in the first). */
  readonly texted: boolean
  /** Texting Chief: the pending sign-in link and the binding (text-link.ts). Absent in old heads. */
  readonly link?: LinkState
}

export const MAX_DELIVERIES = 50
export const INITIAL_ADDRESS_HEAD: AddressHead = { id: null, channel: null, value: null, linked_user: null, suppression: null, window: { lastByInviter: {} }, deliveries: [], texted: false }

/** Later states win; terminal states never change. */
const RANK: Readonly<Record<DeliveryState, number>> = {
  sending: 1, indeterminate: 2, sent: 3, delivered: 4,
  failed: 9, bounced: 9, complained: 9, suppressed: 9, refused_env: 9, disabled: 9, repeat: 9, recipient_limited: 9
}
const SUPPRESSING: Partial<Record<DeliveryState, Suppression>> = { bounced: "bounced", complained: "complained" }
const REASONS = new Set<Suppression>(["opted_out", "bounced", "complained", "reported", "admin"])

type Params = Readonly<Record<string, unknown>>
const refuse = (code: string, message = code): ReduceResult<AddressHead> => ({ ok: false, code, message })
const str = (v: unknown, max = 256): v is string => typeof v === "string" && v.length > 0 && v.length <= max
const record = (head: AddressHead, r: DeliveryRecord): ReadonlyArray<DeliveryRecord> =>
  [...head.deliveries.filter((d) => d.invite !== r.invite), r].slice(-MAX_DELIVERIES)

/** Only a Stack-verified email proves ownership; an unverified claim never does. */
const isAddressOwner = (head: AddressHead, p: Principal) =>
  p.kind === "session" &&
  p.email_verified === true &&
  head.channel === "email" &&
  typeof p.email === "string" &&
  p.email.trim().toLowerCase() === head.value

export const addressDomain: Domain<AddressHead, Params> = {
  initial: () => INITIAL_ADDRESS_HEAD,
  authorize: (head, op, _params, p): Reject | undefined => {
    // The link is opened by a signed-in person; the domain checks it is the account that asked.
    if (op === "address.text_link.confirm") return p.kind === "session" && p.user ? undefined : { code: "forbidden", message: "sign in to link this phone" }
    if (op === "address.text_link.unlink" && (p.kind === "session" || p.kind === "install")) return undefined
    if (op === "address.unsuppress") return isAddressOwner(head, p) ? undefined : { code: "forbidden", message: "only the owner of this address may unsuppress it" }
    return p.kind === "system" ? undefined : { code: "forbidden", message: `${op} is a system op` }
  },
  reduce: (head, op, params, ctx) => {
    switch (op) {
      case "address.ensure": {
        const { id, channel, value } = params
        if (!str(id) || !id.startsWith("addr_") || (channel !== "email" && channel !== "sms") || !str(value)) return refuse("invalid_params")
        if (head.id !== null) {
          if (head.id !== id || head.value !== value) return refuse("address.mismatch", "this object holds another address")
          return { ok: true, state: head, value: summary(head), changed: false }
        }
        const next: AddressHead = { ...head, id, channel, value }
        return { ok: true, state: next, value: summary(next) }
      }
      case "address.deliver": {
        // The payload is ConversationDO's DeliveryIntent (conversation/fanout.ts), read as is.
        const { invite, conversation, invited_by: inviter, address } = params
        if (head.id === null) return refuse("address.unknown")
        if (!str(invite) || !str(conversation) || !str(inviter)) return refuse("invalid_params")
        if (address !== undefined && address !== head.id) return refuse("address.mismatch", "the delivery names another address")
        const prior = head.deliveries.find((d) => d.invite === invite)
        if (prior) return { ok: true, state: head, value: { send: false, state: prior.state, first_text: false }, changed: false }
        const base = { invite, conversation, inviter, provider_id: null, at: ctx.now }
        if (head.suppression) {
          const r: DeliveryRecord = { ...base, state: "suppressed" }
          return { ok: true, state: { ...head, deliveries: record(head, r) }, value: { send: false, state: r.state }, outbox: report(r) }
        }
        const quota = takeAddressQuota(head.window, inviter, ctx.now)
        const state: DeliveryState = !quota.ok ? "recipient_limited" : quota.send ? "sending" : "repeat"
        const r: DeliveryRecord = { ...base, state }
        const window = quota.ok ? quota.window : head.window
        const first_text = head.channel === "sms" && !head.texted && state === "sending"
        const next = { ...head, window, deliveries: record(head, r), texted: head.texted || first_text }
        return { ok: true, state: next, value: { send: state === "sending", state, first_text }, ...(state === "sending" ? {} : { outbox: report(r) }) }
      }
      case "address.delivery.record": {
        const { invite, state, provider_id } = params
        const prior = head.deliveries.find((d) => d.invite === invite)
        if (!prior) return refuse("address.unknown_delivery")
        if (typeof state !== "string" || !(state in RANK) || (provider_id !== undefined && provider_id !== null && !str(provider_id))) return refuse("invalid_params")
        const s = state as DeliveryState
        if (RANK[s] <= RANK[prior.state] || RANK[prior.state] === 9) return { ok: true, state: head, value: prior, changed: false }
        const r: DeliveryRecord = { ...prior, state: s, provider_id: (provider_id as string | undefined) ?? prior.provider_id, at: ctx.now }
        const reason = SUPPRESSING[s]
        const suppression = head.suppression ?? (reason ? { reason, at: ctx.now } : null)
        return { ok: true, state: { ...head, suppression, deliveries: record(head, r) }, value: r, outbox: report(r) }
      }
      case "address.suppress": {
        const { reason } = params
        if (!REASONS.has(reason as Suppression)) return refuse("invalid_params")
        if (head.suppression) return { ok: true, state: head, value: head.suppression, changed: false }
        const suppression = { reason: reason as Suppression, at: ctx.now }
        // An opt-out also ends texting Chief from this number; linking again needs a new link.
        const link = head.link ? { ...head.link, binding: null, pending: null } : head.link
        return { ok: true, state: { ...head, suppression, ...(link ? { link } : {}) }, value: suppression }
      }
      case "address.unsuppress": {
        if (!head.suppression) return { ok: true, state: head, value: null, changed: false }
        // An operator's block is not the address owner's to lift.
        if (head.suppression.reason === "admin") return refuse("forbidden", "this address was blocked by cmux")
        return { ok: true, state: { ...head, suppression: null }, value: null }
      }
      case "address.link": {
        const { user } = params
        if (!str(user, 128) || !user.startsWith("user_")) return refuse("invalid_params")
        if (head.linked_user === user) return { ok: true, state: head, value: summary(head), changed: false }
        const next = { ...head, linked_user: user }
        return { ok: true, state: next, value: summary(next) }
      }
      case "address.text_link.request": {
        // Built by the Worker from the requesting session; the user is the requester.
        const { user, code_hash } = params
        if (head.channel !== "sms") return refuse("invalid_params", "only phone numbers can be linked")
        if (!str(user, 128) || !user.startsWith("user_") || !str(code_hash, 64)) return refuse("invalid_params")
        if (head.suppression) return refuse("address.suppressed")
        const r = requestLink(head.link ?? EMPTY_LINK_STATE, user, code_hash, ctx.now)
        if (!r.ok) return refuse(r.code)
        return { ok: true, state: { ...head, link: r.state }, value: r.value }
      }
      case "address.text_link.confirm": {
        const { proof } = params
        if (!str(proof, 128)) return refuse("invalid_params")
        const user = ctx.principal.user!.startsWith("user_") ? ctx.principal.user! : `user_${ctx.principal.user}`
        const r = confirmLink(head.link ?? EMPTY_LINK_STATE, user, proof, ctx.now)
        // A failed confirm still commits (attempt count, burned link): the reject alone would lose it.
        if (!r.ok) return r.state ? { ok: true, state: { ...head, link: r.state }, value: { linked: false, code: r.code } } : refuse(r.code)
        return { ok: true, state: { ...head, link: r.state, linked_user: head.linked_user ?? user }, value: { linked: true, expires_at: r.value.expires_at } }
      }
      case "address.text_link.unlink": {
        const p = ctx.principal
        const user = p.kind === "system" ? null : p.user ? (p.user.startsWith("user_") ? p.user : `user_${p.user}`) : "?"
        const r = unlink(head.link ?? EMPTY_LINK_STATE, user)
        if (!r.ok) return refuse(r.code)
        if (r.state === (head.link ?? EMPTY_LINK_STATE)) return { ok: true, state: head, value: null, changed: false }
        return { ok: true, state: { ...head, link: r.state }, value: null }
      }
      case "address.inbound.note": {
        const link = head.link ?? EMPTY_LINK_STATE
        if (!link.binding) return { ok: true, state: head, value: null, changed: false }
        return { ok: true, state: { ...head, link: noteInbound(link, ctx.now) }, value: null }
      }
      default:
        return refuse("invalid_params", `unknown op ${op}`)
    }
  }
}

/** What the Worker learns; it must answer the inviter the same way whether or not `suppressed`. */
const summary = (h: AddressHead) => ({ id: h.id, channel: h.channel, linked_user: h.linked_user, suppressed: h.suppression !== null })

/**
 * The conversation knows fewer states than AddressDO: in-flight states are not
 * reported, and the reasons the inviter must not learn (repeat, recipient
 * limits, a disabled switch) collapse into states it already has.
 */
const REPORTED: Readonly<Partial<Record<DeliveryState, string>>> = {
  sent: "sent",
  delivered: "delivered",
  failed: "failed",
  bounced: "bounced",
  complained: "complained",
  suppressed: "suppressed",
  refused_env: "refused_env",
  disabled: "refused_env",
  repeat: "suppressed",
  recipient_limited: "suppressed"
}

/** The delivery report for the invite's conversation (forward-only there too); none for in-flight states. */
const report = (r: DeliveryRecord): ReadonlyArray<OutboxItem> => {
  const state = REPORTED[r.state]
  if (!state) return []
  return [
    {
      kind: "invite.delivery.report",
      entity: `delivery:${r.invite}:${state}`,
      payload: { invite_id: r.invite, delivery: { state, ...(r.provider_id ? { provider_id: r.provider_id } : {}) } },
      target: { class: "ConversationDO", name: r.conversation }
    }
  ]
}
