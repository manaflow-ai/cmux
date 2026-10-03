import { address as homeAddress, invites } from "@cmux/home-core"
import type { Env } from "./env.ts"

/**
 * The invite send adapter for AddressDO (stage C, home-messaging.md section 9). A delivery the
 * domain committed as `sending` is sent once: the stashed secret builds the accept link, the
 * inviter's first name comes from the conversation's invite preview, home-core renders the copy
 * and `deliverInvite` makes the single provider call. The result is recorded with
 * `address.delivery.record`, which reports to the ConversationDO.
 *
 * Fail-closed switches: HOME_INVITES_SEND must be exactly "on" (anything else, including unset,
 * is off); outside production only allow-listed recipients are reached; a missing provider key
 * or sender is a failed delivery, never a retry loop. Text (SMS and iMessage) waits for the
 * SendBlue status webhook (vCard first) and is not sent by this slice.
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

export const sendInvite = async (env: Env, target: SendTarget, fetcher: invites.Fetch = (url, init) => fetch(url, init as RequestInit)): Promise<SendOutcome> => {
  const log = (state: string, extra: Record<string, unknown> = {}) =>
    console.log(JSON.stringify({ msg: "home invite send", at: new Date().toISOString(), env: env.ENVIRONMENT, invite: target.invite, channel: target.channel, state, ...extra }))
  if (target.channel !== "email") {
    log("disabled", { reason: "text sends wait for the vCard-first adapter" })
    return { state: "disabled", provider_id: null }
  }
  if (!target.secret) {
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
  const stub = env.CONVERSATION_DO.get(env.CONVERSATION_DO.idFromName(target.conversation)) as unknown as PreviewStub
  const preview = await stub.invitePreview(target.conversation, target.secret)
  if (preview.state !== "ok") {
    log("failed", { reason: `invite is ${preview.state}` })
    return { state: "failed", provider_id: null }
  }
  let link: string
  try {
    link = invites.inviteLink(env.ENVIRONMENT, target.conversation, target.secret, env.HOME_INVITE_ORIGIN)
  } catch {
    log("failed", { reason: "no invite origin for this environment" })
    return { state: "failed", provider_id: null }
  }
  const message = invites.renderEmail({ variant: "A", locale: "en", inviterName: preview.inviter ?? "Someone", trustedInviter: false, kind: preview.kind ?? "dm", title: preview.title ?? null, link })
  const result = await invites.deliverInvite(
    {
      policy: { environment, sendSwitch: sendSwitchOn(env) ? "on" : "off", allowlist },
      fetch: fetcher,
      ...(env.RESEND_API_KEY && env.HOME_INVITE_FROM ? { resend: { apiKey: env.RESEND_API_KEY, from: env.HOME_INVITE_FROM } } : {})
    },
    { inviteId: target.invite, address: { channel: "email", value: target.value }, suppression: null, message }
  )
  log(result.state, { allowlist_index: result.allowlist_index ?? 0, provider_id: result.provider_id ?? null, http_status: result.http_status ?? null, reason: result.reason ?? null })
  return { state: result.state, provider_id: result.provider_id ?? null }
}
