import { describe, expect, it } from "vitest"
import { MAX_INSTALL_POSTS_PER_MINUTE, MAX_ITEM_BYTES, MAX_ITEMS, MAX_OPEN_REQUESTS, MAX_POSTS_PER_MINUTE, MAX_STATE_BYTES, RETENTION_MS, jsonBytes } from "../src/domains/feed-state.ts"
import { feedCounts, visibleTo } from "../src/domains/feed.ts"
import { listItems } from "../src/domains/feed-query.ts"
import { agentA, agentB, approvePrompt, choicePrompt, daemon, driver, mac, phone, session, stranger, system, vm } from "./feed-harness.ts"

const notice = (title: string, extra: Record<string, unknown> = {}) => ({ type: "notice", kind: "notice", title, ...extra })
const approve = (extra: Record<string, unknown> = {}) => ({ type: "request", kind: "approve", title: "Claude Code needs permission", prompt: approvePrompt, ...extra })

describe("feed.post", () => {
  it("creates notices and requests with owner-assigned ids and per-kind defaults", () => {
    const f = driver()
    const n = f.do(agentA, "feed.post", notice("Build finished"))
    expect(n.deduped).toBe(false)
    expect(n.item).toMatchObject({ type: "notice", kind: "notice", priority: "normal", state: "open", home: "cloud", count: 1, needs_mac: false })
    expect(n.item.id).toMatch(/^fi_[a-z0-9]{20}$/)
    expect(n.item.poster).toMatchObject({ kind: "agent", scope: "inst:inst_dmn00000000000000000/agent:agent_a", agent: "agent_a" })
    expect(n.item.expires_at).toBe(f.now + 7 * 24 * 3600_000)
    const r = f.do(agentA, "feed.post", { type: "request", kind: "passkey", title: "Approve the passkey", prompt: { origin: "https://github.com", ceremony: "get", browser_tab: "tab_1", reason: "sign in" } })
    expect(r.item).toMatchObject({ priority: "high", needs_mac: true, expires_at: f.now + 24 * 3600_000, push_due_at: f.now + 20_000 })
  })

  it("validates the shape of notices, requests, prompts and action answers", () => {
    const f = driver()
    expect(f.try(agentA, "feed.post", { ...notice("x"), prompt: {} })).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(f.try(agentA, "feed.post", { type: "request", kind: "notice", title: "x" })).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(f.try(agentA, "feed.post", { type: "notice", kind: "approve", title: "x" })).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(f.try(agentA, "feed.post", approve({ prompt: { action: { type: "command" } } }))).toMatchObject({ ok: false })
    expect(f.try(agentA, "feed.post", { type: "request", kind: "choice", title: "x", prompt: { questions: [{ id: "a", question: "q", options: [{ id: "o", label: "o" }, { id: "o", label: "p" }], multi: false, allow_other: false }] } })).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(f.try(agentA, "feed.post", { type: "request", kind: "x-acme.deploy", title: "x" })).toMatchObject({ ok: false, message: expect.stringMatching(/answer_schema/) })
    expect(f.try(agentA, "feed.post", { type: "request", kind: "question", title: "x", prompt: { question: "q" }, answer_schema: { type: "object" } })).toMatchObject({ ok: false })
    expect(f.try(agentA, "feed.post", { type: "request", kind: "input", title: "x", prompt: { schema: { type: "object", properties: { n: { type: "object" } } } } })).toMatchObject({ ok: false })
    expect(f.try(agentA, "feed.post", approve({ actions: [{ id: "a", label: "Allow", answer: { decision: "allow", scope: "always" } }] }))).toMatchObject({ ok: false, message: expect.stringMatching(/not offered/) })
    expect(f.try(agentA, "feed.post", approve({ actions: [{ id: "a", label: "Allow", answer: { decision: "allow", scope: "once" } }] }))).toMatchObject({ ok: true })
    expect(f.try(agentA, "feed.post", { type: "request", kind: "x-acme.deploy", title: "Deploy?", prompt: { env: "prod" }, answer_schema: { type: "object", properties: { go: { type: "boolean" } }, required: ["go"] } })).toMatchObject({ ok: true })
  })

  it("dedupes within the poster scope: notices coalesce, requests reattach", () => {
    const f = driver()
    const a = f.do(agentA, "feed.post", notice("Tests failed", { dedupe_key: "ci" }))
    f.do(mac, "feed.read", { items: [a.item.id] }, "user")
    f.advance(1000)
    const b = f.do(agentA, "feed.post", notice("Tests failed again", { dedupe_key: "ci" }))
    expect(b).toMatchObject({ deduped: true, item: { id: a.item.id, count: 2, title: "Tests failed again", read_at: null } })
    // Another agent's same key is its own item.
    expect(f.do(agentB, "feed.post", notice("Tests failed", { dedupe_key: "ci" })).item.id).not.toBe(a.item.id)
    const r1 = f.do(agentA, "feed.post", approve({ dedupe_key: "claude-code:s1:abc" }))
    const r2 = f.try(agentA, "feed.post", approve({ dedupe_key: "claude-code:s1:abc", title: "changed" }))
    expect(r2).toMatchObject({ ok: true, changed: false, value: { deduped: true, item: { id: r1.item.id, title: "Claude Code needs permission" } } })
    // Once answered, the key is free again.
    f.do(mac, "feed.answer", { item: r1.item.id, answer: { decision: "deny" } }, "user")
    expect(f.do(agentA, "feed.post", approve({ dedupe_key: "claude-code:s1:abc" })).item.id).not.toBe(r1.item.id)
  })

  it("rate-limits each poster scope per minute and caps open requests", () => {
    const f = driver()
    for (let i = 0; i < MAX_POSTS_PER_MINUTE; i++) f.do(agentA, "feed.post", notice(`n${i}`))
    expect(f.try(agentA, "feed.post", notice("one too many"))).toMatchObject({ ok: false, code: "feed.rate_limited", retryable: true })
    expect(f.try(agentB, "feed.post", notice("other scope"))).toMatchObject({ ok: true })
    f.advance(60_000)
    expect(f.try(agentA, "feed.post", notice("next minute"))).toMatchObject({ ok: true })
    const g = driver()
    for (let i = 0; i < MAX_OPEN_REQUESTS; i++) {
      if (i % MAX_POSTS_PER_MINUTE === 0) g.advance(60_000)
      g.do(agentA, "feed.post", approve())
    }
    g.advance(60_000)
    expect(g.try(agentA, "feed.post", approve())).toMatchObject({ ok: false, code: "feed.full", retryable: true })
    expect(g.try(agentA, "feed.post", notice("notices still post"))).toMatchObject({ ok: true })
  })

  it("evicts closed and read items first and never an open request", () => {
    const f = driver()
    const requests: Array<string> = []
    for (let i = 0; i < MAX_ITEMS + 50; i++) {
      if (i % MAX_POSTS_PER_MINUTE === 0) f.advance(60_000)
      const r = f.do(agentA, "feed.post", i % 10 === 0 ? approve() : notice(`n${i}`))
      if (i % 10 === 0) requests.push(r.item.id)
    }
    const items = f.state.items
    expect(Object.keys(items).length).toBe(MAX_ITEMS)
    for (const id of requests) expect(items[id]?.state).toBe("open")
  })
})

