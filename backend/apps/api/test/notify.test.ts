import { env } from "cloudflare:workers"
import { runInDurableObject as runIn } from "cloudflare:test"
import { idFactory, type Principal } from "@cmux/ownership"
import type { FeedItem, PushPrefs } from "@cmux/protocol"
import { exportPKCS8, generateKeyPair } from "jose"
import { describe, expect, it } from "vitest"
import { userDomain, type UserState } from "../src/domains/user.ts"
import { ACTIVITY_TTL_MS, MAX_ACTIVITIES_PER_INSTALL, notifyTargetsOf, type NotifyActivityTarget } from "../src/domains/user-notify.ts"
import { activitySignature, dismissDue, feedBadge, needsUser } from "../src/domains/feed-notify.ts"
import { initialFeedState, type FeedState } from "../src/domains/feed-state.ts"
import { apnsMessageRequest, apnsPayload, dismissMessage, sendFeedItem } from "../src/push/apns.ts"
import { activityState, liveActivityRequest } from "../src/push/live-activity.ts"
import { feedCategory, interruptionLevel, notificationKindOf, wantsItem } from "../src/push/notify-kind.ts"
import { runFeedPushEffects } from "../src/feed-push-effects.ts"

/** plans/cmux-next/ios-next/c7-notify.md: per-device prefs, Live Activities, dismiss and badge. */
const U = "user_aaaaaaaaaaaaaaaaaaaa"
const phone: Principal = { identity: "inst_ios00000000000000000", kind: "install", user: U, install: "inst_ios00000000000000000" }
const ipad: Principal = { ...phone, identity: "inst_pad00000000000000000", install: "inst_pad00000000000000000" }
const cli: Principal = { ...phone, identity: "inst_cli00000000000000000", install: "inst_cli00000000000000000" }
const session: Principal = { identity: `session:${U}`, kind: "session", user: U }
const tok = (c: string) => c.repeat(64)

let n = 0
const reduce = (s: UserState, p: Principal, op: string, params: unknown, now = 1_000 + n) => {
  const tx = `t${n++}`
  return userDomain.reduce(s, op, params, { principal: p, now, tx, newId: idFactory(tx) })
}
const inst = (kind: string, id: string) => ({ id, kind, revoked_at: null, grant: `grant_${id}` }) as unknown as UserState["installs"][string]
const seed = (): UserState => ({
  ...userDomain.initial(),
  installs: { [phone.install!]: inst("ios", phone.install!), [ipad.install!]: inst("ios", ipad.install!), [cli.install!]: inst("cli", cli.install!) },
  push_targets: { [tok("a")]: { token: tok("a"), topic: "dev.cmux.ios", environment: "development", install: phone.install!, device_name: "iPhone", registered_at: 1 } }
})
const ok = (r: ReturnType<typeof reduce>) => {
  if (!r.ok) throw new Error(`${r.code}: ${r.message}`)
  return r.state
}
const prefs = (over: Partial<PushPrefs> = {}): PushPrefs => ({ kinds: ["permission", "question", "planApproval", "finished", "terminalAlert"], sound: true, time_sensitive: true, ...over })

describe("push.prefs.set (UserDO)", () => {
  it("stores an iOS install's preferences, sorted and deduped; others are refused", () => {
    const s = ok(reduce(seed(), phone, "push.prefs.set", { kinds: ["question", "permission", "question"], sound: false, time_sensitive: false }))
    expect(s.push_prefs?.[phone.install!]).toEqual({ kinds: ["permission", "question"], sound: false, time_sensitive: false })
    expect(reduce(seed(), cli, "push.prefs.set", prefs())).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(reduce(seed(), session, "push.prefs.set", prefs())).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(reduce(seed(), phone, "push.prefs.set", { kinds: ["bogus"], sound: true, time_sensitive: true })).toMatchObject({ ok: false })
    expect(reduce(s, phone, "push.prefs.set", { kinds: ["permission", "question"], sound: false, time_sensitive: false })).toMatchObject({ ok: true, changed: false })
  })

  it("rides along with the install's push target and goes when the install is revoked", () => {
    let s = ok(reduce(seed(), phone, "push.prefs.set", prefs({ sound: false })))
    expect(notifyTargetsOf(s, 2_000).push[0]?.prefs?.sound).toBe(false)
    s = ok(reduce(s, session, "install.revoke", { install: phone.install }))
    expect(s.push_prefs?.[phone.install!]).toBeUndefined()
    expect(notifyTargetsOf(s, 2_000).push).toEqual([])
  })
})

