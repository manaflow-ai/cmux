import { createHmac } from "node:crypto"
import { describe, expect, it } from "vitest"
import {
  acceptUrlPattern,
  deliverInvite,
  inviteLink,
  parseAllowlist,
  renderEmail,
  renderSms,
  resendWebhookEffects,
  sendblueWebhookEffects,
  verifyResendWebhook,
  verifySendblueWebhook,
  type CopyInput,
  type Fetch,
  type SenderDeps
} from "../src/invites/index.ts"

const LINK = inviteLink("staging", "conv_01JB8Q3Z5X7Y9K2M4N6P8R0T2V", "0123456789ABCDEFGHJKMNPQRS")
const base: CopyInput = {
  variant: "A",
  locale: "en",
  inviterName: "Lawrence",
  inviterEmail: "lawrence@example.com",
  trustedInviter: true,
  kind: "dm",
  preview: "want to try my agents?",
  link: LINK,
  unsubscribeLink: "https://cmux.com/u/abc",
  reportLink: "https://cmux.com/r/abc"
}

describe("copy", () => {
  it("variant A quotes the inviter's words", () => {
    const sms = renderSms(base)
    expect(sms).toEqual({ channel: "sms", variant: "A", body: `Lawrence sent you a message on cmux: "want to try my agents?"\n${LINK}` })
    const email = renderEmail(base)
    expect(email.subject).toBe("Lawrence: want to try my agents?")
    expect(email.text).toContain(`"want to try my agents?"`)
    expect(email.headers["List-Unsubscribe-Post"]).toBe("List-Unsubscribe=One-Click")
  })

  it("falls back to B for untrusted inviters and empty previews", () => {
    expect(renderSms({ ...base, trustedInviter: false }).variant).toBe("B")
    expect(renderSms({ ...base, preview: "   " }).variant).toBe("B")
    expect(renderEmail({ ...base, trustedInviter: false }).text).not.toContain("want to try")
  })

  it("removes links and control characters from user text and escapes HTML", () => {
    const sms = renderSms({ ...base, preview: "free money at https://evil.example.com/x and scam.com‮ now", inviterName: "<b>Eve</b> visit win.xyz" })
    expect(sms.body).not.toMatch(/evil|scam\.com|win\.xyz|‮/)
    expect(sms.body).toContain("(link removed)")
    const email = renderEmail({ ...base, inviterName: "<script>x</script>" })
    expect(email.html).not.toContain("<script>")
    expect(email.html).toContain("&lt;script&gt;")
  })

  it("omits footer links and unsubscribe headers when the routes do not exist", () => {
    const email = renderEmail({ ...base, unsubscribeLink: null, reportLink: null })
    expect(email.headers).toEqual({})
    expect(email.text).not.toContain("Stop all invites")
    expect(email.html).not.toContain("Report spam")
    expect(email.text.split("\n")).toContain(LINK)
  })

  it("adds the opt-out line to the first text only", () => {
    expect(renderSms({ ...base, firstSmsToNumber: true }).body).toBe(`Lawrence sent you a message on cmux: "want to try my agents?"\nReply STOP to opt out.\n${LINK}`)
    expect(renderSms(base).body).not.toContain("STOP")
  })

  it("hides group titles from untrusted inviters", () => {
    expect(renderSms({ ...base, variant: "B", kind: "group", title: "Launch", trustedInviter: false }).body).toContain(`"a group"`)
    expect(renderSms({ ...base, variant: "B", kind: "group", title: "Launch" }).body).toContain(`"Launch"`)
  })

  it("ends every text with the environment's absolute accept URL on its own line", () => {
    for (const environment of ["staging", "production"] as const) {
      const link = inviteLink(environment, "conv_dm_01JB8Q3Z5X7Y9K2M4N6P8R0T2V", "0123456789ABCDEFGHJKMNPQRS")
      for (const locale of ["en", "ja"] as const)
        for (const variant of ["A", "B", "C"] as const)
          for (const kind of ["dm", "group"] as const)
            for (const firstSmsToNumber of [true, false]) {
              const body = renderSms({ ...base, link, locale, variant, kind, firstSmsToNumber, title: "Launch" }).body
              const lines = body.split("\n")
              const last = lines[lines.length - 1]!
              expect(last).toMatch(acceptUrlPattern(environment))
              expect(new URL(last).protocol).toBe("https:")
              expect(lines.slice(0, -1).join("\n")).not.toContain("https://")
            }
      const email = renderEmail({ ...base, link })
      expect(email.text.split("\n")).toContain(link)
      expect(email.html).toContain(`href="${link}"`)
    }
    expect(() => renderSms({ ...base, link: "cmux.com/i/x" })).toThrow()
    expect(() => renderSms({ ...base, link: "http://console-staging.cmux.dev/i/x" })).toThrow()
  })

  it("fills every placeholder in every variant, locale and kind", () => {
    for (const locale of ["en", "ja"] as const)
      for (const variant of ["A", "B", "C"] as const)
        for (const kind of ["dm", "group"] as const) {
          const input = { ...base, locale, variant, kind, title: "Launch" }
          const sms = renderSms(input)
          const email = renderEmail(input)
          for (const text of [sms.body, email.subject, email.text, email.html]) expect(text).not.toMatch(/\{\w+\}/)
          expect(sms.body).toContain(LINK)
          // One link plus at most about two SMS segments of text.
          expect(sms.body.length).toBeLessThanOrEqual(240)
        }
  })
})

