import { describe, expect, it } from "vitest"
import {
  apnsPayload,
  apnsRequest,
  category,
  collapseId,
  parseNotify,
  pushTargets,
  threadId,
  wantedKinds,
  type NotifyEvent
} from "../src/push.ts"
import type { PushRegistration } from "../src/store.ts"
import { call, register, token } from "./helpers.ts"

const HEX = "cd".repeat(32)
const MAC = "11111111-1111-4111-8111-111111111111"
const OTHER = "22222222-2222-4222-8222-222222222222"

const base: NotifyEvent = { eventId: "p-1", kind: "question", agent: "Claude", place: "cmux-next", macId: MAC, macName: "Mac mini", sessionId: "s1" }
const reg = (over: Partial<PushRegistration> = {}): PushRegistration => ({
  deviceId: "d1",
  ownerUserId: "o",
  token: "aa",
  environment: "production",
  topic: "dev.cmux.mobile",
  kinds: ["question", "permission", "completed", "failed", "chief", "terminal"],
  mutedMacs: [],
  previews: true,
  updatedAt: "",
  ...over
})
const bytes = (v: unknown) => new TextEncoder().encode(JSON.stringify(v)).length

describe("notify body (0.13.0 fields)", () => {
  it("cleans and cuts every new field to its limit", () => {
    const r = parseNotify({
      eventId: "p-1",
      kind: "question",
      agent: "Claude",
      place: "repo",
      workspace: "w".repeat(80),
      workspaceId: "ws_1",
      tabId: "s7",
      sessionId: "s1",
      permissionId: "perm.1",
      title: "Which\u0000 branch?" + "x".repeat(300),
      body: "b".repeat(500),
      options: Array.from({ length: 9 }, (_, i) => ({ id: `o${i}`, label: "L".repeat(80), kind: i === 0 ? "allow_once" : "bogus" })),
      questions: Array.from({ length: 6 }, () => ({
        question: "q".repeat(300),
        header: "h".repeat(40),
        multiSelect: true,
        allowsOther: false,
        options: Array.from({ length: 8 }, () => ({ label: "o".repeat(70) }))
      })),
      tail: Array.from({ length: 9 }, (_, i) => `line ${i} ` + "t".repeat(200)),
      state: "waiting"
    })
    if (typeof r === "string") throw new Error(r)
    expect(r.workspace).toHaveLength(60)
    expect(r.title!.startsWith("Which branch?")).toBe(true)
    expect(Array.from(r.title!)).toHaveLength(200)
    expect(r.body).toHaveLength(400)
    expect(r.options).toHaveLength(6)
    expect(r.options![0]).toEqual({ id: "o0", label: `${"L".repeat(59)}…`, kind: "allow_once" })
    expect(r.options![1]!.kind).toBeUndefined()
    expect(r.questions).toHaveLength(4)
    expect(r.questions![0]!.question).toHaveLength(200)
    expect(r.questions![0]!.header).toHaveLength(30)
    expect(r.questions![0]!.options).toHaveLength(6)
    expect(r.questions![0]!.options[0]!.label).toHaveLength(60)
    // The last six lines, each at most 160.
    expect(r.tail).toHaveLength(6)
    expect(r.tail![0]!.startsWith("line 3")).toBe(true)
    expect(r.tail![5]).toHaveLength(160)
    expect(r.state).toBe("waiting")
  })

  it("refuses only a push it can't name; drops other malformed fields (review #6)", () => {
    const ok = { eventId: "e1", kind: "terminal" }
    expect(typeof parseNotify(ok)).toBe("object")
    expect(parseNotify({ ...ok, kind: "shell" })).toMatch(/kind/)
    expect(parseNotify({ ...ok, eventId: "has space" })).toMatch(/eventId/)
    for (const bad of [
      { permissionId: "has space" },
      { notificationId: "x".repeat(65) },
      { conversationId: 7 },
      { state: "sleeping" },
      { options: "yes" },
      { options: [{ label: "no id" }] },
      { questions: [{ options: [] }] },
      { tail: [1, 2] },
      { title: 5 }
    ]) {
      const r = parseNotify({ ...ok, ...bad })
      expect(typeof r, JSON.stringify(bad)).toBe("object")
    }
  })
})

