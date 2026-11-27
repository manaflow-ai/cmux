import { describe, expect, it } from "vitest"
import { apnsPayload, clean, collapseId, MAX_PAYLOAD_BYTES, notifyLimitKey, parseNotify, type NotifyEvent } from "../src/push.ts"

// Security and correctness review of #24156 (M3, L3, #3, #6, lows, nits).

const MAC = "11111111-1111-4111-8111-111111111111"
const OTHER = "22222222-2222-4222-8222-222222222222"
const base: NotifyEvent = { eventId: "p-1", kind: "question", agent: "Claude", place: "cmux-next", macId: MAC, macName: "Mac mini", sessionId: "s1" }
const bytes = (v: unknown) => new TextEncoder().encode(JSON.stringify(v)).length

describe("review fixes", () => {
  it("a terminal banner says Terminal, never the program's own title (M3)", () => {
    const a = apnsPayload({ ...base, kind: "terminal", title: "Claude needs permission", body: "Allow git push?", workspace: "api" }).aps.alert
    expect(a.title).toBe("Terminal · api")
    expect(a.body).toBe("Claude needs permission: Allow git push?")
    expect(apnsPayload({ ...base, kind: "terminal", title: "Build done", place: undefined }).aps.alert.title).toBe("Terminal")
  })

  it("terminal notifications use their own rate bucket (M3)", () => {
    expect(notifyLimitKey(MAC, "terminal")).toBe(`${MAC}:terminal`)
    expect(notifyLimitKey(MAC, "permission")).toBe(MAC)
    expect(notifyLimitKey(MAC, "question")).toBe(MAC)
  })

  it("a cut text ends with an ellipsis (L3)", () => {
    const c = clean("word ".repeat(100), 60)
    expect(Array.from(c)).toHaveLength(60)
    expect(c.endsWith("…")).toBe(true)
    expect(clean("short", 60)).toBe("short")
    const long: NotifyEvent = { ...base, kind: "permission", title: `rm -rf build ${"x".repeat(180)}`, tail: Array.from({ length: 6 }, () => "😀".repeat(160)) }
    const p = apnsPayload(long)
    expect(bytes(p)).toBeLessThanOrEqual(MAX_PAYLOAD_BYTES)
    if (p.cmuxMobile.title !== long.title) expect(p.cmuxMobile.title!.endsWith("…")).toBe(true)
  })

  it("strips combining-mark floods (nit)", () => {
    expect(clean(`a${"́".repeat(30)}b`, 60)).toBe("á́b")
    expect(clean("é", 60)).toBe("é")
  })

  it("collapses a terminal notification per Mac and ledger id (#3)", () => {
    const a = collapseId({ eventId: "n-9", kind: "terminal", notificationId: "42", macId: MAC })
    const b = collapseId({ eventId: "n-9", kind: "terminal", notificationId: "42", macId: OTHER })
    expect(a).not.toBe(b)
    expect(a.startsWith("term-")).toBe(true)
    expect(collapseId({ eventId: "n-9", kind: "terminal", notificationId: "x".repeat(64), macId: MAC }).length).toBeLessThanOrEqual(64)
  })

  it("drops a bad field or option instead of refusing the push (#6)", () => {
    const r = parseNotify({
      eventId: "p-1",
      kind: "permission",
      permissionId: "has space",
      workspaceId: "ok-1",
      state: "sleeping",
      title: 5,
      options: [
        { id: "allow", label: "Allow once", kind: "allow_once" },
        { id: "bad id/x", label: "Odd", kind: "allow_always" },
        { label: "no id" },
        { id: "reject", label: "Deny", kind: "reject_once" }
      ],
      tail: ["one", 2, "three"]
    })
    expect(typeof r).toBe("object")
    if (typeof r === "string") return
    expect(r.permissionId).toBeUndefined()
    expect(r.workspaceId).toBe("ok-1")
    expect(r.state).toBeUndefined()
    expect(r.title).toBeUndefined()
    expect(r.options!.map((o) => o.id)).toEqual(["allow", "reject"])
    expect(r.tail).toEqual(["one", "three"])
    // Only what names the push stays required.
    expect(parseNotify({ kind: "permission" })).toMatch(/eventId/)
    expect(parseNotify({ eventId: "p-1", kind: "shell" })).toMatch(/kind/)
  })

  it("keeps option descriptions, and drops them first when the payload is too big (low)", () => {
    const r = parseNotify({
      eventId: "p-1",
      kind: "question",
      questions: [{ question: "Which?", multiSelect: false, allowsOther: false, options: [{ label: "A", description: "the first" }, { label: "B" }] }]
    })
    if (typeof r === "string") throw new Error(r)
    expect(r.questions![0]!.options).toEqual([{ label: "A", description: "the first" }, { label: "B" }])
    const big: NotifyEvent = {
      ...base,
      title: "Which?",
      questions: Array.from({ length: 4 }, (_, i) => ({
        question: `Q${i} ${"🙂".repeat(190)}`,
        multiSelect: false,
        allowsOther: false,
        options: Array.from({ length: 6 }, (_, j) => ({ label: `opt ${j} ${"🙂".repeat(50)}`, description: "🙂".repeat(120) }))
      }))
    }
    const p = apnsPayload(big)
    expect(bytes(p)).toBeLessThanOrEqual(MAX_PAYLOAD_BYTES)
  })

  it("always fits 4096 bytes, even with every field full of 4-byte characters (low)", () => {
    const four = (n: number) => "𝕏".repeat(n)
    const worst: NotifyEvent = {
      ...base,
      kind: "permission",
      agent: four(40),
      place: four(60),
      workspace: four(60),
      macName: four(64),
      title: four(200),
      body: four(400),
      tail: Array.from({ length: 6 }, () => four(160)),
      options: Array.from({ length: 6 }, (_, i) => ({ id: `o${i}`, label: four(60), kind: "allow_once" as const }))
    }
    for (const previews of [true, false]) expect(bytes(apnsPayload(worst, { previews }))).toBeLessThanOrEqual(MAX_PAYLOAD_BYTES)
  })
})
