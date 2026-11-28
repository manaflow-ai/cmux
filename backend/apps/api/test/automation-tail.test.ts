import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { RUN_MARKER } from "../src/code-run.ts"

/**
 * Billing rule: we never over-bill. A tail delivery the runtime sends twice must count once.
 * The usage key comes from the invocation's own identity (the harness marker), never from a
 * value the tail consumer makes up per delivery (plans/cmux-next/automations-plan.md 2a).
 */

const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; USAGE_METER_DO: DurableObjectNamespace }
const worker = (exports as unknown as { default: Fetcher }).default
const inDO = runInDurableObject as unknown as (stub: unknown, cb: (instance: any) => Promise<void>) => Promise<void>

const token = async (stackUser: string) => {
  const key = await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256")
  return new SignJWT({ email: `${stackUser}@example.com`, name: stackUser })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(stackUser)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(key)
}
const teamOf = async (u: string) => {
  const res = await worker.fetch("https://api.test/v1/ops", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${await token(u)}` },
    body: JSON.stringify({ op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "cli" })
  })
  return ((await res.json()) as any).value.personal_team as string
}

const RUN = "run_aaaaaaaaaaaaaaaaaaaa"
const AUTO = "auto_bbbbbbbbbbbbbbbbbbbb"
const inv = (c: string) => `inv_${c.repeat(20)}`

interface TailStub {
  tail(events: ReadonlyArray<unknown>): Promise<void>
}

/** One buffered tail delivery of one tenant invocation (the harness marker first, if any). */
const deliver = async (team: string, o: { at: number; marker?: ReadonlyArray<string>; cpu: number }) => {
  const tail = (exports as unknown as { AutomationTail: (x: { props: unknown }) => TailStub }).AutomationTail({ props: { team, commit: "c".repeat(40) } })
  const logs = [...(o.marker ? [{ timestamp: o.at, level: "log", message: o.marker }] : []), { timestamp: o.at, level: "log", message: ["tenant says hi"] }]
  await tail.tail([{ scriptName: null, entrypoint: "CmuxHarness", event: null, eventTimestamp: o.at, logs, exceptions: [], diagnosticsChannelEvents: [], outcome: "ok", truncated: false, cpuTime: o.cpu, wallTime: o.cpu + 5, executionModel: "stateless", scriptTags: [] }])
}

const usage = async (team: string) => {
  let meters: Array<{ meter: string; quantity: number }> = []
  await inDO(testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(team)), async (m) => {
    meters = (await m.check(team)).summary.meters
  })
  return (name: string) => meters.find((x) => x.meter === name)?.quantity ?? 0
}

describe("AutomationTail usage keys (workerd)", () => {
  it("counts a redelivered tail once", async () => {
    const team = await teamOf("tail-user-1")
    const marker = [RUN_MARKER, RUN, AUTO, inv("a")]
    await deliver(team, { at: 1_700_000_000_000, marker, cpu: 40 })
    await deliver(team, { at: 1_700_000_000_000, marker, cpu: 40 })
    const q = await usage(team)
    expect(q("automation.invocations")).toBe(1)
    expect(q("automation.cpu_ms")).toBe(40)
  })

  it("counts two invocations of the same run twice", async () => {
    const team = await teamOf("tail-user-2")
    await deliver(team, { at: 1_700_000_000_001, marker: [RUN_MARKER, RUN, AUTO, inv("a")], cpu: 10 })
    await deliver(team, { at: 1_700_000_000_002, marker: [RUN_MARKER, RUN, AUTO, inv("b")], cpu: 15 })
    const q = await usage(team)
    expect(q("automation.invocations")).toBe(2)
    expect(q("automation.cpu_ms")).toBe(25)
  })

  it("meters nothing for an invocation without a valid harness marker (under-count, never guess)", async () => {
    const team = await teamOf("tail-user-3")
    await deliver(team, { at: 1_700_000_000_001, cpu: 10 })
    await deliver(team, { at: 1_700_000_000_002, marker: [RUN_MARKER, RUN, AUTO, "inv_short"], cpu: 10 })
    await deliver(team, { at: 1_700_000_000_003, marker: [RUN_MARKER, RUN, "x".repeat(300), inv("c")], cpu: 10 })
    const q = await usage(team)
    expect(q("automation.invocations")).toBe(0)
    expect(q("automation.cpu_ms")).toBe(0)
  })
})
