import type { RenderedEmail } from "../copy.ts"

/**
 * Resend email API (https://resend.com/docs/api-reference/emails/send-email).
 * The invite id is the provider idempotency key, so a retried drain never
 * sends a second email (Resend keeps keys for 24 hours).
 */
export interface ResendConfig {
  readonly apiKey: string
  /** For example `cmux <invites@cmux.com>`; the domain must be verified in Resend. */
  readonly from: string
  readonly replyTo?: string
  readonly baseUrl?: string
}

export interface ProviderRequest {
  readonly url: string
  readonly init: { readonly method: "POST"; readonly headers: Record<string, string>; readonly body: string }
}

export const resendRequest = (config: ResendConfig, to: string, email: RenderedEmail, idempotencyKey: string): ProviderRequest => ({
  url: `${(config.baseUrl ?? "https://api.resend.com").replace(/\/$/, "")}/emails`,
  init: {
    method: "POST",
    headers: {
      Authorization: `Bearer ${config.apiKey}`,
      "Content-Type": "application/json",
      "Idempotency-Key": idempotencyKey
    },
    body: JSON.stringify({
      from: config.from,
      to: [to],
      subject: email.subject,
      html: email.html,
      text: email.text,
      headers: email.headers,
      ...(config.replyTo ? { reply_to: config.replyTo } : {}),
      tags: [
        { name: "kind", value: "home_invite" },
        { name: "variant", value: email.variant }
      ]
    })
  }
})

/** The provider message id from a 2xx body. */
export const resendMessageId = (body: unknown): string | null => {
  const id = (body as { id?: unknown } | null)?.id
  return typeof id === "string" && id.length > 0 ? id : null
}