describe("answers, cancels and lifecycle", () => {
  it("accepts one answer from a user action; the late device sees the closed item", () => {
    const f = driver()
    const id = f.do(agentA, "feed.post", approve()).item.id
    expect(f.try(agentA, "feed.answer", { item: id, answer: { decision: "allow" } }, "user")).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(f.try(mac, "feed.answer", { item: id, answer: { decision: "allow" } }, "cli")).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(f.try(mac, "feed.answer", { item: id, answer: { decision: "allow", scope: "always" } }, "user")).toMatchObject({ ok: false, code: "validation.invalid" })
    const a = f.do(phone, "feed.answer", { item: id, answer: { decision: "allow", scope: "session" }, device: "iPhone" }, "user")
    expect(a.item).toMatchObject({ state: "answered", answer: { value: { decision: "allow", scope: "session" }, by: phone.identity, device: "iPhone" }, push_due_at: null })
    expect(a.item.read_at).not.toBeNull()
    const late = f.try(mac, "feed.answer", { item: id, answer: { decision: "deny" } }, "user")
    expect(late).toMatchObject({ ok: false, code: "feed.closed", details: { item: { state: "answered" } } })
    expect(f.try(mac, "feed.answer", { item: f.do(agentA, "feed.post", notice("n")).item.id, answer: {} }, "user")).toMatchObject({ ok: false, code: "validation.invalid" })
  })

  it("checks choice, input, file and custom answers against the prompt", () => {
    const f = driver()
    const c = f.do(agentA, "feed.post", { type: "request", kind: "choice", title: "Pick", prompt: choicePrompt }).item.id
    const bad = [
      { answers: { db: { selected: ["pg", "sqlite"] }, feat: { selected: ["auth"] } } },
      { answers: { db: { selected: ["pg"] } } },
      { answers: { db: { selected: [] }, feat: { selected: ["auth"], other: "x" } } },
      { answers: { db: { selected: ["mysql"] }, feat: { selected: ["auth"] } } }
    ]
    for (const answer of bad) expect(f.try(mac, "feed.answer", { item: c, answer }, "user")).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(f.try(mac, "feed.answer", { item: c, answer: { answers: { db: { selected: [], other: "DuckDB" }, feat: { selected: ["auth", "sync"] } } } }, "user")).toMatchObject({ ok: true })

    const schema = { type: "object", properties: { email: { type: "string", format: "email" }, seats: { type: "integer", minimum: 1, maximum: 10 }, tags: { type: "array", items: { type: "string", enum: ["a", "b"] } } }, required: ["email"] }
    const i = f.do(agentA, "feed.post", { type: "request", kind: "input", title: "Details", prompt: { schema } }).item.id
    expect(f.try(mac, "feed.answer", { item: i, answer: { seats: 2 } }, "user")).toMatchObject({ ok: false })
    expect(f.try(mac, "feed.answer", { item: i, answer: { email: "nope", seats: 2 } }, "user")).toMatchObject({ ok: false })
    expect(f.try(mac, "feed.answer", { item: i, answer: { email: "a@b.co", seats: 11 } }, "user")).toMatchObject({ ok: false })
    expect(f.try(mac, "feed.answer", { item: i, answer: { email: "a@b.co", extra: 1 } }, "user")).toMatchObject({ ok: false })
    expect(f.try(mac, "feed.answer", { item: i, answer: { email: "a@b.co", seats: 3, tags: ["a"] } }, "user")).toMatchObject({ ok: true })

    const file = f.do(agentA, "feed.post", { type: "request", kind: "file", title: "Screenshot", prompt: { purpose: "repro", accept: ["image/png"], multiple: false, max_bytes: 1000 } }).item.id
    const att = (size: number) => ({ id: "a1", name: "s.png", mime: "image/png", size, sha256: "a".repeat(64), ref: "r2/a1" })
    expect(f.try(mac, "feed.answer", { item: file, answer: { files: [att(2000)] } }, "user")).toMatchObject({ ok: false })
    expect(f.try(mac, "feed.answer", { item: file, answer: { files: [att(10), att(10)] } }, "user")).toMatchObject({ ok: false })
    expect(f.try(mac, "feed.answer", { item: file, answer: { files: [att(10)] } }, "user")).toMatchObject({ ok: true })
  })

  it("lets the poster withdraw and the user decline; others are refused; repeats are no-ops", () => {
    const f = driver()
    const a = f.do(agentA, "feed.post", approve()).item.id
    expect(f.try(agentB, "feed.cancel", { item: a })).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(f.try(stranger, "feed.cancel", { item: a })).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(f.do(agentA, "feed.cancel", { item: a, reason: "answered_elsewhere" }).item).toMatchObject({ state: "cancelled", cancel: { reason: "answered_elsewhere" } })
    expect(f.try(agentA, "feed.cancel", { item: a, reason: "answered_elsewhere" })).toMatchObject({ ok: true, changed: false })
    expect(f.try(agentA, "feed.cancel", { item: a, reason: "poster" })).toMatchObject({ ok: false, code: "feed.closed" })
    const b = f.do(agentA, "feed.post", approve()).item.id
    expect(f.try(agentA, "feed.cancel", { item: b, reason: "declined" })).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(f.do(mac, "feed.cancel", { item: b }, "user").item.cancel.reason).toBe("declined")
    // The daemon that posted for an agent may cancel it (poster gone) without the agent id.
    const c = f.do(agentA, "feed.post", approve()).item.id
    expect(f.do(daemon, "feed.cancel", { item: c, reason: "poster_gone" }, "script").item.cancel.reason).toBe("poster_gone")
  })

  it("expires by the owner's alarm and refuses answers after the deadline", () => {
    const f = driver()
    const id = f.do(agentA, "feed.post", approve({ expires_in_ms: 10_000 })).item.id
    f.advance(10_000)
    expect(f.try(mac, "feed.answer", { item: id, answer: { decision: "allow" } }, "user")).toMatchObject({ ok: false, code: "feed.closed" })
    expect(f.try(mac, "feed.expire", { at: f.now })).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(f.do(system, "feed.expire", { at: f.now }).items).toEqual([id])
    expect(f.state.items[id]).toMatchObject({ state: "expired", closed_at: f.now })
    expect(f.try(system, "feed.expire", { at: f.now })).toMatchObject({ ok: true, changed: false })
    expect(f.try(system, "feed.expire", { at: "soon" })).toMatchObject({ ok: false, code: "validation.invalid" })
  })
})

