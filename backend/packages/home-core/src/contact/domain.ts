import type { Domain, OutboxItem, Principal, Reject, ReduceResult } from "../conversation/engine-types.ts"
import { takeContactQuota, type ContactWindow } from "../invites/limits.ts"
import type { Suppression } from "../invites/policy.ts"

/**
 * ContactDO, one per address (home-messaging.md sections 3, 4.3 and 9): the
 * only copy of the raw address, its suppression, the per-recipient limits
 * and the delivery record. The provider call is an external effect done by
 * the adapter after `contact.deliver` commits (`send: true`), through
 * `deliverInvite`, and recorded with `contact.delivery.record`, which reports
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

export interface ContactHead {
  readonly contact: string | null
  readonly channel: "email" | "sms" | null
  readonly address: string | null
  readonly linked_user: string | null
  readonly suppression: { readonly reason: Suppression; readonly at: number } | null
  readonly window: ContactWindow
  /** Newest last; at most MAX_DELIVERIES. */
  readonly deliveries: ReadonlyArray<DeliveryRecord>
  /** True once a text went to this number (the STOP line goes only in the first). */
  readonly texted: boolean
}

export const MAX_DELIVERIES = 50
export const INITIAL_CONTACT_HEAD: ContactHead = { contact: null, channel: null, address: null, linked_user: null, suppression: null, window: { lastByInviter: {} }, deliveries: [], texted: false }

/** Later states win; terminal states never change. */
const RANK: Readonly<Record<DeliveryState, number>> = {
  sending: 1, indeterminate: 2, sent: 3, delivered: 4,
  failed: 9, bounced: 9, complained: 9, suppressed: 9, refused_env: 9, disabled: 9, repeat: 9, recipient_limited: 9
}
const SUPPRESSING: Partial<Record<DeliveryState, Suppression>> = { bounced: "bounced", complained: "complained" }
const REASONS = new Set<Suppression>(["opted_out", "bounced", "complained", "reported", "admin"])

type Params = Readonly<Record<string, unknown>>
const refuse = (code: string, message = code): ReduceResult<ContactHead> => ({ ok: false, code, message })
const str = (v: unknown, max = 256): v is string => typeof v === "string" && v.length > 0 && v.length <= max
const record = (head: ContactHead, r: DeliveryRecord): ReadonlyArray<DeliveryRecord> =>
  [...head.deliveries.filter((d) => d.invite !== r.invite), r].slice(-MAX_DELIVERIES)

/** Only a Stack-verified email proves ownership; an unverified claim never does. */
const isAddressOwner = (head: ContactHead, p: Principal) =>
  p.kind === "session" &&
  p.email_verified === true &&
  head.channel === "email" &&
  typeof p.email === "string" &&
  p.email.trim().toLowerCase() === head.address

