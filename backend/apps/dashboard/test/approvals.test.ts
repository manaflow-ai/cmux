import { describe, expect, it } from "bun:test"
import { createHash } from "node:crypto"
import { createElement } from "react"
import { renderToStaticMarkup } from "react-dom/server"
import { canonicalJson } from "../../../packages/ownership/src/engine.ts"
import { ApprovalCard } from "../src/lib/approval-card.tsx"
import { approvalStatus, canApprove, checkDigest, parseApproval, requestDigest, type ApprovalView } from "../src/lib/approvals.ts"
import { approvalText, pickLocale } from "../src/lib/approval-strings.ts"
import { expiryStore } from "../src/lib/expiry.ts"

/** The digest exactly as the API Worker computes it (integrations/approval-gate.ts approvalDigest). */
const serverDigest = (op: string, params: Record<string, unknown>) => `sha256:${createHash("sha256").update(canonicalJson({ op, params })).digest("hex")}`

const REQUEST = `apr_${"a1".repeat(16)}`
const NOW = 1_800_000_000_000
const HOUR = 3_600_000
const params = { connection: "conn_1", to: ["ann@example.com"], subject: "Q3 numbers", body: "secret body", nested: { z: 1, a: [{ y: 2, b: 3 }] } }
const DIGEST = serverDigest("mail.send", params)

const feedItem = (over: Record<string, unknown> = {}) => ({
  id: "fi_1",
  kind: "approve",
  type: "request",
  title: "Approve an action by an agent",
  state: "open",
  poster: { kind: "integration", scope: "system:connections:team_1", label: "Integrations" },
  prompt: {
    action: {
      type: "tool",
      tool: "mail.send",
      summary: "mail.send to ann@example.com: Q3 numbers",
      risk: "send-external",
      input: { approval: { team: "team_1", request: REQUEST, digest: DIGEST }, connection: "conn_1", target: "ann@example.com", summary: "Q3 numbers" }
    },
    scopes: ["once"]
  },
  answer: null,
  cancel: null,
  expires_at: NOW + 24 * HOUR,
  created_at: NOW,
  ...over
})

const view = (over: Partial<ApprovalView> = {}): ApprovalView => ({
  request: REQUEST,
  op: "mail.send",
  connection: "conn_1",
  target: "ann@example.com",
  summary: "Q3 numbers",
  params,
  digest: DIGEST,
  state: "pending",
  created_at: NOW,
  expires_at: NOW + 24 * HOUR,
  ...over
})

const approval = (over: Record<string, unknown> = {}) => parseApproval(feedItem(over))!

describe("integration approval feed items", () => {
  it("reads only approve requests posted by an integration, with the request, digest, op and target", () => {
    const a = approval()
    expect(a).toMatchObject({ item: "fi_1", request: REQUEST, digest: DIGEST, team: "team_1", op: "mail.send", target: "ann@example.com", summary: "Q3 numbers", risk: "send-external", expiresAt: NOW + 24 * HOUR })
    expect(parseApproval(feedItem({ poster: { kind: "agent", scope: "agent:x", label: "Claude" } }))).toBeNull()
    expect(parseApproval(feedItem({ kind: "confirm" }))).toBeNull()
    // Only the team named in the approval may have posted it (the API ignores any other answer).
    expect(parseApproval(feedItem({ poster: { kind: "integration", scope: "system:connections:team_2", label: "Integrations" } }))).toBeNull()
    // A Cloud request from a device (cx-wb5.65) is posted by the same team's CloudDO.
    expect(parseApproval(feedItem({ poster: { kind: "integration", scope: "system:cloud:team_1", label: "Cloud" } }))).toMatchObject({ request: REQUEST, team: "team_1" })
    expect(parseApproval(feedItem({ poster: { kind: "integration", scope: "system:cloud:team_2", label: "Cloud" } }))).toBeNull()
    expect(parseApproval(feedItem({ prompt: { action: { input: { approval: { team: "team_1", request: "apr_bad", digest: DIGEST } } } } }))).toBeNull()
  })
})

