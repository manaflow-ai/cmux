import { address as homeAddress, invites } from "@cmux/home-core"
import type { Env } from "./env.ts"
import { apiOrigin, CARD_PATH, sendblueConfig } from "./home-text.ts"

/**
 * The invite send adapter for AddressDO (stage C, home-messaging.md section 9). A delivery the
 * domain committed as `sending` is sent once: the stashed secret builds the accept link, the
 * inviter's first name comes from the conversation's invite preview, home-core renders the copy
 * and `deliverInvite` makes the single provider call. The result is recorded with
 * `address.delivery.record`, which reports to the ConversationDO.
 *
 * Fail-closed switches: HOME_INVITES_SEND must be exactly "on" (anything else, including unset,
 * is off); outside production only allow-listed recipients are reached, unless the invite's
 * inviter is on HOME_INVITE_ALLOWED_INVITERS (user id or verified email; decision 2026-10-05); a missing provider key
 * or sender is a failed delivery, never a retry loop. Text (SMS and iMessage) sends the contact
 * card first to a new number and the invite text after SendBlue reports the card (home-text.ts).
 *
 * Every attempt logs one line: time, channel, allow-list index, provider id and state; never the
 * address, the secret or the link.
 */
export interface SendTarget {
  readonly invite: string
  readonly conversation: string
  readonly channel: "email" | "sms"
  readonly value: string
  readonly secret: string | undefined
  /** Who made the invite (user id, verified email or null), recorded at invite.create. */
  readonly inviter?: { readonly user: string; readonly email: string | null } | undefined
  /** The address's suppression; a suppressed address is never sent to (deliverInvite checks it). */
  readonly suppression?: invites.Suppression | null
}

export interface SendOutcome {
  readonly state: homeAddress.DeliveryState
  readonly provider_id: string | null
}

interface PreviewStub {
  invitePreview(entity: string, secret: string): Promise<{ state: string; inviter?: string; kind?: "dm" | "group"; title?: string }>
}

export type Fetch = invites.Fetch

/** The production Worker (wrangler.jsonc env.production.name). */
export const PRODUCTION_WORKER = "cmux-api"

export const sendSwitchOn = (env: Env) => env.HOME_INVITES_SEND === "on"

/**
 * One invite step. `step` is "email", "text" (the invite text, with the invite card image) or
 * "card" (the cmux contact card, first contact with a number). Every step goes through
 * deliverInvite, so the switch, the allow list and suppression apply to each provider call.
 */
export const sendInvite = async (
  env: Env,
  target: SendTarget,
  fetcher: invites.Fetch = (url, init) => fetch(url, init as RequestInit),
  step: "email" | "text" | "card" = target.channel === "email" ? "email" : "text",
  firstText = false
): Promise<SendOutcome> => {
  const log = (state: string, extra: Record<string, unknown> = {}) =>
    console.log(JSON.stringify({ msg: "home invite send", at: new Date().toISOString(), env: env.ENVIRONMENT, invite: target.invite, channel: target.channel, step, state, ...extra }))
  if ((step === "email") !== (target.channel === "email")) {
    log("failed", { reason: "step does not match the channel" })
    return { state: "failed", provider_id: null }
  }
  if (!target.secret && step !== "card") {
    log("failed", { reason: "invite secret expired" })
    return { state: "failed", provider_id: null }
  }
  // Production behavior (no allow list) needs both the production environment and the production
  // Worker name from config; a mislabeled staging deploy still uses the allow list.
  const parsed = invites.parseEnvironment(env.ENVIRONMENT)
  const environment = parsed === "production" && env.WORKER_NAME !== PRODUCTION_WORKER ? "staging" : parsed
  let allowlist: invites.Allowlist
  try {
    allowlist = invites.allowlistFromEnv(env.HOME_INVITE_ALLOWLIST_EMAILS, env.HOME_INVITE_ALLOWLIST_PHONES)
  } catch {
    log("refused_env", { reason: "allow list does not parse" })
    return { state: "refused_env", provider_id: null }
  }
  // The team inviter rule, re-read at every send: a removed inviter's pending invites fall back to the allow list.
  let trustedInviter = false
  if (environment !== "production" && target.inviter) {
    try {
      trustedInviter = invites.isAllowedInviter(invites.allowedInvitersFromEnv(env.HOME_INVITE_ALLOWED_INVITERS), target.inviter)
    } catch {
      log("inviter_list_invalid", { reason: "HOME_INVITE_ALLOWED_INVITERS does not parse; the allow list applies" })
    }
  }
  const sendblue = sendblueConfig(env)
  const deps: invites.SenderDeps = {
    policy: { environment, sendSwitch: sendSwitchOn(env) ? "on" : "off", allowlist, trustedInviter },
    fetch: fetcher,
    ...(env.RESEND_API_KEY && env.HOME_INVITE_FROM ? { resend: { apiKey: env.RESEND_API_KEY, from: env.HOME_INVITE_FROM } } : {}),
    ...(sendblue ? { sendblue } : {})
  }
  const deliver = async (message: invites.RenderedEmail | invites.RenderedSms, inviteId: string) => {
    const result = await invites.deliverInvite(deps, { inviteId, address: { channel: target.channel, value: target.value }, suppression: target.suppression ?? null, message })
    log(result.state, { allowlist_index: result.allowlist_index ?? 0, inviter_rule: trustedInviter, provider_id: result.provider_id ?? null, http_status: result.http_status ?? null, reason: result.reason ?? null })
    return { state: result.state, provider_id: result.provider_id ?? null }
  }
  if (step === "card") {
    const origin = apiOrigin(env)
    if (!origin) {
      log("failed", { reason: "no public origin for the contact card" })
      return { state: "failed", provider_id: null }
    }
    return deliver({ channel: "sms", variant: "A", body: "", mediaUrl: `${origin}${CARD_PATH}` }, `${target.invite}:card`)
  }
  const stub = env.CONVERSATION_DO.get(env.CONVERSATION_DO.idFromName(target.conversation)) as unknown as PreviewStub
  const preview = await stub.invitePreview(target.conversation, target.secret!)
  if (preview.state !== "ok") {
    log("failed", { reason: `invite is ${preview.state}` })
    return { state: "failed", provider_id: null }
  }
  let link: string
  try {
    link = invites.inviteLink(env.ENVIRONMENT, target.conversation, target.secret!, env.HOME_INVITE_ORIGIN)
  } catch {
    log("failed", { reason: "no invite origin for this environment" })
    return { state: "failed", provider_id: null }
  }
  const copy = { variant: "A" as const, locale: "en" as const, inviterName: preview.inviter ?? "Someone", trustedInviter: false, kind: preview.kind ?? "dm", title: preview.title ?? null, link }
  if (step === "email") return deliver(invites.renderEmail(copy), target.invite)
  // The invite text carries the invite card image (inviteImageUrl) and the link on its last line.
  const sms = invites.renderSms({ ...copy, firstSmsToNumber: firstText })
  return deliver({ ...sms, mediaUrl: invites.inviteImageUrl(env.ENVIRONMENT, target.conversation, env.HOME_INVITE_ORIGIN) }, target.invite)
}
