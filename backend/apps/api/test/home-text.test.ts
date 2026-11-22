import { env, exports } from "cloudflare:workers"
import { runInDurableObject as runIn } from "cloudflare:test"
import { conversation as homeConversation, invites } from "@cmux/home-core"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { userIdFor } from "../src/domains/user.ts"
import { handleSendblueHook } from "../src/home-text.ts"
import { fireAlarm } from "./setup/alarm.ts"

/** Stage C part 2: invite texts send the contact card first, the text after SendBlue reports it. */
const runInDurableObject = runIn as unknown as <T>(stub: unknown, fn: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; HOME_ADDRESS_KEY: string; ADDRESS_DO: any; CONVERSATION_DO: any }
const worker = (exports as unknown as { default: Fetcher }).default
const sessionToken = async (sub: string) =>
  new SignJWT({ email: `${sub}@example.com`, email_verified: true, name: "Alice Example" })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))
const op = async (token: string, name: string, params: unknown) => {
  const res = await worker.fetch("https://api.test/v1/ops", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, body: JSON.stringify({ op: name, params, idempotency_key: crypto.randomUUID(), origin: "user" }) })
  return (await res.json()) as any
}
const PHONE = "+14155550123"
const ON = {
  HOME_INVITES_SEND: "on", ENVIRONMENT: "staging", WORKER_NAME: "cmux-api-staging", HOME_INVITE_ORIGIN: "https://console-staging.cmux.dev", HOME_INVITE_ALLOWLIST_PHONES: PHONE,
  SENDBLUE_API_KEY: "sb_key", SENDBLUE_API_SECRET: "sb_secret", SENDBLUE_FROM_NUMBER: "+14155550199"
}