describe("notify.activity.* (UserDO)", () => {
  const register = (s: UserState, p: Principal, activity: string, now: number, token = tok("b")) =>
    reduce(s, p, "notify.activity.register", { activity, push_token: token, subject: { host: "h_mac", task: "task_1" }, title: "Fix login", started_at: 500 }, now)

  it("registers, replaces the token, joins the install's push target and ends", () => {
    let s = ok(register(seed(), phone, "act_one", 1_000))
    s = ok(register(s, phone, "act_one", 2_000, tok("c")))
    const targets = notifyTargetsOf(s, 3_000).activities
    expect(targets).toHaveLength(1)
    expect(targets[0]).toMatchObject({ activity: "act_one", push_token: tok("c"), topic: "dev.cmux.ios", environment: "development", title: "Fix login", started_at: 500 })
    expect(register(s, ipad, "act_one", 3_000)).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(reduce(s, ipad, "notify.activity.end", { activity: "act_one" })).toMatchObject({ ok: false, code: "auth.forbidden" })
    s = ok(reduce(s, phone, "notify.activity.end", { activity: "act_one" }))
    expect(notifyTargetsOf(s, 3_000).activities).toEqual([])
    expect(reduce(s, phone, "notify.activity.end", { activity: "act_one" })).toMatchObject({ ok: true, changed: false })
  })

  it("drops registrations after the ActivityKit lifetime and keeps a per-install cap", () => {
    let s = ok(register(seed(), phone, "act_old", 1_000))
    expect(notifyTargetsOf(s, 1_000 + ACTIVITY_TTL_MS).activities).toEqual([])
    for (let i = 0; i < MAX_ACTIVITIES_PER_INSTALL + 2; i++) s = ok(register(s, phone, `act_n${i}`, 2_000 + i))
    const left = Object.keys(s.activities ?? {})
    expect(left).toHaveLength(MAX_ACTIVITIES_PER_INSTALL)
    expect(left).not.toContain("act_old")
    expect(left).toContain(`act_n${MAX_ACTIVITIES_PER_INSTALL + 1}`)
  })

  it("an activity without a push target is not sent, and revoke drops it", () => {
    let s = ok(register(seed(), ipad, "act_pad", 1_000))
    expect(notifyTargetsOf(s, 1_500).activities).toEqual([])
    s = ok(register(s, phone, "act_ph", 1_000))
    s = ok(reduce(s, session, "install.revoke", { install: phone.install }))
    expect(Object.keys(s.activities ?? {})).toEqual(["act_pad"])
  })
})

const item = (over: Partial<FeedItem> = {}): FeedItem =>
  ({
    id: "fi_aaaaaaaaaaaaaaaaaaaa", home: "cloud", type: "request", kind: "approve", title: "Run npm run build?", body: "", priority: "high",
    dedupe_key: null, thread: null, context: {}, attachments: [], actions: [], open: null,
    poster: { kind: "harness", scope: "inst:x", label: "api", harness: "Claude Code" }, state: "open", answer: null, cancel: null, needs_mac: false,
    expires_at: 10_000_000, read_at: null, seen_at: null, archived_at: null, snoozed_until: null, push_due_at: null, pushed_at: null,
    count: 1, order: 1, revision: 1, created_at: 1, updated_at: 1, closed_at: null, ...over
  }) as FeedItem