describe("triage, push and retention", () => {
  it("never archives or snoozes an open request; snooze wakes items unread with push re-armed", () => {
    const f = driver()
    const r = f.do(agentA, "feed.post", approve()).item.id
    const n = f.do(agentA, "feed.post", notice("n", { dedupe_key: "k" })).item.id
    expect(f.try(mac, "feed.archive", { items: [r] }, "user")).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(f.try(mac, "feed.snooze", { items: [r], until: f.now + 1000 }, "user")).toMatchObject({ ok: false })
    expect(f.try(agentA, "feed.read", { items: [n] }, "user")).toMatchObject({ ok: false, code: "auth.forbidden" })
    f.do(mac, "feed.read", { items: [n] }, "user")
    f.do(mac, "feed.snooze", { items: [n], until: f.now + 5000 }, "user")
    expect(f.state.items[n]).toMatchObject({ snoozed_until: f.now + 5000, push_due_at: null })
    f.advance(5000)
    f.do(system, "feed.snooze_wake", { at: f.now })
    expect(f.state.items[n]).toMatchObject({ snoozed_until: null, read_at: null, push_due_at: f.now + 120_000 })
    // Archive releases the dedupe key: the next post is a new item; unarchive does not steal it back.
    f.do(mac, "feed.archive", { items: [n] }, "user")
    const n2 = f.do(agentA, "feed.post", notice("n again", { dedupe_key: "k" })).item.id
    expect(n2).not.toBe(n)
    f.do(mac, "feed.unarchive", { items: [n] }, "user")
    expect(f.do(agentA, "feed.post", notice("third", { dedupe_key: "k" })).item.id).toBe(n2)
  })

  it("records push decisions only for eligible due items", () => {
    const f = driver()
    const seen = f.do(agentA, "feed.post", approve()).item.id
    const due = f.do(agentA, "feed.post", approve()).item.id
    const low = f.do(agentA, "feed.post", notice("low", { priority: "low" })).item.id
    expect(f.state.items[low]!.push_due_at).toBeNull()
    f.do(mac, "feed.seen", { items: [seen] }, "user")
    f.advance(20_000)
    const r = f.do(system, "feed.push_due", { at: f.now, send: [seen, due], skip: [] })
    expect(r.sent).toEqual([due])
    expect(f.state.items[due]).toMatchObject({ pushed_at: f.now, push_due_at: null })
    expect(f.state.items[seen]!.pushed_at).toBeNull()
  })

  it("prunes closed and archived items after the retention window", () => {
    const f = driver()
    const a = f.do(agentA, "feed.post", notice("a")).item.id
    const r = f.do(agentA, "feed.post", approve()).item.id
    f.do(mac, "feed.archive", { items: [a] }, "user")
    f.advance(RETENTION_MS)
    expect(f.do(system, "feed.prune", { before: f.now - RETENTION_MS + 1 }).items).toEqual([a])
    expect(f.state.items[r]).toBeDefined()
  })

  it("prefs change push delays for new items", () => {
    const f = driver()
    f.do(mac, "feed.prefs.set", { push_delay: { high: null } }, "user")
    expect(f.do(agentA, "feed.post", approve()).item.push_due_at).toBeNull()
    f.do(session, "feed.prefs.set", { push_enabled: false }, "user")
    expect(f.do(agentA, "feed.post", approve({ priority: "urgent" })).item.push_due_at).toBeNull()
  })
})

