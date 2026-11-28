import type { RenderedSms } from "./copy.ts"
import { inviteImageUrl } from "./token.ts"

/**
 * The text-channel send plan for one invite (decision, 2026-10-02):
 * - first contact with a number (AddressDO `first_text`): 1. the cmux contact card (.vcf as
 *   media), 2. only after the card's status is SENT or DELIVERED, the invite text with the
 *   invite card image attached and the link alone on the last line;
 * - later invites to the same number: the text with the image, no card.
 * The adapter (AddressDO, backend lead) runs the steps in order and waits on the provider's
 * status callback between them; nothing here sends.
 */
export type SendStep =
  | { readonly kind: "contact_card"; readonly media_url: string; readonly wait_for: ReadonlyArray<"SENT" | "DELIVERED"> }
  | { readonly kind: "invite_text"; readonly message: RenderedSms }

export interface FirstContactInput {
  readonly environment: string | undefined
  readonly conversation: string
  readonly firstText: boolean
  /** Public https URL of the hosted cmux.vcf (ends in .vcf, no spaces). */
  readonly cardUrl: string
  readonly sms: RenderedSms
  readonly originOverride?: string
}

export const textSendPlan = (input: FirstContactInput): ReadonlyArray<SendStep> => {
  if (!/^https:\/\/\S+\.(vcf|vcard)$/.test(input.cardUrl)) throw new Error("card url must be https and end in .vcf")
  const text: SendStep = { kind: "invite_text", message: { ...input.sms, mediaUrl: inviteImageUrl(input.environment, input.conversation, input.originOverride) } }
  return input.firstText ? [{ kind: "contact_card", media_url: input.cardUrl, wait_for: ["SENT", "DELIVERED"] }, text] : [text]
}