describe("presentation per device", () => {
  it("maps kinds like the iPhone (CmuxFeedPushCore NotificationKind)", () => {
    expect(notificationKindOf(item())).toBe("permission")
    for (const kind of ["question", "choice", "confirm", "input", "file"]) expect(notificationKindOf(item({ kind }))).toBe("question")
    expect(notificationKindOf(item({ kind: "review" }))).toBe("planApproval")
    expect(notificationKindOf(item({ type: "notice", kind: "notice" }))).toBe("finished")
    expect(notificationKindOf(item({ type: "notice", kind: "notice", poster: { kind: "system", scope: "s", label: "cmux" }, context: { terminal: "term_1" } }))).toBe("terminalAlert")
    expect(notificationKindOf(item({ kind: "sign-in" }))).toBeNull()
  })

  it("picks the session-scope and plan categories", () => {
    expect(feedCategory(item({ prompt: { scopes: ["once"] } }))).toBe("FEED_APPROVE")
    expect(feedCategory(item({ prompt: { scopes: ["once", "session"] } }))).toBe("FEED_APPROVE_SESSION")
    expect(feedCategory(item({ kind: "review", prompt: { subject: "plan" } }))).toBe("FEED_PLAN")
    expect(feedCategory(item({ kind: "review", prompt: { subject: "diff" } }))).toBe("FEED_REVIEW")
    expect(feedCategory(item({ type: "notice", kind: "notice" }))).toBe("FEED_NOTICE")
  })

  it("follows the device's kinds, sound and time-sensitive choice", () => {
    expect(wantsItem(prefs({ kinds: ["finished"] }), item())).toBe(false)
    expect(wantsItem(undefined, item())).toBe(true)
    expect(wantsItem(prefs({ kinds: [] }), item({ kind: "sign-in" }))).toBe(true)
    expect(interruptionLevel(undefined, item())).toBe("time-sensitive")
    expect(interruptionLevel(prefs({ time_sensitive: false }), item())).toBeUndefined()
    expect(interruptionLevel(prefs({ time_sensitive: false }), item({ priority: "urgent" }))).toBe("time-sensitive")
    expect(interruptionLevel(undefined, item({ type: "notice", kind: "notice" }))).toBeUndefined()
    const quiet = apnsPayload(item({ prompt: { scopes: ["once", "session"] } }), { badge: 3, prefs: prefs({ sound: false, time_sensitive: false }) })
    expect(quiet.aps).toMatchObject({ badge: 3, category: "FEED_APPROVE_SESSION", "mutable-content": 1 })
    expect(quiet.aps).not.toHaveProperty("sound")
    expect(quiet.aps).not.toHaveProperty("interruption-level")
    expect(quiet.cmux).toMatchObject({ scopes: ["once", "session"], notify_kind: "permission", expires_at: 10_000_000 })
  })

  it("sends each device only the kinds it wants, shaped by its own prefs", async () => {
    const pair = await generateKeyPair("ES256", { extractable: true })
    const config = { keyP8: await exportPKCS8(pair.privateKey), keyId: "KEYN", teamId: "TEAMN" }
    const base = { topic: "dev.cmux.ios", environment: "production" as const, device_name: "x", registered_at: 1 }
    const bodies = new Map<string, any>()
    const fetcher = (async (req: Request) => {
      bodies.set(req.url.split("/").pop()!, await req.json())
      return new Response(null, { status: 200 })
    }) as typeof fetch
    const r = await sendFeedItem(config, [
      { ...base, token: tok("1"), install: "i1" },
      { ...base, token: tok("2"), install: "i2", prefs: prefs({ kinds: ["finished"] }) },
      { ...base, token: tok("3"), install: "i3", prefs: prefs({ sound: false }) }
    ], item(), 2, 1_000, fetcher)
    expect(r.map((x) => x.token).sort()).toEqual([tok("1"), tok("3")])
    expect(bodies.get(tok("1")).aps).toMatchObject({ sound: "default", badge: 2 })
    expect(bodies.get(tok("3")).aps.sound).toBeUndefined()
  })
})

const feed = (items: Array<FeedItem>): FeedState => ({ ...initialFeedState(), user: U, items: Object.fromEntries(items.map((i) => [i.id, i])) })
const id = (c: string) => `fi_${c.repeat(20)}`

describe("dismiss and badge (FeedDO)", () => {
  it("needs the user while a request is open or a notice unread", () => {
    expect(needsUser(item())).toBe(true)
    expect(needsUser(item({ state: "answered" }))).toBe(false)
    expect(needsUser(item({ type: "notice", kind: "notice" }))).toBe(true)
    expect(needsUser(item({ type: "notice", kind: "notice", read_at: 5 }))).toBe(false)
    expect(needsUser(item({ type: "notice", kind: "notice", archived_at: 5 }))).toBe(false)
  })

  it("badges open requests and unread notices; dismisses pushed items that closed, once", () => {
    const s = feed([
      item({ id: id("a"), pushed_at: 10 }),
      item({ id: id("b"), pushed_at: 10, state: "answered" }),
      item({ id: id("c"), state: "cancelled" }),
      item({ id: id("d"), type: "notice", kind: "notice", pushed_at: 10, read_at: 20 }),
      item({ id: id("e"), type: "notice", kind: "notice" })
    ])
    expect(feedBadge(s, 100)).toBe(2)
    expect(dismissDue(s, new Set())).toEqual([id("b"), id("d")])
    expect(dismissDue(s, new Set([id("b")]))).toEqual([id("d")])
  })

  it("builds a background push without a collapse id", async () => {
    const req = apnsMessageRequest({ token: tok("d"), topic: "dev.cmux.ios", environment: "production", install: "i", device_name: "x", registered_at: 1 }, dismissMessage([id("b")], 4, 1_000), "jwt")
    expect(req.headers.get("apns-push-type")).toBe("background")
    expect(req.headers.get("apns-priority")).toBe("5")
    expect(req.headers.get("apns-collapse-id")).toBeNull()
    expect(await req.json()).toEqual({ aps: { "content-available": 1 }, cmux: { dismiss: [id("b")], badge: 4 } })
  })
})

