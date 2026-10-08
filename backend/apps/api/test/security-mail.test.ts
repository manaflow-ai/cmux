import { describe, expect, it } from "vitest"
import type { Env } from "../src/env.ts"
import { deliverSecurityMail } from "../src/security-mail.ts"

/** Security notices by email (H11: lowering the text confirmation level notifies the owner) through Resend. */
const item = (id: number, to: string | undefined = "owner@example.com") => ({
  id,
  op: "mail.security_notice",
  key: `mail:lowered:user_1:${id}`,
  params: { user: "user_1", template: "text_confirm_lowered", locale: "en", title: "Level lowered", body: "From Strict to Off", install: "inst_1", at: 1, ...(to ? { to } : {}) }
})
const env = (over: Partial<Env> = {}) => ({ RESEND_API_KEY: "re_test", HOME_INVITE_FROM: "cmux <security@cmux.test>", ...over }) as unknown as Env

describe("security notice email", () => {
  it("sends one Resend email per item to the verified address, idempotent by item key", async () => {
    const calls: Array<{ url: string; init: RequestInit }> = []
    const fetcher = (async (url: string, init: RequestInit) => {
      calls.push({ url, init })
      return new Response(JSON.stringify({ id: "msg_1" }), { status: 200 })
    }) as unknown as typeof fetch
    const r = await deliverSecurityMail(env(), [item(1)], fetcher)
    expect(r).toEqual({ done: [1], dead: [] })
    expect(calls[0]!.url).toBe("https://api.resend.com/emails")
    const headers = calls[0]!.init.headers as Record<string, string>
    expect(headers["Idempotency-Key"]).toBe("mail:lowered:user_1:1")
    const body = JSON.parse(String(calls[0]!.init.body))
    expect(body).toMatchObject({ to: ["owner@example.com"], subject: "Level lowered" })
    expect(body.text).toContain("From Strict to Off")
  })

  it("dead-letters at once when mail is not configured or there is no verified address", async () => {
    const never = (async () => { throw new Error("must not send") }) as unknown as typeof fetch
    expect(await deliverSecurityMail(env({ RESEND_API_KEY: undefined }), [item(1)], never)).toMatchObject({ done: [], dead: [1], reason: "mail.not_configured" })
    expect(await deliverSecurityMail(env(), [item(2, undefined)], never)).toMatchObject({ done: [], dead: [2] })
  })

  it("a refused request is dead; a rate limit or server error throws (counted, capped retries)", async () => {
    const status = (n: number) => (async () => new Response("{}", { status: n })) as unknown as typeof fetch
    expect(await deliverSecurityMail(env(), [item(1)], status(422))).toMatchObject({ done: [], dead: [1] })
    await expect(deliverSecurityMail(env(), [item(1)], status(429))).rejects.toThrow()
    await expect(deliverSecurityMail(env(), [item(1)], status(503))).rejects.toThrow()
  })
})