describe("v2 APNs payload", () => {
  it("writes the question, its Mac and the routing fields", () => {
    const e: NotifyEvent = {
      ...base,
      workspace: "cmux-next",
      workspaceId: "ws_1",
      tabId: "t1",
      permissionId: "perm1",
      title: "Which branch?",
      questions: [{ question: "Which branch?", multiSelect: false, allowsOther: true, options: [{ label: "main" }, { label: "dev" }] }],
      tail: ["Looking at branches"],
      state: "waiting"
    }
    const p = apnsPayload(e)
    expect(p.aps.alert).toEqual({ title: "Claude asks", subtitle: "cmux-next · Mac mini", body: "Which branch?" })
    expect(p.aps["mutable-content"]).toBe(1)
    expect(p.aps["thread-id"]).toBe(`${MAC}:s1`)
    expect(p.aps["target-content-id"]).toBe(`${MAC}:s1`)
    expect(p.aps.category).toBe("CMUX_MOBILE_QUESTION")
    expect(p.aps["interruption-level"]).toBe("time-sensitive")
    expect(p.cmuxMobile).toMatchObject({
      v: 2,
      mac: MAC,
      macName: "Mac mini",
      kind: "question",
      eventId: "p-1",
      agent: "Claude",
      place: "cmux-next",
      workspace: "cmux-next",
      workspaceId: "ws_1",
      tabId: "t1",
      sessionId: "s1",
      permissionId: "perm1",
      title: "Which branch?",
      tail: ["Looking at branches"],
      state: "waiting",
      previews: true
    })
    expect(p.cmuxMobile.questions).toEqual(e.questions)
  })

  it("writes each kind's banner", () => {
    const alert = (e: Partial<NotifyEvent>) => apnsPayload({ ...base, ...e } as NotifyEvent).aps.alert
    expect(alert({ kind: "permission", title: "rm -rf build" })).toEqual({ title: "Claude needs permission", subtitle: "cmux-next · Mac mini", body: "rm -rf build" })
    expect(alert({ kind: "completed", tail: ["first", "All tests pass"] })).toEqual({ title: "Claude finished", subtitle: "cmux-next · Mac mini", body: "All tests pass" })
    expect(alert({ kind: "failed", body: "rate limited", tail: ["x"] }).body).toBe("rate limited")
    expect(alert({ kind: "failed", tail: ["boom"] })).toMatchObject({ title: "Claude stopped with an error", body: "boom" })
    expect(alert({ kind: "chief", body: "Done: 3 PRs merged" })).toMatchObject({ title: "Chief", body: "Done: 3 PRs merged" })
    expect(alert({ kind: "terminal", title: "Build done", body: "exit 0", workspace: "api" })).toEqual({ title: "Terminal · api", subtitle: "api · Mac mini", body: "Build done: exit 0" })
    // No content (a 0.11 host): the 0.11 banner, unchanged.
    expect(alert({ kind: "permission" })).toEqual({ title: "Claude needs permission", body: "cmux-next · Mac mini" })
  })

  it("hides content when the phone turned previews off, but keeps what the buttons need", () => {
    const e: NotifyEvent = { ...base, kind: "permission", title: "rm -rf build", options: [{ id: "a", label: "Allow once", kind: "allow_once" }] }
    const p = apnsPayload(e, { previews: false })
    expect(p.aps.alert).toEqual({ title: "Claude needs permission", body: "Mac mini" })
    expect(p.cmuxMobile).toMatchObject({ previews: false, title: "rm -rf build", options: e.options })
    const r = apnsRequest(reg({ previews: false }), e, "tok", Date.now())
    return r.json().then((body: any) => expect(body.aps.alert.title).toBe("Claude needs permission"))
  })

  it("picks the category", () => {
    const q = (questions: NotifyEvent["questions"]) => category({ ...base, ...(questions ? { questions } : {}) })
    const opts = (n: number) => Array.from({ length: n }, (_, i) => ({ label: `o${i}` }))
    expect(q([{ question: "?", multiSelect: false, allowsOther: false, options: opts(4) }])).toBe("CMUX_MOBILE_QUESTION")
    expect(q([{ question: "?", multiSelect: false, allowsOther: true, options: opts(2) }])).toBe("CMUX_MOBILE_QUESTION")
    expect(q([{ question: "?", multiSelect: false, allowsOther: false, options: opts(5) }])).toBe("CMUX_MOBILE_QUESTION_FORM")
    expect(q([{ question: "?", multiSelect: true, allowsOther: false, options: opts(2) }])).toBe("CMUX_MOBILE_QUESTION_FORM")
    expect(q([{ question: "?", multiSelect: false, allowsOther: false, options: opts(2) }, { question: "?", multiSelect: false, allowsOther: false, options: opts(2) }])).toBe(
      "CMUX_MOBILE_QUESTION_FORM"
    )
    expect(q([{ question: "?", multiSelect: false, allowsOther: true, options: [] }])).toBe("CMUX_MOBILE_QUESTION_FORM")
    expect(q(undefined)).toBe("CMUX_MOBILE_QUESTION_FORM")
    for (const kind of ["permission", "completed", "failed", "chief", "terminal"] as const)
      expect(category({ ...base, kind })).toBe(`CMUX_MOBILE_${kind.toUpperCase()}`)
  })

  it("threads per session, terminal tab, Chief or Mac", () => {
    expect(threadId(base)).toBe(`${MAC}:s1`)
    const { sessionId: _, ...noSession } = base
    expect(threadId({ ...noSession, kind: "terminal", tabId: "s4" })).toBe(`${MAC}:s4`)
    expect(threadId({ ...noSession, kind: "chief", conversationId: "home1" })).toBe(`${MAC}:chief:home1`)
    expect(threadId(noSession)).toBe(MAC)
  })

  it("collapses a terminal notification per ledger id and keeps the turn rules", () => {
    expect(collapseId({ eventId: "n-9", kind: "terminal", notificationId: "42", macId: MAC })).toMatch(/^term-[0-9a-f]{16}-42$/)
    expect(collapseId({ eventId: "n-9", kind: "terminal", macId: MAC })).toBe("n-9")
    expect(collapseId({ eventId: "t-s1-t9", kind: "completed", sessionId: "s1" })).toBe("turn-s1")
    expect(collapseId({ eventId: "p-1", kind: "question", sessionId: "s1" })).toBe("p-1")
  })

  it("fits 4096 bytes: tail first, then the title, then the questions", () => {
    const question = (text: string, label: string) => ({ question: text, header: "H".repeat(30), multiSelect: false, allowsOther: true, options: Array.from({ length: 6 }, () => ({ label })) })
    const big: NotifyEvent = {
      ...base,
      workspace: "w".repeat(60),
      title: "T".repeat(200),
      body: "B".repeat(100),
      questions: Array.from({ length: 4 }, () => question("Q".repeat(100), "o".repeat(40))),
      tail: Array.from({ length: 6 }, () => "😀".repeat(160))
    }
    const p = apnsPayload(big)
    expect(bytes(p)).toBeLessThanOrEqual(4096)
    // The questions fit once the tail is gone, so only the tail was cut.
    expect((p.cmuxMobile.tail ?? []).length).toBeLessThan(6)
    expect(p.cmuxMobile.questions).toEqual(big.questions)
    expect(p.aps.category).toBe("CMUX_MOBILE_QUESTION_FORM")
    // Too large even without a tail and with a short title: the questions go and it stays a form.
    const huge: NotifyEvent = { ...big, questions: Array.from({ length: 4 }, () => question("😀".repeat(200), "😀".repeat(60))) }
    const h = apnsPayload(huge)
    expect(bytes(h)).toBeLessThanOrEqual(4096)
    expect(h.cmuxMobile.questions).toBeUndefined()
    expect(h.cmuxMobile.tail).toBeUndefined()
    expect(Array.from(h.cmuxMobile.title!).length).toBeLessThan(200)
    expect(h.aps.category).toBe("CMUX_MOBILE_QUESTION_FORM")
    // Small payloads keep everything.
    expect(apnsPayload({ ...base, tail: ["a", "b"] }).cmuxMobile.tail).toEqual(["a", "b"])
  })
})

