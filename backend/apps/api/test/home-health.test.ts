import { env, exports } from "cloudflare:workers"
import { conversation as homeConversation } from "@cmux/home-core"
import { describe, expect, it } from "vitest"
import { HOME_HEALTH_CRON, PROBE_SENDER, PROBE_PEER, runHomeHealth } from "../src/home-health.ts"

/**
 * Cloud Home health (plans/cmux-next/home-messaging-invites/DESIGN.md section 3, H1): every five
 * minutes the Worker sends one message between two probe users through the real owners
 * (ConversationDO, the peer's UserDO inbox) and reports the result as a Sentry Cron check-in.
 * Sentry opens one issue after two failed check-ins in a row (or a missed one) and resolves it on
 * the next good one; the Worker keeps no alert state of its own.
 */
const testEnv = env as unknown as Record<string, unknown> & { USER_DO: DurableObjectNamespace; CONVERSATION_DO: DurableObjectNamespace }
const DSN = "https://publickey@o1.ingest.sentry.test/42"
const worker = (exports as unknown as { default: { scheduled(options: { cron: string; scheduledTime: Date }): Promise<unknown> } }).default

interface Sent {
  readonly url: string
  readonly auth: string
  readonly items: ReadonlyArray<Record<string, unknown>>
}
const recorder = () => {
  const sent: Array<Sent> = []
  const fetcher = async (url: string, init?: { headers?: Record<string, string>; body?: string }) => {
    const lines = String(init?.body ?? "").split("\n").filter((l) => l.length > 0).map((l) => JSON.parse(l) as Record<string, unknown>)
    sent.push({ url, auth: init?.headers?.["x-sentry-auth"] ?? "", items: lines })
    return new Response("{}", { status: 200 })
  }
  return { sent, fetcher }
}
const checkInOf = (s: Sent) => s.items.find((item, i) => i > 0 && s.items[i - 1]?.type === "check_in") as Record<string, any>
const peerInbox = async () => {
  const inbox = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(PROBE_PEER)) as unknown as { readInbox(e: string, p: unknown, op: string, params: unknown): Promise<{ ok: boolean; value?: { entries: Array<{ conversation: string; preview: string }> } }> }
  return inbox.readInbox(PROBE_PEER, { identity: "test", user: PROBE_PEER, kind: "session" }, "inbox.list", { limit: 50 })
}
const dmId = homeConversation.dmConversationId(PROBE_SENDER, PROBE_PEER)

describe("Cloud Home health probe", { timeout: 60_000 }, () => {
  it("a healthy round trip reaches the peer's inbox and checks in ok; the next run reuses the same DM", async () => {
    const { sent, fetcher } = recorder()
    const first = await runHomeHealth({ ...testEnv, SENTRY_DSN: DSN } as never, { fetcher })
    expect(first.probe).toMatchObject({ ok: true, step: "done" })
    expect(first.check_in).toBe("sent")
    const inbox = await peerInbox()
    expect(inbox.ok).toBe(true)
    expect(inbox.value!.entries.map((e) => e.conversation)).toEqual([dmId])

    expect(sent).toHaveLength(1)
    expect(sent[0]!.url).toBe("https://o1.ingest.sentry.test/api/42/envelope/")
    expect(sent[0]!.auth).toContain("sentry_key=publickey")
    const ok = checkInOf(sent[0]!)
    expect(ok).toMatchObject({ monitor_slug: "cloud-home-test", status: "ok", environment: "test" })
    expect(ok.monitor_config).toMatchObject({ schedule: { type: "crontab", value: HOME_HEALTH_CRON }, failure_issue_threshold: 2, recovery_threshold: 1 })

    const second = await runHomeHealth({ ...testEnv, SENTRY_DSN: DSN } as never, { fetcher })
    expect(second.probe.ok).toBe(true)
    expect((await peerInbox()).value!.entries.map((e) => e.conversation)).toEqual([dmId])
    expect(sent).toHaveLength(2)
  })

  it("a broken owner checks in as error with the failed step, one check-in per run", async () => {
    const { sent, fetcher } = recorder()
    const broken = { ...testEnv, SENTRY_DSN: DSN, CONVERSATION_DO: { idFromName: () => { throw new Error("owner down") }, get: () => { throw new Error("owner down") } } }
    const a = await runHomeHealth(broken as never, { fetcher })
    const b = await runHomeHealth(broken as never, { fetcher })
    expect(a.probe).toMatchObject({ ok: false, step: "open" })
    expect(b.probe.ok).toBe(false)
    expect(sent.map((s) => checkInOf(s).status)).toEqual(["error", "error"])
    // Recovery: the next good run checks in ok (Sentry resolves its issue).
    const c = await runHomeHealth({ ...testEnv, SENTRY_DSN: DSN } as never, { fetcher })
    expect(c.probe.ok).toBe(true)
    expect(sent.map((s) => checkInOf(s).status)).toEqual(["error", "error", "ok"])
  })

  it("with no SENTRY_DSN the probe still runs and only logs", async () => {
    const { sent, fetcher } = recorder()
    const { SENTRY_DSN: _none, ...withoutDsn } = testEnv
    const run = await runHomeHealth(withoutDsn as never, { fetcher })
    expect(run.probe.ok).toBe(true)
    expect(run.check_in).toBe("skipped")
    expect(sent).toHaveLength(0)
  })

  it("the Worker's five-minute cron runs the probe", async () => {
    await worker.scheduled({ cron: HOME_HEALTH_CRON, scheduledTime: new Date() })
    const inbox = await peerInbox()
    expect(inbox.value!.entries.map((e) => e.conversation)).toEqual([dmId])
  })
})
