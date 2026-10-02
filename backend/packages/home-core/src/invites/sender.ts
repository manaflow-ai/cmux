import type { RenderedEmail, RenderedSms } from "./copy.ts"
import type { Address } from "./normalize.ts"
import { decideSend, type SendPolicyInput, type Suppression } from "./policy.ts"
import { resendMessageId, resendRequest, type ProviderRequest, type ResendConfig } from "./providers/resend.ts"
import { sendblueFailed, sendblueMessageId, sendblueRequest, type SendblueConfig } from "./providers/sendblue.ts"

/**
 * The only path to a provider (ContactDO `contact.deliver`). Order: channel
 * check, environment policy and suppression (decideSend), then exactly one
 * provider call. Nothing here logs an address or a secret.
 */
export type Fetch = (url: string, init: ProviderRequest["init"]) => Promise<{ readonly status: number; json(): Promise<unknown> }>

export interface SenderDeps {
  readonly policy: SendPolicyInput
  readonly fetch: Fetch
  readonly resend?: ResendConfig
  readonly sendblue?: SendblueConfig
}

export interface DeliveryRequest {
  readonly inviteId: string
  readonly address: Address
  readonly suppression: Suppression | null
  readonly message: RenderedEmail | RenderedSms
}

export type DeliveryState = "sent" | "failed" | "indeterminate" | "refused_env" | "suppressed" | "disabled"

export interface DeliveryResult {
  readonly state: DeliveryState
  readonly channel: Address["channel"]
  readonly provider_id?: string
  /** 1-based allow-list position (0 when not on the list); safe to report. */
  readonly allowlist_index?: number
  readonly http_status?: number
  readonly reason?: string
}

export const deliverInvite = async (deps: SenderDeps, request: DeliveryRequest): Promise<DeliveryResult> => {
  const channel = request.address.channel
  if (request.message.channel !== channel) return { state: "failed", channel, reason: "message channel does not match the address" }
  const decision = decideSend(deps.policy, request.address, request.suppression)
  if (!decision.send) return { state: decision.state, channel, reason: decision.reason }
  let req: ProviderRequest
  let readId: (body: unknown) => string | null
  if (request.message.channel === "email") {
    if (!deps.resend) return { state: "failed", channel, reason: "email provider not configured" }
    req = resendRequest(deps.resend, request.address.value, request.message, `home-invite-${request.inviteId}`)
    readId = resendMessageId
  } else {
    if (!deps.sendblue) return { state: "failed", channel, reason: "sms provider not configured" }
    req = sendblueRequest(deps.sendblue, request.address.value, request.message)
    readId = sendblueMessageId
  }
  const base = { channel, allowlist_index: decision.allowlist_index }
  let status: number
  let body: unknown
  try {
    const response = await deps.fetch(req.url, req.init)
    status = response.status
    body = await response.json().catch(() => null)
  } catch (e) {
    return { ...base, state: "indeterminate", reason: `network: ${e instanceof Error ? e.name : "error"}` }
  }
  if (status >= 500 || status === 429) return { ...base, state: "indeterminate", http_status: status, reason: "provider unavailable" }
  if (status < 200 || status >= 300) return { ...base, state: "failed", http_status: status, reason: providerError(body) }
  if (channel === "sms" && sendblueFailed(body)) return { ...base, state: "failed", http_status: status, reason: providerError(body) }
  const id = readId(body)
  return id ? { ...base, state: "sent", http_status: status, provider_id: id } : { ...base, state: "indeterminate", http_status: status, reason: "no message id in the reply" }
}

/** A short provider error without echoing request data. */
const providerError = (body: unknown): string => {
  const b = body as { name?: unknown; message?: unknown; error_message?: unknown; error_code?: unknown } | null
  const parts = [b?.name, b?.error_code, b?.message ?? b?.error_message].filter((x) => typeof x === "string" || typeof x === "number")
  return parts.length ? parts.join(": ").slice(0, 200) : "provider refused"
}
