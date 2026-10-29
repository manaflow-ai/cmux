import { env } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { Env } from "../src/env.ts"
import { handleCreditsWebhook } from "../src/credits-routes.ts"
import { testPlanGrant } from "../src/inference/plan.ts"
import { hmacHex } from "../src/ingress/verify.ts"
import { handlePlanCheckout } from "../src/plan-checkout.ts"

const secret = "whsec_plan_checkout_delivery_test"
const testEnv: Env = { ...(env as unknown as Env), STRIPE_CREDITS_WEBHOOK_SECRET: secret }
const TEAM = "team_25574000000000000000"
const session = (suffix: string, team = TEAM) => ({
  id: `cs_test_${suffix}`, livemode: false, mode: "subscription", status: "complete", payment_status: "paid",
  currency: "usd", amount_total: 5000, amount_subtotal: 5000, subscription: `sub_${suffix}`,
  metadata: { app: "cmux", kind: "cmux_plan", team, plan: "pro" }
})
const hook = async (e: Env, type: string, object: unknown) => {
  const body = JSON.stringify({ type, livemode: false, data: { object } })
  const t = Math.floor(Date.now() / 1000)
  return handleCreditsWebhook(new Request("https://api.test/v1/hooks/stripe/credits", {
    method: "POST", headers: { "stripe-signature": `t=${t},v1=${await hmacHex(secret, `${t}.${body}`)}` }, body
  }), e)
}
const returned = (e: Env, id: string) => handlePlanCheckout(new Request(`https://api.test/v1/billing/plan/done?session_id=${id}`), e, "done")
const grant = async (team = TEAM) => {
  const stub = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team))
  return runInDurableObject(stub, async (instance) => testPlanGrant(instance.ctx.storage.sql))
}

afterEach(() => vi.restoreAllMocks())

describe("Chief plan checkout delivery", () => {
  it("a cancellation delivered before checkout completion stays revoked on completion and return", async () => {
    const paid = session("cancelledfirst")
    vi.spyOn(globalThis, "fetch").mockResolvedValue(Response.json(paid))
    expect((await hook(testEnv, "customer.subscription.deleted", { id: paid.subscription, metadata: paid.metadata })).status).toBe(200)
    expect(await (await hook(testEnv, "checkout.session.completed", paid)).json()).toEqual({ received: true, granted: false })
    expect((await returned(testEnv, paid.id)).status).toBe(410)
    expect(await grant()).toBeNull()
    // Revocation is scoped to the cancelled subscription, not future purchases on this team.
    expect(await (await hook(testEnv, "checkout.session.completed", session("replacement"))).json()).toEqual({ received: true, granted: true })
    expect(await grant()).toBe("pro")
  })

  it.each(["throws", "retry"])("a Chief notice that %s asks for webhook redelivery and is retried after the grant", async (failure) => {
    // A team of its own per case, so the grant asserted below is this session's, not an earlier test's.
    const team = failure === "throws" ? "team_25574000000000000001" : "team_25574000000000000002"
    const paid = { ...session(`notice${failure}`, team), metadata: { ...session("", team).metadata, chief: "agent_plan_notice", conversation: "conv_plan_notice" } }
    expect(await grant(team)).toBeNull()
    const chiefPlan = vi.fn().mockResolvedValue({ ok: true })
    if (failure === "throws") chiefPlan.mockRejectedValueOnce(new Error("owner temporarily unreachable"))
    else chiefPlan.mockResolvedValueOnce({ ok: false, code: "owner.unreachable", message: "try again", retry: true })
    const e: Env = { ...testEnv, CHIEF_BRAIN_DO: { idFromName: (name: string) => name, get: () => ({ chiefPlan }) } as unknown as Env["CHIEF_BRAIN_DO"] }
    const first = await hook(e, "checkout.session.completed", paid)
    expect(first.status).toBe(503)
    // The durable grant already exists; delivery must still run when its session is replayed.
    expect(await grant(team)).toBe("pro")
    const retry = await hook(e, "checkout.session.completed", paid)
    expect(retry.status).toBe(200)
    expect(await retry.json()).toEqual({ received: true, granted: false })
    expect(chiefPlan).toHaveBeenCalledTimes(2)
    expect(chiefPlan.mock.calls[1]![0]).toMatchObject({ session: paid.id, team: paid.metadata.team, chief: paid.metadata.chief, conversation: paid.metadata.conversation })
  })
})