const allowlist = parseAllowlist("email allowed@example.com\nphone +1 415 555 0100")
const recorder = (status = 200, body: unknown = { id: "re_123", message_handle: "sb_123", status: "QUEUED" }) => {
  const calls: Array<{ url: string; headers: Record<string, string>; body: Record<string, unknown> }> = []
  const fetch: Fetch = async (url, init) => {
    calls.push({ url, headers: init.headers, body: JSON.parse(init.body) as Record<string, unknown> })
    return { status, json: async () => body }
  }
  return { calls, fetch }
}
const deps = (fetch: Fetch, environment: "staging" | "production" = "staging"): SenderDeps => ({
  policy: { environment, allowlist },
  fetch,
  resend: { apiKey: "re_test", from: "cmux <invites@example.com>" },
  sendblue: { apiKeyId: "kid", apiSecret: "ksecret", fromNumber: "+14155550199" }
})
const email = renderEmail(base)
const sms = renderSms(base)

describe("sender", () => {
  it("staging refuses a recipient outside the allow list before any provider call", async () => {
    const { calls, fetch } = recorder()
    const r = await deliverInvite(deps(fetch), { inviteId: "inv_1", address: { channel: "email", value: "stranger@example.com" }, suppression: null, message: email })
    expect(r.state).toBe("refused_env")
    const s = await deliverInvite(deps(fetch), { inviteId: "inv_2", address: { channel: "sms", value: "+14155550111" }, suppression: null, message: sms })
    expect(s.state).toBe("refused_env")
    expect(calls).toHaveLength(0)
  })

  it("sends allow-listed email once with the invite id as idempotency key", async () => {
    const { calls, fetch } = recorder()
    const r = await deliverInvite(deps(fetch), { inviteId: "inv_1", address: { channel: "email", value: "allowed@example.com" }, suppression: null, message: email })
    expect(r).toMatchObject({ state: "sent", provider_id: "re_123", allowlist_index: 1 })
    expect(calls).toHaveLength(1)
    expect(calls[0]!.url).toBe("https://api.resend.com/emails")
    expect(calls[0]!.headers["Idempotency-Key"]).toBe("home-invite-inv_1")
    expect(calls[0]!.body.to).toEqual(["allowed@example.com"])
  })

  it("sends allow-listed SMS through SendBlue", async () => {
    const { calls, fetch } = recorder()
    const r = await deliverInvite(deps(fetch), { inviteId: "inv_3", address: { channel: "sms", value: "+14155550100" }, suppression: null, message: sms })
    expect(r).toMatchObject({ state: "sent", provider_id: "sb_123", allowlist_index: 2 })
    expect(calls[0]!.url).toBe("https://api.sendblue.com/api/send-message")
    expect(calls[0]!.headers["sb-api-key-id"]).toBe("kid")
    expect(calls[0]!.body).toMatchObject({ number: "+14155550100", from_number: "+14155550199" })
  })

  it("never sends to suppressed recipients, even in production", async () => {
    const { calls, fetch } = recorder()
    const r = await deliverInvite(deps(fetch, "production"), { inviteId: "inv_1", address: { channel: "email", value: "stranger@example.com" }, suppression: "complained", message: email })
    expect(r.state).toBe("suppressed")
    expect(calls).toHaveLength(0)
  })

  it("maps provider outcomes", async () => {
    const to = { channel: "email" as const, value: "allowed@example.com" }
    expect((await deliverInvite(deps(recorder(500).fetch), { inviteId: "i", address: to, suppression: null, message: email })).state).toBe("indeterminate")
    expect((await deliverInvite(deps(recorder(429).fetch), { inviteId: "i", address: to, suppression: null, message: email })).state).toBe("indeterminate")
    expect((await deliverInvite(deps(recorder(422, { name: "validation_error" }).fetch), { inviteId: "i", address: to, suppression: null, message: email })).state).toBe("failed")
    const thrown: Fetch = async () => {
      throw new TypeError("connection reset")
    }
    expect((await deliverInvite(deps(thrown), { inviteId: "i", address: to, suppression: null, message: email })).state).toBe("indeterminate")
    expect((await deliverInvite(deps(recorder().fetch), { inviteId: "i", address: to, suppression: null, message: sms })).state).toBe("failed")
    const declined = recorder(200, { status: "DECLINED", message_handle: "sb_9" })
    expect((await deliverInvite(deps(declined.fetch), { inviteId: "i", address: { channel: "sms", value: "+14155550100" }, suppression: null, message: sms })).state).toBe("failed")
  })
})