describe("scoping, handoff and reads", () => {
  it("binds to one user and filters agent reads to their own scope", () => {
    const f = driver()
    const mine = f.do(agentA, "feed.post", notice("a")).item
    const theirs = f.do(agentB, "feed.post", notice("b")).item
    expect(f.try(stranger, "feed.post", notice("x"))).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(visibleTo(agentA, mine)).toBe(true)
    expect(visibleTo(agentA, theirs)).toBe(false)
    expect(visibleTo(mac, theirs)).toBe(true)
  })

  it("adopts a local item with the same id once, only from its home install", () => {
    const f = driver()
    const local = f.do(agentA, "feed.post", approve()).item
    const g = driver()
    const item = { ...local, home: `local:${daemon.install}` }
    expect(g.try(mac, "feed.adopt", { item })).toMatchObject({ ok: false, code: "auth.forbidden" })
    const a = g.do(daemon, "feed.adopt", { item })
    expect(a.item).toMatchObject({ id: local.id, home: "cloud", state: "open", revision: local.revision + 1 })
    expect(g.try(daemon, "feed.adopt", { item })).toMatchObject({ ok: true, changed: false })
    expect(g.do(mac, "feed.answer", { item: local.id, answer: { decision: "deny" } }, "user").item.state).toBe("answered")
  })
})