export const contactDomain: Domain<ContactHead, Params> = {
  initial: () => INITIAL_CONTACT_HEAD,
  authorize: (head, op, _params, p): Reject | undefined => {
    if (op === "contact.unsuppress") return isAddressOwner(head, p) ? undefined : { code: "forbidden", message: "only the owner of this address may unsuppress it" }
    return p.kind === "system" ? undefined : { code: "forbidden", message: `${op} is a system op` }
  },
  reduce: (head, op, params, ctx) => {
    switch (op) {
      case "contact.ensure": {
        const { contact, channel, address } = params
        if (!str(contact) || !contact.startsWith("contact_") || (channel !== "email" && channel !== "sms") || !str(address)) return refuse("invalid_params")
        if (head.contact !== null) {
          if (head.contact !== contact || head.address !== address) return refuse("contact.mismatch", "this object holds another address")
          return { ok: true, state: head, value: summary(head), changed: false }
        }
        const next: ContactHead = { ...head, contact, channel, address }
        return { ok: true, state: next, value: summary(next) }
      }
      case "contact.deliver": {
        // The payload is ConversationDO's DeliveryIntent (conversation/fanout.ts), read as is.
        const { invite, conversation, invited_by: inviter, contact } = params
        if (head.contact === null) return refuse("contact.unknown")
        if (!str(invite) || !str(conversation) || !str(inviter)) return refuse("invalid_params")
        if (contact !== undefined && contact !== head.contact) return refuse("contact.mismatch", "the delivery names another contact")
        const prior = head.deliveries.find((d) => d.invite === invite)
        if (prior) return { ok: true, state: head, value: { send: false, state: prior.state, first_text: false }, changed: false }
        const base = { invite, conversation, inviter, provider_id: null, at: ctx.now }
        if (head.suppression) {
          const r: DeliveryRecord = { ...base, state: "suppressed" }
          return { ok: true, state: { ...head, deliveries: record(head, r) }, value: { send: false, state: r.state }, outbox: report(r) }
        }
        const quota = takeContactQuota(head.window, inviter, ctx.now)
        const state: DeliveryState = !quota.ok ? "recipient_limited" : quota.send ? "sending" : "repeat"
        const r: DeliveryRecord = { ...base, state }
        const window = quota.ok ? quota.window : head.window
        const first_text = head.channel === "sms" && !head.texted && state === "sending"
        const next = { ...head, window, deliveries: record(head, r), texted: head.texted || first_text }
        return { ok: true, state: next, value: { send: state === "sending", state, first_text }, ...(state === "sending" ? {} : { outbox: report(r) }) }
      }
      case "contact.delivery.record": {
        const { invite, state, provider_id } = params
        const prior = head.deliveries.find((d) => d.invite === invite)
        if (!prior) return refuse("contact.unknown_delivery")
        if (typeof state !== "string" || !(state in RANK) || (provider_id !== undefined && provider_id !== null && !str(provider_id))) return refuse("invalid_params")
        const s = state as DeliveryState
        if (RANK[s] <= RANK[prior.state] || RANK[prior.state] === 9) return { ok: true, state: head, value: prior, changed: false }
        const r: DeliveryRecord = { ...prior, state: s, provider_id: (provider_id as string | undefined) ?? prior.provider_id, at: ctx.now }
        const reason = SUPPRESSING[s]
        const suppression = head.suppression ?? (reason ? { reason, at: ctx.now } : null)
        return { ok: true, state: { ...head, suppression, deliveries: record(head, r) }, value: r, outbox: report(r) }
      }
      case "contact.suppress": {
        const { reason } = params
        if (!REASONS.has(reason as Suppression)) return refuse("invalid_params")
        if (head.suppression) return { ok: true, state: head, value: head.suppression, changed: false }
        const suppression = { reason: reason as Suppression, at: ctx.now }
        return { ok: true, state: { ...head, suppression }, value: suppression }
      }
      case "contact.unsuppress": {
        if (!head.suppression) return { ok: true, state: head, value: null, changed: false }
        // An operator's block is not the address owner's to lift.
        if (head.suppression.reason === "admin") return refuse("forbidden", "this address was blocked by cmux")
        return { ok: true, state: { ...head, suppression: null }, value: null }
      }
      case "contact.link": {
        const { user } = params
        if (!str(user, 128) || !user.startsWith("user_")) return refuse("invalid_params")
        if (head.linked_user === user) return { ok: true, state: head, value: summary(head), changed: false }
        const next = { ...head, linked_user: user }
        return { ok: true, state: next, value: summary(next) }
      }
      default:
        return refuse("invalid_params", `unknown op ${op}`)
    }
  }
}

/** What the Worker learns; it must answer the inviter the same way whether or not `suppressed`. */
const summary = (h: ContactHead) => ({ contact: h.contact, channel: h.channel, linked_user: h.linked_user, suppressed: h.suppression !== null })

/**
 * The conversation knows fewer states than ContactDO: in-flight states are not
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
