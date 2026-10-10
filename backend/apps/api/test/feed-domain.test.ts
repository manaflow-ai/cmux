import { describe, expect, it } from "vitest"
import { MAX_INSTALL_POSTS_PER_MINUTE, MAX_ITEM_BYTES, MAX_ITEMS, MAX_OPEN_REQUESTS, MAX_POSTS_PER_MINUTE, MAX_STATE_BYTES, RETENTION_MS, jsonBytes } from "../src/domains/feed-state.ts"
import { feedCounts, visibleTo } from "../src/domains/feed.ts"
import { listItems } from "../src/domains/feed-query.ts"
import { agentA, agentB, approvePrompt, choicePrompt, daemon, driver, mac, phone, session, stranger, system, vm } from "./feed-harness.ts"

const notice = (title: string, extra: Record<string, unknown> = {}) => ({ type: "notice", kind: "notice", title, ...extra })
const approve = (extra: Record<string, unknown> = {}) => ({ type: "request", kind: "approve", title: "Claude Code needs permission", prompt: approvePrompt, ...extra })

describe("feed.post", () => {

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

})

describe("answers, cancels and lifecycle", () => {

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