describe("request digest", () => {
  it("matches the digest the API Worker stores, for nested params in any key order", async () => {
    expect(await requestDigest("mail.send", params)).toBe(DIGEST)
    const shuffled = { nested: { a: [{ b: 3, y: 2 }], z: 1 }, body: "secret body", subject: "Q3 numbers", to: ["ann@example.com"], connection: "conn_1" }
    expect(await requestDigest("mail.send", shuffled)).toBe(DIGEST)
    const edge = { connection: "c", skipped: undefined, n: [-0, 1.5, 1e21, 0.1], deep: [[{ b: null, a: [] }]], "10": "x", "2": "y" }
    expect(await requestDigest("x.op", edge)).toBe(serverDigest("x.op", edge))
  })
  it("refuses a view whose params, op or digest differ from the feed request", async () => {
    expect(await checkDigest(approval(), view())).toBe("match")
    expect(await checkDigest(approval(), view({ params: { ...params, body: "changed" } }))).toBe("mismatch")
    expect(await checkDigest(approval(), view({ op: "slack.post_as_bot" }))).toBe("mismatch")
    expect(await checkDigest(approval(), view({ digest: serverDigest("mail.send", { ...params, to: ["eve@example.com"] }) }))).toBe("mismatch")
    // A final request has no params left to check; its state is what counts.
    expect(await checkDigest(approval(), view({ state: "done", params: {} }))).toBeNull()
  })
})

describe("approval status", () => {
  it("is pending and approvable only while open, unexpired and digest-checked", () => {
    expect(approvalStatus(approval(), view(), "match", NOW)).toBe("pending")
    expect(canApprove("pending", "match")).toBe(true)
    expect(canApprove("pending", null)).toBe(false)
    expect(canApprove("stale", "mismatch")).toBe(false)
  })
  it("shows the final states from the API: approved, denied, expired", () => {
    expect(approvalStatus(approval({ state: "answered", answer: { value: { decision: "allow", scope: "once" }, at: NOW } }), view({ state: "done", params: {} }), null, NOW)).toBe("approved")
    expect(approvalStatus(approval(), view({ state: "denied", params: {} }), null, NOW)).toBe("denied")
    expect(approvalStatus(approval(), view({ state: "expired", params: {} }), null, NOW)).toBe("expired")
  })
  it("expires after 24 hours even before the server alarm runs", () => {
    expect(approvalStatus(approval(), view(), "match", NOW + 24 * HOUR)).toBe("expired")
    expect(approvalStatus(approval(), null, null, NOW + 25 * HOUR)).toBe("expired")
  })
  it("reports a stale digest as refused, never approvable", () => {
    expect(approvalStatus(approval(), view({ params: { ...params, body: "changed" } }), "mismatch", NOW)).toBe("stale")
    expect(approvalStatus(approval({ state: "answered", answer: { value: { decision: "allow" }, at: NOW } }), view(), "mismatch", NOW)).toBe("stale")
  })
  it("tracks the person's answer until the API settles it", () => {
    expect(approvalStatus(approval({ state: "answered", answer: { value: { decision: "allow", scope: "once" }, at: NOW } }), view(), "match", NOW)).toBe("running")
    expect(approvalStatus(approval({ state: "answered", answer: { value: { decision: "deny" }, at: NOW } }), view(), "match", NOW)).toBe("denied")
    expect(approvalStatus(approval({ state: "cancelled", cancel: { reason: "declined", at: NOW } }), view(), "match", NOW)).toBe("denied")
    expect(approvalStatus(approval({ state: "cancelled", cancel: { reason: "poster", at: NOW } }), null, null, NOW)).toBe("withdrawn")
    // Approved, but this session cannot read the outcome (another team, pruned, a failed read): never claim it ran.
    expect(approvalStatus(approval({ state: "answered", answer: { value: { decision: "allow" }, at: NOW } }), null, null, NOW)).toBe("answered")
  })
  it("tells an approved request whose caller lost its grant apart from a denial", () => {
    const allowed = approval({ state: "answered", answer: { value: { decision: "allow", scope: "once" }, at: NOW } })
    expect(approvalStatus(allowed, view({ state: "denied", params: {} }), null, NOW)).toBe("revoked")
    expect(approvalStatus(approval({ state: "answered", answer: { value: { decision: "deny" }, at: NOW } }), view({ state: "denied", params: {} }), null, NOW)).toBe("denied")
  })
})

describe("localized strings", () => {
  it("picks Japanese for ja browsers and English otherwise", () => {
    expect(pickLocale(["ja-JP", "en-US"])).toBe("ja")
    expect(pickLocale(["fr-FR", "ja"])).toBe("ja")
    expect(pickLocale(["de-DE"])).toBe("en")
    expect(pickLocale([])).toBe("en")
  })
  it("translates every status into Japanese", () => {
    for (const s of ["pending", "running", "answered", "approved", "revoked", "denied", "expired", "stale", "withdrawn"] as const) {
      expect(approvalText("ja", `status.${s}`)).not.toBe(approvalText("en", `status.${s}`))
    }
  })
})

