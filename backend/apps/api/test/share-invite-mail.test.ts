import { env } from "cloudflare:workers"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import type { Env } from "../src/env.ts"
import { handleShareInviteMail, mailIdOf, renderShareInviteEmail, shareIdOf, SHARE_INVITE_MAIL_PATH } from "../src/share-invite-mail.ts"

/** The chat share invite mail: off by default, a verified sender, a link on the share host only, sent once per share and person. */
const testEnv = env as unknown as Env & { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string }
const sessionToken = async (sub: string, email: string) =>
  new SignJWT({ email, email_verified: true, name: "Alice <b>Example</b>" })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))

const LINK = "https://share-staging.cmux.dev/i/AbCdEf0123456789xyzQ"
const on = (extra: Partial<Record<string, unknown>> = {}, allowed = true) =>
  ({
    ...testEnv,
    // "test" keeps the local Stack keys (auth.ts); its policy is a non-production one, with the allow list.
    ENVIRONMENT: "test",
    SHARE_INVITE_MAIL_SEND: "on",
    HOME_INVITES_SEND: "on",
    RESEND_API_KEY: "re_test_not_a_key",
    HOME_INVITE_FROM: "cmux <invites@example.test>",
    HOME_INVITE_ALLOWLIST_EMAILS: "bob@example.test",
    SHARE_INVITE_MAIL_LIMIT: { limit: async () => ({ success: allowed }) },
    ...extra
  }) as unknown as Env

const recorder = () => {
  const calls: { url: string; body: any; headers: Record<string, string> }[] = []
  const fetcher = async (url: string, init: any) => {
    calls.push({ url, body: JSON.parse(init.body), headers: init.headers })
    return new Response(JSON.stringify({ id: "email_1" }), { status: 200, headers: { "content-type": "application/json" } })
  }
  return { calls, fetcher: fetcher as any }
}

const post = async (e: Env, body: unknown, token?: string, fetcher?: any) =>
  handleShareInviteMail(
    new Request(`https://api.test${SHARE_INVITE_MAIL_PATH}`, {
      method: "POST",
      headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: JSON.stringify(body)
    }),
    e,
    fetcher
  )

describe("share invite mail", () => {
  it("is off unless SHARE_INVITE_MAIL_SEND is on", async () => {
    const { calls, fetcher } = recorder()
    const token = await sessionToken("share-mail-off", "alice@example.test")
    for (const value of [undefined, "", "off", "1"]) {
      const res = await post(on({ SHARE_INVITE_MAIL_SEND: value }), { to: "bob@example.test", invite_url: LINK }, token, fetcher)
      expect(res.status).toBe(404)
    }
    expect(calls).toHaveLength(0)
  })

  it("mails the invited address from the verified sender with the chat link", async () => {
    const { calls, fetcher } = recorder()
    const token = await sessionToken("share-mail-sent", "alice@example.test")
    const res = await post(on(), { to: " Bob@Example.test ", invite_url: LINK, role: "view" }, token, fetcher)
    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ state: "sent", provider_id: "email_1" })
    expect(calls).toHaveLength(1)
    const sent = calls[0]!
    expect(sent.body.to).toEqual(["bob@example.test"])
    expect(sent.body.subject).toBe("Alice <b>Example</b> shared a chat with you")
    expect(sent.body.text).toContain(LINK)
    expect(sent.body.html).toContain("Alice &lt;b&gt;Example&lt;/b&gt;")
    expect(sent.body.html).not.toContain("<b>Example")
    expect(sent.headers["Idempotency-Key"] ?? sent.headers["idempotency-key"]).toBe(`home-invite-${await mailIdOf("AbCdEf0123456789xyzQ", "bob@example.test")}`)
  })

  it("refuses without a token, a link off the share host, a bad address or over the rate limit", async () => {
    const { calls, fetcher } = recorder()
    const token = await sessionToken("share-mail-refused", "alice@example.test")
    expect((await post(on(), { to: "bob@example.test", invite_url: LINK }, undefined, fetcher)).status).toBe(401)
    for (const invite_url of ["https://evil.example/i/AbCdEf0123456789xyzQ", "https://share.cmux.dev/i/AbCdEf0123456789xyzQ", `${LINK}?x=1`, "https://share-staging.cmux.dev/x/AbCdEf0123456789", "not a url"]) {
      expect((await post(on(), { to: "bob@example.test", invite_url }, token, fetcher)).status).toBe(400)
    }
    for (const to of ["@bob", "bob", "a@b", "x".repeat(250) + "@example.test"]) {
      expect((await post(on(), { to, invite_url: LINK }, token, fetcher)).status).toBe(400)
    }
    expect((await post(on(), { to: "bob@example.test", invite_url: LINK, role: "owner" }, token, fetcher)).status).toBe(400)
    expect((await post(on({}, false), { to: "bob@example.test", invite_url: LINK }, token, fetcher)).status).toBe(429)
    expect((await post(on({ SHARE_INVITE_MAIL_LIMIT: undefined }), { to: "bob@example.test", invite_url: LINK }, token, fetcher)).status).toBe(503)
    expect(calls).toHaveLength(0)
  })

  it("keeps the Home invite policy: the send switch and the allow list outside production", async () => {
    const { calls, fetcher } = recorder()
    const token = await sessionToken("share-mail-policy", "alice@example.test")
    const off = await post(on({ HOME_INVITES_SEND: "off" }), { to: "bob@example.test", invite_url: LINK }, token, fetcher)
    expect((await off.json()) as any).toMatchObject({ state: "disabled" })
    const outside = await post(on(), { to: "carol@example.test", invite_url: LINK }, token, fetcher)
    expect((await outside.json()) as any).toMatchObject({ state: "refused_env" })
    expect(calls).toHaveLength(0)
  })

  it("takes only this deployment's share links", () => {
    expect(shareIdOf("production", "https://share.cmux.dev/i/AbCdEf0123456789")).toBe("AbCdEf0123456789")
    expect(shareIdOf("production", LINK)).toBeNull()
    expect(shareIdOf("staging", LINK)).toBe("AbCdEf0123456789xyzQ")
    expect(shareIdOf("development", LINK)).toBe("AbCdEf0123456789xyzQ")
    expect(shareIdOf("staging", "https://share-staging.cmux.dev/i/short")).toBeNull()
  })

  it("renders a mail without links in the sender's name", () => {
    const mail = renderShareInviteEmail({ name: "Eve https://phish.example", link: LINK })
    expect(mail.subject).not.toContain("phish.example")
    expect(mail.text).toContain("chat in it")
    expect(renderShareInviteEmail({ name: "", link: LINK }).subject).toBe("Someone shared a chat with you")
  })
})