const activity = (over: Partial<NotifyActivityTarget> = {}): NotifyActivityTarget => ({
  activity: "act_one", install: "i", push_token: tok("9"), subject: { host: "h_mac", task: "task_1" }, title: "Fix login",
  started_at: 1_000_000, registered_at: 1, topic: "dev.cmux.ios", environment: "development", ...over
})

describe("Live Activity updates", () => {
  it("shows needs-input for the oldest matching open request, else running", () => {
    const waiting = item({ id: id("w"), title: "Allow npm install?", context: { host: "h_mac", task: "task_1" }, created_at: 5 })
    const other = item({ id: id("o"), context: { host: "h_other", task: "task_1" } })
    expect(activityState(activity(), [other, waiting])).toEqual({ phase: "needs_input", title: "Allow npm install?", started: 1_000, item: id("w") })
    expect(activityState(activity(), [other])).toEqual({ phase: "running", title: "Fix login", started: 1_000 })
    expect(activityState(activity({ subject: { host: "h_mac", terminal: "term_1" } }), [item({ context: { terminal: "term_1" } })]).phase).toBe("needs_input")
  })

  it("sends a liveactivity push to the activity token on the derived topic", async () => {
    const req = liveActivityRequest(activity(), { phase: "needs_input", title: "Allow?", started: 1_000, item: id("w") }, "jwt", 2_000_000)
    expect(new URL(req.url).pathname).toBe(`/3/device/${tok("9")}`)
    expect(new URL(req.url).host).toBe("api.sandbox.push.apple.com")
    expect(req.headers.get("apns-topic")).toBe("dev.cmux.ios.push-type.liveactivity")
    expect(req.headers.get("apns-push-type")).toBe("liveactivity")
    const body = (await req.json()) as any
    expect(body.aps).toMatchObject({ event: "update", timestamp: 2_000, "content-state": { phase: "needs_input", item: id("w") } })
    expect(body.aps.alert).toBeDefined()
  })

  it("only open requests with a task or terminal change the signature", () => {
    const a = feed([item({ id: id("a"), context: { task: "task_1" } }), item({ id: id("b") })])
    const b = feed([item({ id: id("a"), context: { task: "task_1" } }), item({ id: id("b"), state: "answered" })])
    expect(activitySignature(a)).toBe(activitySignature(b))
    expect(activitySignature(feed([]))).not.toBe(activitySignature(a))
  })
})

const runInDurableObject = runIn as unknown as <T>(stub: unknown, fn: (instance: any) => Promise<T>) => Promise<T>
const testEnv = env as unknown as { FEED_DO: DurableObjectNamespace }

describe("after-commit effects (FeedDO storage)", { timeout: 60_000 }, () => {
  it("dismisses once across runs and sends one activity update per change", async () => {
    const pair = await generateKeyPair("ES256", { extractable: true })
    const config = { keyP8: await exportPKCS8(pair.privateKey), keyId: "KEYE", teamId: "TEAME" }
    const sent: Array<{ type: string | null; body: any }> = []
    const fetcher = (async (req: Request) => {
      sent.push({ type: req.headers.get("apns-push-type"), body: await req.json() })
      return new Response(null, { status: 200 })
    }) as typeof fetch
    const targets = async () => ({
      push: [{ token: tok("d"), topic: "dev.cmux.ios", environment: "production" as const, install: "i", device_name: "x", registered_at: 1 }],
      activities: [activity()]
    })
    const stub = testEnv.FEED_DO.get(testEnv.FEED_DO.idFromName("user_notifyeffects000000"))
    await runInDurableObject(stub, async (i) => {
      const run = (state: FeedState) => runFeedPushEffects({ sql: i.ctx.storage.sql, state, config, targets, dropTarget: async () => {}, now: 5_000, fetcher })
      const waiting = item({ id: id("w"), context: { host: "h_mac", task: "task_1" } })
      await run(feed([waiting, item({ id: id("b"), pushed_at: 1, state: "answered" })]))
      expect(sent.map((s) => s.type)).toEqual(["background", "liveactivity"])
      expect(sent[0]!.body.cmux).toEqual({ dismiss: [id("b")], badge: 1 })
      expect(sent[1]!.body.aps["content-state"]).toMatchObject({ phase: "needs_input", item: id("w") })
      // Same state again: nothing new.
      await run(feed([waiting, item({ id: id("b"), pushed_at: 1, state: "answered" })]))
      expect(sent).toHaveLength(2)
      // The request is answered: the activity goes back to running.
      await run(feed([{ ...waiting, state: "answered" }, item({ id: id("b"), pushed_at: 1, state: "answered" })]))
      expect(sent.map((s) => s.type)).toEqual(["background", "liveactivity", "liveactivity"])
      expect(sent[2]!.body.aps["content-state"]).toMatchObject({ phase: "running", title: "Fix login" })
    })
  })
})