const render = (props: Partial<Parameters<typeof ApprovalCard>[0]> = {}) =>
  renderToStaticMarkup(
    createElement(ApprovalCard, { approval: approval(), view: view(), digest: "match", now: NOW, locale: "en", open: false, busy: false, onToggle: () => {}, onApprove: () => {}, onDeny: () => {}, ...props })
  )

describe("approval card", () => {
  it("marks the integration poster and offers Approve and Deny while pending, with the expiry", () => {
    const html = render()
    expect(html).toContain('data-poster="integration"')
    // Closed: the full request is not on screen, so only Review and Deny.
    expect(html).not.toContain(">Approve<")
    expect(html).toContain(">Review<")
    expect(render({ open: true })).toContain(">Approve<")
    expect(html).toContain(">Deny<")
    expect(html).toContain("mail.send")
    expect(html).toContain("ann@example.com")
    expect(html).toContain("in 24 hours")
    expect(html).not.toContain("secret body")
  })
  it("shows the full parameters and digest only when opened", () => {
    const html = render({ open: true })
    expect(html).toContain("secret body")
    expect(html).toContain(DIGEST)
  })
  it("offers no Approve for a stale digest, and no answer at all for a final state", () => {
    const stale = render({ open: true, view: view({ params: { ...params, body: "changed" } }), digest: "mismatch" })
    expect(stale).not.toContain(">Approve<")
    expect(stale).toContain(">Deny<")
    expect(stale).toContain('data-status="stale"')
    // The API refused the approval (digest mismatch): the item is answered, so no Deny either, and the text says so.
    const refused = render({ approval: approval({ state: "answered", answer: { value: { decision: "allow" }, at: NOW } }), digest: "mismatch" })
    expect(refused).not.toContain(">Deny<")
    expect(refused).toContain("It ends when it expires.")
    for (const state of ["done", "denied", "expired"] as const) {
      const html = render({ open: true, view: view({ state, params: {} }), digest: null })
      expect(html).not.toContain(">Approve<")
      expect(html).not.toContain(">Deny<")
    }
    expect(render({ view: view({ state: "done", params: {} }), digest: null })).toContain('data-status="approved"')
  })
  it("never offers Approve when this browser cannot check the digest", () => {
    const html = render({ open: true, digest: "error" })
    expect(html).not.toContain(">Approve<")
    expect(html).toContain("could not check the request digest")
  })
  it("renders in Japanese", () => {
    const html = render({ locale: "ja", open: true })
    expect(html).toContain(">承認<")
    expect(html).toContain(">拒否<")
  })
})

describe("expiry at render time", () => {
  const fakeScheduler = (start: number) => {
    const timers: Array<{ fn: () => void; ms: number }> = []
    const state = { clock: start, cleared: 0 }
    return {
      timers,
      state,
      scheduler: {
        now: () => state.clock,
        setTimeout: (fn: () => void, ms: number) => timers.push({ fn, ms }),
        clearTimeout: () => void state.cleared++
      }
    }
  }
  it("schedules one timeout to the exact expiry, flips to expired when it fires, and clears it on unsubscribe", () => {
    const f = fakeScheduler(1_000)
    const store = expiryStore(5_000, f.scheduler)
    let changes = 0
    const unsubscribe = store.subscribe(() => changes++)
    expect(f.timers.map((t) => t.ms)).toEqual([4_000])
    expect(store.getSnapshot()).toBe(false)
    f.state.clock = 5_000
    f.timers[0]!.fn()
    expect(changes).toBe(1)
    expect(store.getSnapshot()).toBe(true)
    unsubscribe()
    // A card that unmounts before the expiry clears its timer.
    const g = fakeScheduler(1_000)
    expiryStore(5_000, g.scheduler).subscribe(() => {})()
    expect(g.timers).toHaveLength(1)
    expect(g.state.cleared).toBe(1)
  })
  it("schedules nothing for a request that already expired", () => {
    const f = fakeScheduler(9_000)
    const store = expiryStore(5_000, f.scheduler)
    store.subscribe(() => {})
    expect(f.timers).toHaveLength(0)
    expect(store.getSnapshot()).toBe(true)
  })
  it("an expired card never shows Approve, even when the page's render time is older", () => {
    const past = Date.now() - 1_000
    const html = render({ open: true, now: past - HOUR, approval: approval({ expires_at: past }), view: view({ expires_at: past }) })
    expect(html).not.toContain(">Approve<")
    expect(html).not.toContain(">Deny<")
    expect(html).toContain('data-status="expired"')
  })
})
