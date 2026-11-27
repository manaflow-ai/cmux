import { env } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { describe, expect, it } from "vitest"
import type { ChiefBrainDO } from "../src/chief-brain/brain-do.ts"
import type { Env } from "../src/env.ts"
import { SLACK_NON_OWNER_DAILY_AWAKE_SECONDS, awakeFact, awakeSeconds, meterSlackTurn, recordSlackSender, reportSlackAwake, senderAwakeSeconds, slackAwakeLabel, slackMayWake, utcDay, type SlackSender } from "../src/chief-brain/slack-meter.ts"

// RFD 0123 (Chief in Slack), Plan and billing: the brain's awake-time meter per Slack sender.

const inBrain = async <T>(f: (b: ChiefBrainDO) => T | Promise<T>): Promise<T> => {
  const ns = (env as unknown as Env).CHIEF_BRAIN_DO
  return runInDurableObject(ns.get(ns.idFromName(`slack-meter-${crypto.randomUUID()}`)), async (instance) => f(instance as ChiefBrainDO))
}

const guest: SlackSender = { slackTeamId: "T0TEAM", slackUserId: "U0GUEST", senderIsOwner: false, cmuxTeamId: "team_acme", ownerUserId: "user_owner" }
const owner: SlackSender = { ...guest, slackUserId: "U0OWNER", senderIsOwner: true }
const NOON = Date.UTC(2026, 10, 25, 12, 0, 0)

describe("slack awake meter", () => {
  it("rounds a turn up to whole seconds and charges nothing for a turn that never ran", () => {
    expect(awakeSeconds(NOON, NOON + 1)).toBe(1)
    expect(awakeSeconds(NOON, NOON + 61_500)).toBe(62)
    expect(awakeSeconds(NOON, NOON)).toBe(0)
    expect(awakeSeconds(NOON, NOON - 5)).toBe(0)
  })

  it("labels the Slack sender under the usage store's label rules", () => {
    expect(slackAwakeLabel("T0TEAM", "U0GUEST")).toBe("slack:T0TEAM/U0GUEST")
    expect(slackAwakeLabel("T0TEAM", "u-bad")).toBe("")
  })

  it("meters a turn against the sender of its trigger, once", async () => {
    await inBrain((b) => {
      recordSlackSender(b.sql, "msg_1", guest)
      expect(meterSlackTurn(b.sql, "run_1", "msg_1", NOON, NOON + 90_000)).toBe(true)
      expect(meterSlackTurn(b.sql, "run_1", "msg_1", NOON, NOON + 90_000)).toBe(false)
      // A turn whose trigger is no recorded Slack message costs nobody.
      expect(meterSlackTurn(b.sql, "run_2", "msg_unknown", NOON, NOON + 1_000)).toBe(false)
      expect(senderAwakeSeconds(b.sql, "T0TEAM", "U0GUEST", utcDay(NOON))).toBe(90)
      expect(senderAwakeSeconds(b.sql, "T0TEAM", "U0GUEST", "2026-11-26")).toBe(0)
    })
  })

  it("stops a non-owner's wakes at the day's allowance, never the owner's, and starts again the next UTC day", async () => {
    await inBrain((b) => {
      recordSlackSender(b.sql, "msg_g", guest)
      recordSlackSender(b.sql, "msg_o", owner)
      expect(slackMayWake(b.sql, guest, NOON)).toBe(true)
      meterSlackTurn(b.sql, "run_g", "msg_g", NOON - SLACK_NON_OWNER_DAILY_AWAKE_SECONDS * 1000, NOON)
      meterSlackTurn(b.sql, "run_o", "msg_o", NOON - 3 * 3600_000, NOON)
      expect(slackMayWake(b.sql, guest, NOON)).toBe(false)
      expect(slackMayWake(b.sql, owner, NOON)).toBe(true)
      expect(slackMayWake(b.sql, guest, NOON + 24 * 3600_000)).toBe(true)
      // The allowance is per sender: another guest in the same workspace still wakes it.
      expect(slackMayWake(b.sql, { ...guest, slackUserId: "U0OTHER" }, NOON)).toBe(true)
    })
  })

  it("reports each metered turn to cmux-platform once, keyed by the turn, and keeps a failed send for later", async () => {
    await inBrain(async (b) => {
      recordSlackSender(b.sql, "msg_1", guest)
      meterSlackTurn(b.sql, "run_1", "msg_1", NOON, NOON + 42_000)
      const calls: Array<{ url: string; auth: string | null; body: { facts: Array<Record<string, unknown>> } }> = []
      let status = 503
      const platform = { fetch: async (url: string, init: RequestInit) => {
        calls.push({ url, auth: new Headers(init.headers).get("authorization"), body: JSON.parse(String(init.body)) })
        return new Response(JSON.stringify({ accepted: 1, duplicates: 0, refused: [] }), { status })
      } } as unknown as Fetcher
      const cfg = { PLATFORM: platform, INTERNAL_TOKEN: "internal-test" }
      expect(await reportSlackAwake(cfg, b.sql, "agent_a")).toBe(0)
      status = 200
      expect(await reportSlackAwake(cfg, b.sql, "agent_a")).toBe(1)
      expect(await reportSlackAwake(cfg, b.sql, "agent_a")).toBe(0)
      expect(calls).toHaveLength(2)
      expect(calls[1]!.url).toBe("https://platform/internal/v1/usage/team_acme/facts")
      expect(calls[1]!.auth).toBe("Bearer internal-test")
      expect(calls[1]!.body.facts).toEqual([awakeFact("agent_a", { turn: "run_1", owner: "user_owner", slack_team: "T0TEAM", slack_user: "U0GUEST", at: NOON, seconds: 42 })])
      expect(calls[1]!.body.facts[0]).toMatchObject({ key: "chief-slack:agent_a:run_1", unit: "chief.slack_awake_seconds", quantity: 42, user: "user_owner", payer: "team", label: "slack:T0TEAM/U0GUEST", source: "chief_brain" })
    })
  })

  it("stops resending a fact the store refused", async () => {
    await inBrain(async (b) => {
      recordSlackSender(b.sql, "msg_1", guest)
      meterSlackTurn(b.sql, "run_1", "msg_1", NOON, NOON + 1_000)
      let calls = 0
      const platform = { fetch: async () => (calls++, new Response(JSON.stringify({ accepted: 0, duplicates: 0, refused: [{ index: 0, error: "unit: unknown" }] }))) } as unknown as Fetcher
      expect(await reportSlackAwake({ PLATFORM: platform, INTERNAL_TOKEN: "t" }, b.sql, "agent_a")).toBe(0)
      expect(await reportSlackAwake({ PLATFORM: platform, INTERNAL_TOKEN: "t" }, b.sql, "agent_a")).toBe(0)
      expect(calls).toBe(1)
    })
  })

  it("sends nothing without the platform binding", async () => {
    await inBrain(async (b) => {
      recordSlackSender(b.sql, "msg_1", guest)
      meterSlackTurn(b.sql, "run_1", "msg_1", NOON, NOON + 1_000)
      expect(await reportSlackAwake({}, b.sql, "agent_a")).toBe(0)
    })
  })
})