describe("invite texts (stage C part 2)", { timeout: 60_000 }, () => {
  it("first contact: card, then the text only after the card is reported; later invites: text only", async () => {
    const token = await sessionToken("text-owner")
    await op(token, "user.ensure", {})
    const user = userIdFor(testEnv.STACK_PROJECT_ID, "text-owner")
    const address = invites.addressId(testEnv.HOME_ADDRESS_KEY, invites.normalizePhone(PHONE) as invites.Address)
    const addr = testEnv.ADDRESS_DO.get(testEnv.ADDRESS_DO.idFromName(address))
    expect((await op(token, "dm.open", { peer: { phone: PHONE } })).ok).toBe(true)
    const sends: Array<{ media_url?: string; content: string; status_callback?: string }> = []
    await runInDurableObject(addr, async (instance) => {
      instance.env = { ...instance.env, ...ON }
      instance.fetcher = async (_url: string, init: { body: string }) => {
        sends.push(JSON.parse(init.body))
        return { status: 200, json: async () => ({ message_handle: `h-${sends.length}`, status: "QUEUED" }) }
      }
    })
    const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(homeConversation.dmConversationId(user, address)))
    for (let i = 0; i < 10 && sends.length === 0; i++) {
      await fireAlarm(conv)
      await fireAlarm(addr)
    }
    // Step 1: only the contact card, with the status callback.
    expect(sends).toHaveLength(1)
    expect(sends[0]!.media_url).toBe("https://cloud-api-staging.cmux.dev/v1/home/cmux.vcf")
    expect(sends[0]!.status_callback).toBe("https://cloud-api-staging.cmux.dev/v1/hooks/sendblue")
    const state = () => runInDurableObject(addr, async (i) => String(i.boundEngine.currentState.deliveries[0].state))
    expect(await state()).toBe("sending")
    // A QUEUED report releases nothing; SENT releases the text with the link and the invite image.
    await (addr as any).textEvent(address, { message_handle: "h-1", status: "QUEUED", number: PHONE, is_outbound: true, content: "", opted_out: false })
    expect(sends).toHaveLength(1)
    await (addr as any).textEvent(address, { message_handle: "h-1", status: "SENT", number: PHONE, is_outbound: true, content: "", opted_out: false })
    expect(sends).toHaveLength(2)
    expect(sends[1]!.content).toMatch(/https:\/\/console-staging\.cmux\.dev\/i\/d[0-9A-HJKMNP-TV-Z]{26}#[0-9A-HJKMNP-TV-Z]{26}\s*$/)
    expect(sends[1]!.media_url).toMatch(/^https:\/\/console-staging\.cmux\.dev\/og\/invite\/d[0-9A-HJKMNP-TV-Z]{26}\.png/)
    expect(await state()).toBe("sent")
    // DELIVERED for the text updates the delivery; an inbound STOP suppresses the number.
    await (addr as any).textEvent(address, { message_handle: "h-2", status: "DELIVERED", number: PHONE, is_outbound: true, content: "", opted_out: false })
    expect(await state()).toBe("delivered")
    await (addr as any).textEvent(address, { message_handle: "in-1", status: "RECEIVED", number: PHONE, is_outbound: false, content: "STOP", opted_out: false })
    expect(await runInDurableObject(addr, async (i) => i.boundEngine.currentState.suppression?.reason)).toBe("opted_out")
  })

  it("a STOP after the card sends no text; a second invite waits for the same card instead of a second card", async () => {
    const token = await sessionToken("text-owner-2")
    await op(token, "user.ensure", {})
    const user = userIdFor(testEnv.STACK_PROJECT_ID, "text-owner-2")
    const phone = "+14155550124"
    const address = invites.addressId(testEnv.HOME_ADDRESS_KEY, invites.normalizePhone(phone) as invites.Address)
    const addr = testEnv.ADDRESS_DO.get(testEnv.ADDRESS_DO.idFromName(address))
    const sends: Array<{ media_url?: string; content: string }> = []
    let handle = true
    await runInDurableObject(addr, async (instance) => {
      instance.env = { ...instance.env, ...ON, HOME_INVITE_ALLOWLIST_PHONES: phone }
      instance.fetcher = async (_url: string, init: { body: string }) => {
        sends.push(JSON.parse(init.body))
        return { status: 200, json: async () => (handle ? { message_handle: `k-${sends.length}`, status: "QUEUED" } : { status: "QUEUED" }) }
      }
    })
    const pump = async (conv: unknown, want: number) => {
      for (let i = 0; i < 10 && sends.length < want; i++) {
        await fireAlarm(conv as never)
        await fireAlarm(addr)
      }
    }
    const states = () => runInDurableObject(addr, async (i) => (i.boundEngine.currentState.deliveries as Array<{ state: string }>).map((d) => d.state))
    // Invite 1 sends the card; invite 2 to the same number waits for that card instead of sending another.
    expect((await op(token, "dm.open", { peer: { phone } })).ok).toBe(true)
    await pump(testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(homeConversation.dmConversationId(user, address))), 1)
    expect(sends).toHaveLength(1)
    // A second inviter (the same inviter would count as a repeat).
    const token2 = await sessionToken("text-owner-2b")
    await op(token2, "user.ensure", {})
    const user2 = userIdFor(testEnv.STACK_PROJECT_ID, "text-owner-2b")
    expect((await op(token2, "dm.open", { peer: { phone } })).ok).toBe(true)
    const conv2 = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(homeConversation.dmConversationId(user2, address)))
    for (let i = 0; i < 10 && (await states()).length < 2; i++) {
      await fireAlarm(conv2)
      await fireAlarm(addr)
    }
    await fireAlarm(addr)
    expect(await states()).toEqual(["sending", "sending"])
    expect(sends).toHaveLength(1)
    // The recipient answers STOP before the card status comes: SENT releases no text.
    await (addr as any).textEvent(address, { message_handle: "in-9", status: "RECEIVED", number: phone, is_outbound: false, content: " stop ", opted_out: false })
    await (addr as any).textEvent(address, { message_handle: "k-1", status: "SENT", number: phone, is_outbound: true, content: "", opted_out: false })
    expect(sends).toHaveLength(1)
    expect(await states()).toEqual(["suppressed", "suppressed"])
  })

  it("a card with no status closes at the card deadline, with no alarm loop before it", async () => {
    const token = await sessionToken("text-owner-4")
    await op(token, "user.ensure", {})
    const user = userIdFor(testEnv.STACK_PROJECT_ID, "text-owner-4")
    const phone = "+14155550126"
    const address = invites.addressId(testEnv.HOME_ADDRESS_KEY, invites.normalizePhone(phone) as invites.Address)
    const addr = testEnv.ADDRESS_DO.get(testEnv.ADDRESS_DO.idFromName(address))
    let sent = 0
    await runInDurableObject(addr, async (instance) => {
      instance.env = { ...instance.env, ...ON, HOME_INVITE_ALLOWLIST_PHONES: phone }
      instance.fetcher = async () => {
        sent++
        return { status: 200, json: async () => ({ message_handle: `n-${sent}`, status: "QUEUED" }) }
      }
    })
    expect((await op(token, "dm.open", { peer: { phone } })).ok).toBe(true)
    const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(homeConversation.dmConversationId(user, address)))
    for (let i = 0; i < 10 && sent === 0; i++) {
      await fireAlarm(conv)
      await fireAlarm(addr)
    }
    expect(sent).toBe(1)
    // Past the 10 minute attempt deadline the next wake is still the card deadline (one day), never a past time.
    const wake = (dt: number) => runInDurableObject(addr, async (i) => Number(i.nextWakeAt(i.boundEngine.currentState, Date.now() + dt)) - Date.now())
    expect(await wake(11 * 60_000)).toBeGreaterThan(23 * 3600_000)
    await runInDurableObject(addr, async (i) => i.onWake(Date.now() + 11 * 60_000))
    expect(await runInDurableObject(addr, async (i) => String(i.boundEngine.currentState.deliveries[0].state))).toBe("sending")
    await runInDurableObject(addr, async (i) => i.onWake(Date.now() + 24 * 3600_000 + 1000))
    expect(await runInDurableObject(addr, async (i) => String(i.boundEngine.currentState.deliveries[0].state))).toBe("indeterminate")
    expect(sent).toBe(1)
  })

  it("a card accepted without a handle closes the invite with no text", async () => {
    const token = await sessionToken("text-owner-3")
    await op(token, "user.ensure", {})
    const user = userIdFor(testEnv.STACK_PROJECT_ID, "text-owner-3")
    const phone = "+14155550125"
    const address = invites.addressId(testEnv.HOME_ADDRESS_KEY, invites.normalizePhone(phone) as invites.Address)
    const addr = testEnv.ADDRESS_DO.get(testEnv.ADDRESS_DO.idFromName(address))
    let sent = 0
    await runInDurableObject(addr, async (instance) => {
      instance.env = { ...instance.env, ...ON, HOME_INVITE_ALLOWLIST_PHONES: phone }
      instance.fetcher = async () => {
        sent++
        return { status: 200, json: async () => ({ status: "QUEUED" }) }
      }
    })
    expect((await op(token, "dm.open", { peer: { phone } })).ok).toBe(true)
    const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(homeConversation.dmConversationId(user, address)))
    for (let i = 0; i < 10 && sent === 0; i++) {
      await fireAlarm(conv)
      await fireAlarm(addr)
    }
    expect(sent).toBe(1)
    // The adapter reports a handle-less accept as indeterminate; nothing waits on it and no text follows.
    expect(await runInDurableObject(addr, async (i) => String(i.boundEngine.currentState.deliveries[0].state))).toBe("indeterminate")
    expect(await runInDurableObject(addr, async (_i, state) => state.storage.sql.exec("SELECT COUNT(*) AS n FROM address_card_steps").one().n)).toBe(0)
    await fireAlarm(addr)
    expect(sent).toBe(1)
  })

  it("the webhook needs the secret and acts on SendBlue's own record of the handle", async () => {
    const hook = (secret: string | null, fetcher: typeof fetch) =>
      handleSendblueHook(
        new Request("https://api.test/v1/hooks/sendblue", { method: "POST", headers: { "content-type": "application/json", ...(secret ? { "sb-signing-secret": secret } : {}) }, body: JSON.stringify({ message_handle: "5a17319e-0000-hook", status: "DELIVERED", number: PHONE }) }),
        Object.assign({}, env as object, { SENDBLUE_WEBHOOK_SECRET: "whsec", SENDBLUE_API_KEY: "k", SENDBLUE_API_SECRET: "s" }) as never,
        fetcher
      )
    let looked = 0
    const sendblue = (async () => {
      looked++
      return new Response(JSON.stringify({ message_handle: "5a17319e-0000-hook", status: "DELIVERED", number: PHONE, is_outbound: true }), { status: 200 })
    }) as unknown as typeof fetch
    expect((await hook(null, sendblue)).status).toBe(401)
    expect((await hook("wrong", sendblue)).status).toBe(401)
    expect(looked).toBe(0)
    expect((await hook("whsec", sendblue)).status).toBe(200)
    expect(looked).toBe(1)
    // SendBlue cannot confirm the handle: nothing acts; SendBlue retries.
    expect((await hook("whsec", (async () => new Response("no", { status: 404 })) as unknown as typeof fetch)).status).toBe(503)
  })
})