describe("owner order, groups, filters and open targets", () => {
  it("orders urgent first for every client, groups by thread, filters and pages", () => {
    const f = driver()
    const oldNotice = f.do(agentA, "feed.post", notice("old", { thread: "s1" })).item.id
    const normalReq = f.do(agentA, "feed.post", { type: "request", kind: "review", title: "review", prompt: { subject: "plan", ref: "plan.md" }, thread: "s1" }).item.id
    const highReq = f.do(agentB, "feed.post", approve({ context: { workspace: "ws_1" } })).item.id
    const urgentReq = f.do(agentB, "feed.post", approve({ priority: "urgent" })).item.id
    const readNotice = f.do(agentA, "feed.post", notice("read")).item.id
    f.do(mac, "feed.read", { items: [readNotice] }, "user")
    const all = Object.values(f.state.items)
    expect(listItems(all, {}, f.now).items.map((i) => i.id)).toEqual([urgentReq, highReq, normalReq, oldNotice, readNotice])
    expect(listItems(all, { order: "recent" }, f.now).items[0]!.id).toBe(readNotice)
    expect(listItems(all, { needs_response: true }, f.now).items).toHaveLength(3)
    expect(listItems(all, { workspace: "ws_1" }, f.now).items.map((i) => i.id)).toEqual([highReq])
    expect(listItems(all, { query: "REVIEW" }, f.now).items.map((i) => i.id)).toEqual([normalReq])
    const grouped = listItems(all, { group_by: "thread" }, f.now)
    expect(grouped.groups!.find((g) => g.items.length === 2)!.items).toEqual([normalReq, oldNotice])
    const page1 = listItems(all, { limit: 2 }, f.now)
    expect(page1.next).toBe(highReq)
    expect(listItems(all, { limit: 2, after: page1.next! }, f.now).items.map((i) => i.id)).toEqual([normalReq, oldNotice])
    expect(feedCounts(f.state, f.now)).toMatchObject({ open_requests: 3, unread: 4, by_priority: { urgent: 1, high: 1, normal: 1 } })
  })

  it("triages by filter: read a thread, archive a poster's notices but skip open requests", () => {
    const f = driver()
    const a = f.do(agentA, "feed.post", notice("a", { thread: "t" })).item.id
    const b = f.do(agentA, "feed.post", notice("b", { thread: "t" })).item.id
    const r = f.do(agentA, "feed.post", approve({ thread: "t" })).item.id
    expect(f.try(mac, "feed.read", { all: true, filter: { thread: "t" } }, "user")).toMatchObject({ ok: false })
    f.do(mac, "feed.read", { filter: { thread: "t" } }, "user")
    expect([a, b, r].map((id) => f.state.items[id]!.read_at !== null)).toEqual([true, true, true])
    f.do(mac, "feed.archive", { filter: { thread: "t" } }, "user")
    expect([a, b, r].map((id) => f.state.items[id]!.archived_at !== null)).toEqual([true, true, false])
  })

  it("accepts only open-style actions as the item's open target", () => {
    const f = driver()
    expect(f.try(agentA, "feed.post", notice("x", { open: { action: "workspace.close", args: {} } }))).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(f.do(agentA, "feed.post", notice("x", { open: { action: "tab.focus", args: { tab: "tab_1" } } })).item.open).toEqual({ action: "tab.focus", args: { tab: "tab_1" } })
    expect(f.do(session, "feed.post", notice("note to self")).item.poster.kind).toBe("user")
  })
})

