import { describe, expect, it } from "vitest"
import { inviteImageUrl, inviteLink, renderSms, sendblueRequest, textSendPlan } from "../src/invites/index.ts"

const conversation = "conv_dm_01JB8Q3Z5X7Y9K2M4N6P8R0T2V"
const link = inviteLink("staging", conversation, "0123456789ABCDEFGHJKMNPQRS")
const sms = renderSms({ variant: "A", locale: "en", inviterName: "Lawrence", trustedInviter: true, kind: "dm", preview: "hi", link, firstSmsToNumber: true })

describe("text send plan", () => {
  it("sends the contact card first, then the text with the invite card image, on first contact", () => {
    const plan = textSendPlan({ environment: "staging", conversation, firstText: true, cardUrl: "https://cdn.example.com/x_cmux.vcf", sms })
    expect(plan.map((s) => s.kind)).toEqual(["contact_card", "invite_text"])
    const text = plan[1]!
    expect(text.kind === "invite_text" && text.message.mediaUrl).toBe("https://console-staging.cmux.dev/og/invite/d01JB8Q3Z5X7Y9K2M4N6P8R0T2V.png")
    expect(text.kind === "invite_text" && text.message.body.split("\n").at(-1)).toBe(link)
  })

  it("skips the card on later invites and refuses a card URL that is not a hosted .vcf", () => {
    expect(textSendPlan({ environment: "production", conversation, firstText: false, cardUrl: "https://cdn.example.com/c.vcf", sms }).map((s) => s.kind)).toEqual(["invite_text"])
    expect(() => textSendPlan({ environment: "staging", conversation, firstText: true, cardUrl: "http://cdn.example.com/c.vcf", sms })).toThrow()
    expect(() => textSendPlan({ environment: "staging", conversation, firstText: true, cardUrl: "https://cdn.example.com/c.png", sms })).toThrow()
  })

  it("puts the image into the provider request as media_url", () => {
    const req = sendblueRequest({ apiKeyId: "k", apiSecret: "s", fromNumber: "+14155550199" }, "+14155550100", { ...sms, mediaUrl: inviteImageUrl("staging", conversation) })
    expect(JSON.parse(req.init.body)).toMatchObject({ media_url: "https://console-staging.cmux.dev/og/invite/d01JB8Q3Z5X7Y9K2M4N6P8R0T2V.png", content: sms.body })
    expect(() => inviteImageUrl(undefined, conversation)).toThrow()
  })
})