describe("targets and wants", () => {
  it("skips phones that muted this Mac and reports the kinds still wanted", () => {
    const regs = [
      reg({ deviceId: "a", kinds: ["question", "permission"] }),
      reg({ deviceId: "b", kinds: ["question", "terminal"], mutedMacs: [MAC] }),
      reg({ deviceId: "c", kinds: ["completed"], mutedMacs: [OTHER] })
    ]
    expect(pushTargets(regs, MAC, "question").map((r) => r.deviceId)).toEqual(["a"])
    expect(pushTargets(regs, MAC, "terminal")).toEqual([])
    expect(pushTargets(regs, OTHER, "terminal").map((r) => r.deviceId)).toEqual(["b"])
    expect(wantedKinds(regs, MAC)).toEqual(["question", "permission", "completed"])
    expect(wantedKinds(regs, OTHER)).toEqual(["question", "permission", "terminal"])
  })
})

describe("push registration settings (HTTP)", () => {
  it("stores and echoes mutedMacs and previews, and validates them", async () => {
    const t = await token("rita")
    const phone = await register(t, "phone", "personal-rita")
    const put = (body: Record<string, unknown>) => call("PUT", `/v1/devices/${phone}/push`, t, { token: HEX, environment: "sandbox", topic: "dev.cmux.mobile", ...body })
    const plain = await put({})
    expect(plain.json.push).toMatchObject({ kinds: ["question", "permission", "completed", "failed", "chief", "terminal"], mutedMacs: [], previews: true })
    const set = await put({ kinds: ["question", "terminal"], mutedMacs: [MAC.toUpperCase(), MAC], previews: false })
    expect(set).toMatchObject({ status: 200, json: { push: { kinds: ["question", "terminal"], mutedMacs: [MAC], previews: false } } })
    expect((await put({ mutedMacs: "all" })).status).toBe(400)
    expect((await put({ mutedMacs: ["not-a-uuid"] })).status).toBe(400)
    expect((await put({ mutedMacs: Array.from({ length: 65 }, () => crypto.randomUUID()) })).status).toBe(400)
    expect((await put({ previews: "no" })).status).toBe(400)
  })

  it("notify answers the wanted kinds and validates the new fields", async () => {
    const t = await token("sam")
    const mac = await register(t, "mac", "personal-sam")
    const phone = await register(t, "phone", "personal-sam")
    await call("PUT", `/v1/devices/${phone}/push`, t, { token: HEX, environment: "sandbox", topic: "dev.cmux.mobile", kinds: ["question", "terminal"] })
    const r = await call("POST", `/v1/devices/${mac}/notify`, t, { eventId: "n-1", kind: "terminal", title: "Build done", notificationId: "7" })
    expect(r).toMatchObject({ status: 200, json: { configured: false, sent: 0, wants: ["question", "terminal"] } })
    expect((await call("POST", `/v1/devices/${mac}/notify`, t, { eventId: "n-2", kind: "terminal", state: "nope" })).status).toBe(200)
    await call("PUT", `/v1/devices/${phone}/push`, t, { token: HEX, environment: "sandbox", topic: "dev.cmux.mobile", mutedMacs: [mac] })
    expect((await call("POST", `/v1/devices/${mac}/notify`, t, { eventId: "n-3", kind: "terminal" })).json.wants).toEqual([])
  })
})