describe("review fixes: authority, bounds and adopt", () => {
  it("lets only the user's own apps answer: never a daemon, CLI or VM token, even with origin user", () => {
    const f = driver()
    const id = f.do(vm, "feed.post", approve()).item.id
    expect(f.try(vm, "feed.answer", { item: id, answer: { decision: "allow" } }, "user")).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(f.try(daemon, "feed.answer", { item: id, answer: { decision: "allow" } }, "user")).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(f.try(daemon, "feed.read", { all: true }, "user")).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(f.try(session, "feed.answer", { item: id, answer: { decision: "allow" } }, "user")).toMatchObject({ ok: true })
    // A VM or CLI token cannot pose as cmux itself.
    expect(f.do(vm, "feed.post", notice("x", { poster: { kind: "system" } })).item.poster.kind).toBe("server")
    expect(f.do(daemon, "feed.post", notice("x", { poster: { kind: "system" } })).item.poster.kind).toBe("system")
  })

  it("answers sign-in and passkey requests only from the Mac", () => {
    const f = driver()
    const id = f.do(agentA, "feed.post", { type: "request", kind: "passkey", title: "p", prompt: { origin: "https://github.com", ceremony: "get", browser_tab: "tab_1", reason: "r" } }).item.id
    expect(f.try(phone, "feed.answer", { item: id, answer: { status: "completed" } }, "user")).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(f.try(mac, "feed.answer", { item: id, answer: { status: "completed" } }, "user")).toMatchObject({ ok: true })
  })

  it("lets the user only decline, and the poster not decline", () => {
    const f = driver()
    const id = f.do(agentA, "feed.post", approve()).item.id
    expect(f.try(mac, "feed.cancel", { item: id, reason: "superseded" }, "user")).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(f.do(mac, "feed.cancel", { item: id, reason: "declined" }, "user").item.cancel.reason).toBe("declined")
  })

  it("bounds item and state bytes, the install-wide rate, and refuses a dedupe key held by another kind", () => {
    const f = driver()
    const big = "x".repeat(4000)
    const args = Object.fromEntries(Array.from({ length: 8 }, (_, i) => [`k${i}`, big]))
    expect(f.try(agentA, "feed.post", notice("x", { open: { action: "tab.focus", args } }))).toMatchObject({ ok: false, message: expect.stringMatching(String(MAX_ITEM_BYTES)) })
    expect(f.try(agentA, "feed.post", notice("x", { context: { url: "javascript:alert(1)" } }))).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(f.try(agentA, "feed.post", notice("x", { open: { action: "url.open", args: { url: "file:///etc/passwd" } } }))).toMatchObject({ ok: false, code: "validation.invalid" })
    f.do(agentA, "feed.post", notice("x", { dedupe_key: "same" }))
    expect(f.try(agentA, "feed.post", approve({ dedupe_key: "same" }))).toMatchObject({ ok: false, code: "validation.invalid" })
    // Many declared agents on one install still share the install-wide limit.
    const g = driver()
    let refused = 0
    for (let i = 0; i < MAX_INSTALL_POSTS_PER_MINUTE + 10; i++) {
      const r = g.try(daemon, "feed.post", notice("n", { poster: { agent: `a${i}` } }))
      if (!r.ok) refused++
    }
    expect(refused).toBe(10)
    // Large notices fill the byte budget; then posts are refused (retryable), never written past it.
    const h = driver()
    const body = "y".repeat(4000)
    let full = false
    for (let i = 0; i < MAX_ITEMS && !full; i++) {
      if (i % MAX_POSTS_PER_MINUTE === 0) h.advance(60_000)
      const r = h.try(agentA, "feed.post", notice("n", { body, actions: [0, 1, 2, 3].map((n) => ({ id: `a${n}`, label: "open" })), open: { action: "tab.focus", args: { pad: "z".repeat(15_000) } } }))
      if (!r.ok) {
        expect(r).toMatchObject({ code: "feed.full", retryable: true })
        full = true
      }
      expect(jsonBytes(h.state.items)).toBeLessThanOrEqual(MAX_STATE_BYTES)
    }
    expect(full).toBe(true)
  })

  it("clears scheduled pushes when prefs turn that priority off", () => {
    const f = driver()
    const id = f.do(agentA, "feed.post", approve()).item.id
    expect(f.state.items[id]!.push_due_at).not.toBeNull()
    f.do(mac, "feed.prefs.set", { push_delay: { high: null } }, "user")
    expect(f.state.items[id]!.push_due_at).toBeNull()
  })

  it("adopts only consistent items of the calling install", () => {
    const src = driver()
    const open = src.do(agentA, "feed.post", approve()).item
    const home = `local:${daemon.install}`
    const g = driver()
    const bad = (item: unknown) => expect(g.try(daemon, "feed.adopt", { item })).toMatchObject({ ok: false })
    bad({ ...open, home, state: "answered", closed_at: g.now, answer: { value: { decision: "launch" }, by: "x", device: null, at: g.now } })
    bad({ ...open, home, archived_at: g.now })
    bad({ ...open, home, poster: { ...open.poster, install: "inst_other00000000000000", scope: "inst:inst_other00000000000000" } })
    bad({ ...open, home, needs_mac: true })
    const answered = { ...open, home, state: "answered", closed_at: g.now, read_at: g.now, answer: { value: { decision: "deny" }, by: mac.identity, device: null, at: g.now } }
    expect(g.do(daemon, "feed.adopt", { item: answered }).item).toMatchObject({ home: "cloud", state: "answered" })
  })

  it("feed.adopt.cancel tombstones a key that was not adopted and reports one that was", () => {
    const src = driver()
    const home = `local:${daemon.install}`
    const g = driver()
    // Not adopted yet: cancelled, and the delayed adopt with that key is refused.
    const late = { ...src.do(agentA, "feed.post", approve()).item, home }
    expect(g.do(daemon, "feed.adopt.cancel", { key: `adopt:${late.id}` })).toMatchObject({ cancelled: true })
    expect(g.try(daemon, "feed.adopt", { item: late })).toMatchObject({ ok: false, code: "feed.adopt_cancelled" })
    expect(g.state.items[late.id]).toBeUndefined()
    // A retried cancel answers the same.
    expect(g.do(daemon, "feed.adopt.cancel", { key: `adopt:${late.id}` })).toMatchObject({ cancelled: true })
    // Already adopted: not cancelled, and the reply carries the cloud record.
    const moved = { ...src.do(agentA, "feed.post", approve()).item, home }
    g.do(daemon, "feed.adopt", { item: moved })
    expect(g.do(daemon, "feed.adopt.cancel", { key: `adopt:${moved.id}` })).toMatchObject({ cancelled: false, item: { id: moved.id, home: "cloud" } })
    // Only the install that posted the item, never a user client, an agent or another install; only adopt keys.
    expect(g.try(mac, "feed.adopt.cancel", { key: `adopt:${moved.id}` })).toMatchObject({ ok: false })
    expect(g.try(agentA, "feed.adopt.cancel", { key: `adopt:${late.id}` })).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(g.try(daemon, "feed.adopt.cancel", { key: `post:${late.id}` })).toMatchObject({ ok: false, code: "validation.invalid" })
    // A full tombstone list refuses new cancels (retryable) and never evicts a live tombstone.
    const id = (n: number) => `fi_${String(n).padStart(20, "0")}`
    for (let n = 0; n < 999; n++) g.do(daemon, "feed.adopt.cancel", { key: `adopt:${id(n)}` })
    expect(g.try(daemon, "feed.adopt.cancel", { key: `adopt:${id(5000)}` })).toMatchObject({ ok: false, code: "feed.full", retryable: true })
    expect(g.try(daemon, "feed.adopt", { item: late })).toMatchObject({ ok: false, code: "feed.adopt_cancelled" })
    // After 30 days the tombstones go and cancels work again.
    g.advance(31 * 24 * 3600_000)
    expect(g.do(daemon, "feed.adopt.cancel", { key: `adopt:${id(5000)}` })).toMatchObject({ cancelled: true })
  })

  it("adopt clamps a daemon clock that runs ahead and takes push timing from the cloud prefs", () => {
    const src = driver()
    const home = `local:${daemon.install}`
    const g = driver()
    // A daemon clock one hour ahead: times come down to the DO clock, far deadlines to the limits.
    const ahead = src.do(agentA, "feed.post", approve()).item
    const skewed = { ...ahead, home, created_at: g.now + 3600_000, updated_at: g.now + 3600_000, read_at: g.now + 3600_000, expires_at: g.now + 400 * 24 * 3600_000, push_due_at: g.now + 3600_000 }
    const a = g.do(daemon, "feed.adopt", { item: skewed }).item
    expect(a).toMatchObject({ created_at: g.now, read_at: g.now, expires_at: g.now + 30 * 24 * 3600_000 })
    // An open request pushes on the cloud delay from its creation (high: 20 s), whatever the daemon sent.
    expect(a.push_due_at).toBe(g.now + 20_000)
    const early = src.do(agentA, "feed.post", approve()).item
    expect(g.do(daemon, "feed.adopt", { item: { ...early, home, created_at: g.now - 60_000, push_due_at: null } }).item.push_due_at).toBe(g.now)
    // Push off for that priority in the cloud: the daemon's due time is dropped.
    g.do(mac, "feed.prefs.set", { push_delay: { high: null } }, "user")
    const off = src.do(agentA, "feed.post", approve()).item
    expect(g.do(daemon, "feed.adopt", { item: { ...off, home, push_due_at: g.now } }).item.push_due_at).toBeNull()
  })
})
