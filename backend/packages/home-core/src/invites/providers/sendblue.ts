import type { RenderedSms } from "../copy.ts"
import type { ProviderRequest } from "./resend.ts"

/**
 * SendBlue text messaging API (https://docs.sendblue.com). Auth headers
 * `sb-api-key-id` and `sb-api-secret-key`. SendBlue documents no
 * idempotency key, so a send whose outcome is unknown (network error, 5xx)
 * is never retried automatically: it is reported `indeterminate` and checked
 * by its message handle or by a person.
 */
export interface SendblueConfig {
  readonly apiKeyId: string
  readonly apiSecret: string
  /** E.164 number on the account. */
  readonly fromNumber: string
  readonly statusCallback?: string
  readonly baseUrl?: string
}

export const sendblueRequest = (config: SendblueConfig, to: string, sms: RenderedSms): ProviderRequest => ({
  url: `${(config.baseUrl ?? "https://api.sendblue.com").replace(/\/$/, "")}/api/send-message`,
  init: {
    method: "POST",
    headers: {
      "sb-api-key-id": config.apiKeyId,
      "sb-api-secret-key": config.apiSecret,
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      number: to,
      from_number: config.fromNumber,
      content: sms.body,
      ...(config.statusCallback ? { status_callback: config.statusCallback } : {})
    })
  }
})

export const sendblueMessageId = (body: unknown): string | null => {
  const handle = (body as { message_handle?: unknown } | null)?.message_handle
  return typeof handle === "string" && handle.length > 0 ? handle : null
}

/** SendBlue statuses that mean the message will not arrive. */
export const sendblueFailed = (body: unknown): boolean => {
  const status = (body as { status?: unknown } | null)?.status
  return status === "ERROR" || status === "DECLINED"
}
