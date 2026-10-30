import { env } from "cloudflare:workers"
import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test"
import { afterEach, describe, expect, it, vi } from "vitest"
import worker from "../src/index.ts"
import { inDO, post, testEnv, token } from "./setup/inference-person.ts"

/**
 * Paid plan step 4 (plans/cmux-next/paid-plan.md §5): a credits top-up is one tap for a returning
 * payer. The first top-up saves its card on the team's payment customer; a later top-up opens Checkout
 * on that customer with saved cards shown. Payment service faked at api.stripe.com.
 */

const ORIGIN = "https://api.test"

const fakeStripe = () => {
  const made: Array<Record<string, string>> = []
  const real = globalThis.fetch
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(input instanceof Request ? input.url : String(input))
    if (url.hostname !== "api.stripe.com") return real(input, init)
    made.push(Object.fromEntries(new URLSearchParams(String(init?.body ?? ""))))
    return Response.json({ id: `cs_test_fast${made.length}`, url: `https://checkout.stripe.com/c/pay/cs_test_fast${made.length}` })
  })
  return made
}

const topup = async (t: string, usd: number) => {
  const ctx = createExecutionContext()
  const res = await worker.fetch!(new Request(`${ORIGIN}/v1/credits/topup`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${t}` }, body: JSON.stringify({ usd }) }) as any, { ...env, CLOUD_API_ORIGIN: ORIGIN } as any, ctx)
  await waitOnExecutionContext(ctx)
  return res.status
}

afterEach(() => {
  vi.restoreAllMocks()
})

describe("credits checkout is one tap for a returning payer (paid-plan step 4)", () => {
  it("the first top-up saves the card; the next one shows the saved card on the same customer", async () => {
    const t = await token("credits-fast")
    const team = (await post("/v1/ops", t, { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "cli" })).value.personal_team as string
    const made = fakeStripe()

    expect(await topup(t, 10)).toBe(200)
    expect(made[0]).toMatchObject({ customer_creation: "always", "payment_intent_data[setup_future_usage]": "off_session" })

    // The first paid top-up recorded the team's customer (grantPaidSession).
    await inDO(testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(team)), async (m) => {
      await m.setCreditCustomer(team, "test", "cus_TestFast123")
    })
    expect(await topup(t, 20)).toBe(200)
    expect(made[1]).toMatchObject({
      customer: "cus_TestFast123",
      "payment_intent_data[setup_future_usage]": "off_session",
      "saved_payment_method_options[allow_redisplay_filters][0]": "always",
      "saved_payment_method_options[allow_redisplay_filters][1]": "limited",
      "saved_payment_method_options[allow_redisplay_filters][2]": "unspecified"
    })
    expect(made[1]!.customer_creation).toBeUndefined()
  })
})
