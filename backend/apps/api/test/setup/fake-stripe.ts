import { env } from "cloudflare:workers"
import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test"
import { vi } from "vitest"
import worker from "../../src/index.ts"

/**
 * The payment service faked at its HTTP boundary (api.stripe.com) for the usage sync route tests
 * (inference-spend-facts.test.ts), with the model provider faked beside it.
 */
export const SYNC_KEY = "test-billing-levels-key-0123456789abcdef"
const USAGE_PRICES: Record<string, string> = { "cmux-ai-usage-go-incl5-v1": "price_u_go", "cmux-ai-usage-pro-incl20-v1": "price_u_pro", "cmux-ai-usage-max-incl100-v1": "price_u_max", "cmux-ai-usage-team-incl20-v1": "price_u_team", "cmux-ai-usage-team-seat20-v1": "price_u_team_seat", "cmux-ai-usage-pro-incl1-e2e": "price_e2e_pro", "cmux-ai-usage-team-seat0.5-e2e": "price_e2e_team_seat" }

type Call = { method: string; path: string; form: Record<string, string>; idempotency: string | null; version: string | null }
type FakeSub = { id: string; status: string; customer: string; metadata: Record<string, string>; items: { data: Array<any> } }

/** An in-memory payment service: prices by lookup key, subscriptions, subscription items, meter events. */
export const fakeStripe = (period: { start: number; end: number }) => {
  const calls: Call[] = []
  const events: Array<Record<string, string>> = []
  /** Every meter event request, failed or accepted. */
  const attempts: Array<Record<string, string>> = []
  const control = { failMeterEvents: 0 }
  const subs: FakeSub[] = []
  const seen = new Map<string, unknown>()
  const addSub = (id: string, customer: string, metadata: Record<string, string>, planLookup: string, extra: Array<any> = []) => {
    const sub: FakeSub = { id, status: "active", customer, metadata: { app: "cmux", ...metadata }, items: { data: [{ id: `si_plan_${id}`, quantity: 1, price: { id: `price_plan_${id}`, product: "prod_plan", lookup_key: planLookup, recurring: { interval: "month" } } }, ...extra] } }
    subs.push(sub)
    return sub
  }
  const withPeriod = (sub: FakeSub) => ({ ...structuredClone(sub), items: { data: sub.items.data.map((i) => ({ ...structuredClone(i), current_period_start: period.start, current_period_end: period.end })) } })
  const handle = async (url: URL, init: RequestInit): Promise<Response> => {
    const method = (init.method ?? "GET").toUpperCase()
    const form = Object.fromEntries(new URLSearchParams(typeof init.body === "string" ? init.body : ""))
    const headers = new Headers(init.headers)
    const idempotency = headers.get("idempotency-key")
    calls.push({ method, path: url.pathname, form, idempotency, version: headers.get("stripe-version") })
    if (idempotency && seen.has(idempotency)) return Response.json(seen.get(idempotency))
    const ok = (body: unknown) => {
      if (idempotency) seen.set(idempotency, body)
      return Response.json(body)
    }
    if (method === "GET" && url.pathname === "/v1/prices") return ok({ data: url.searchParams.getAll("lookup_keys[]").filter((k) => USAGE_PRICES[k]).map((k) => ({ id: USAGE_PRICES[k], lookup_key: k })) })
    if (method === "GET" && url.pathname === "/v1/subscriptions") return ok({ data: subs.filter((x) => x.status === url.searchParams.get("status") && (!url.searchParams.get("customer") || x.customer === url.searchParams.get("customer"))).map(withPeriod), has_more: false })
    const one = url.pathname.match(/^\/v1\/subscriptions\/(sub_[A-Za-z0-9_]+)$/)
    if (method === "GET" && one) {
      const sub = subs.find((x) => x.id === one[1])
      return sub ? ok(withPeriod(sub)) : Response.json({ error: { code: "resource_missing", message: "no such subscription" } }, { status: 404 })
    }
    if (method === "POST" && url.pathname === "/v1/subscription_items") {
      const item = { id: `si_usage_${form.subscription}`, price: { id: form.price, product: "cmux_ai_usage", recurring: { interval: "month" } } }
      subs.find((x) => x.id === form.subscription)!.items.data.push(item)
      return ok({ ...item, current_period_start: period.start, current_period_end: period.end })
    }
    const moved = url.pathname.match(/^\/v1\/subscription_items\/(.+)$/)
    if (method === "POST" && moved) {
      const item = subs.flatMap((x) => x.items.data).find((i) => i.id === moved[1])
      item.price = { ...item.price, id: form.price }
      return ok({ ...structuredClone(item), current_period_start: period.start, current_period_end: period.end })
    }
    if (method === "POST" && url.pathname === "/v1/billing/meter_events") {
      // `failMeterEvents`: the next N sends fail as a 500 (the request is still seen, as a payment service may record it).
      if (control.failMeterEvents > 0) {
        control.failMeterEvents--
        attempts.push(form)
        return Response.json({ error: { type: "api_error", message: "try again" } }, { status: 500 })
      }
      attempts.push(form)
      events.push(form)
      return ok({ object: "billing.meter_event", identifier: form.identifier })
    }
    return Response.json({ error: { code: "resource_missing", message: `no fake for ${method} ${url.pathname}` } }, { status: 404 })
  }
  return { calls, events, attempts, control, subs, addSub, period, handle }
}

/** Fakes both boundaries: the model provider answers `cost`, the payment service is `stripe`. */
export const fakeBoundaries = (stripe: ReturnType<typeof fakeStripe>, cost: number) => {
  const real = globalThis.fetch
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(input instanceof Request ? input.url : String(input))
    if (url.hostname === "api.stripe.com") return stripe.handle(url, init ?? {})
    if (url.hostname === "openrouter.ai") return Response.json({ id: "x", choices: [{ index: 0, message: { role: "assistant", content: "ok" } }], usage: { prompt_tokens: 10, completion_tokens: 5, cost } })
    return real(input, init)
  })
}

/** One usage sync run through the Worker's fetch handler (POST /v1/internal/billing/sync). */
export const sync = async (runEnv: unknown = env, body = "{}") => {
  const ctx = createExecutionContext()
  const res = await worker.fetch!(new Request("https://api.test/v1/internal/billing/sync", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${SYNC_KEY}` }, body }) as any, runEnv as any, ctx)
  const out = (await res.json()) as any
  await waitOnExecutionContext(ctx)
  return { status: res.status, body: out }
}

export const nowS = () => Math.floor(Date.now() / 1000)