describe("webhooks", () => {
  const secret = `whsec_${Buffer.from("0123456789abcdef0123456789abcdef").toString("base64")}`
  const sign = (id: string, ts: string, body: string) =>
    `v1,${createHmac("sha256", Buffer.from("0123456789abcdef0123456789abcdef")).update(`${id}.${ts}.${body}`).digest("base64")}`

  it("verifies Resend (Svix) signatures with a 5 minute window", () => {
    const body = JSON.stringify({ type: "email.bounced" })
    const ts = "1790000000"
    const headers = { "svix-id": "msg_1", "svix-timestamp": ts, "svix-signature": `v1,bad ${sign("msg_1", ts, body)}` }
    expect(verifyResendWebhook(secret, headers, body, 1_790_000_000_000)).toBe(true)
    expect(verifyResendWebhook(secret, headers, `${body} `, 1_790_000_000_000)).toBe(false)
    expect(verifyResendWebhook(secret, headers, body, 1_790_000_400_000)).toBe(false)
  })

  it("maps Resend events to delivery and suppression", () => {
    expect(resendWebhookEffects({ type: "email.complained", data: { email_id: "re_1", to: ["a@example.com"] } })).toEqual([
      { kind: "delivery", provider_id: "re_1", state: "complained" },
      { kind: "suppress", address: "a@example.com", reason: "complained" }
    ])
    expect(resendWebhookEffects({ type: "email.opened", data: { email_id: "re_1" } })).toEqual([{ kind: "ignore" }])
  })

  it("checks the SendBlue secret and turns STOP into suppression", () => {
    expect(verifySendblueWebhook("s3cret", { "sb-signing-secret": "s3cret" })).toBe(true)
    expect(verifySendblueWebhook("s3cret", { "sb-signing-secret": "nope" })).toBe(false)
    expect(sendblueWebhookEffects({ is_outbound: false, content: " stop ", number: "+14155550100" })).toEqual([{ kind: "suppress", address: "+14155550100", reason: "opted_out" }])
    expect(sendblueWebhookEffects({ is_outbound: true, message_handle: "sb_1", status: "DELIVERED" })).toEqual([{ kind: "delivery", provider_id: "sb_1", state: "delivered" }])
  })
})
