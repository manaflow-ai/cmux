import { createHash } from "node:crypto"
import { describe, expect, it } from "vitest"
import { addressDomain, INITIAL_ADDRESS_HEAD, type AddressHead } from "../src/address/domain.ts"
import { parseInbound } from "../src/address/inbound.ts"
import { BINDING_IDLE_MS, BINDING_TTL_MS, LINK_TTL_MS, textAuthority, type LinkState } from "../src/address/text-link.ts"
import type { Principal } from "../src/conversation/engine-types.ts"
import { MemoryRows } from "./support/harness.ts"

const NOW = 1_790_000_000_000
const sha = (v: string) => createHash("sha256").update(v).digest("base64url")
const CODE = "0123456789ABCDEFGHJKMNPQRS"
const PROOF = sha(CODE)
const system: Principal = { identity: "system:w", kind: "system" }
const alice: Principal = { identity: "user:user_alice", kind: "session", user: "user_alice" }
const mallory: Principal = { identity: "user:user_mallory", kind: "session", user: "user_mallory" }

const owner = () => {
  let head: AddressHead = INITIAL_ADDRESS_HEAD
  const submit = (op: string, params: Record<string, unknown>, p: Principal, now = NOW) => {
    const denied = addressDomain.authorize?.(head, op, params, p)
    if (denied) return { ok: false as const, code: denied.code }
    const r = addressDomain.reduce(head, op, params, { principal: p, now, tx: "t", newId: (x) => `${x}1`, rows: new MemoryRows() })
    if (!r.ok) return { ok: false as const, code: r.code }
    head = r.state
    return { ok: true as const, value: r.value as Record<string, unknown> | null }
  }
  submit("address.ensure", { id: "addr_P", channel: "sms", value: "+14155550100" }, system)
  return { submit, get head() { return head } }
}

describe("linking a phone for texting Chief", () => {
  it("binds only when the requesting account opens the link in time, once", () => {
    const o = owner()
    expect(o.submit("address.text_link.request", { user: "user_alice", code_hash: sha(PROOF) }, system).ok).toBe(true)
    expect(o.submit("address.text_link.confirm", { proof: PROOF }, alice)).toMatchObject({ ok: true, value: { linked: true } })
    expect(o.head.link?.binding?.user).toBe("user_alice")
    expect(o.submit("address.text_link.confirm", { proof: PROOF }, alice)).toEqual({ ok: false, code: "link.none" })
  })

  it("burns a forwarded link opened by another account", () => {
    const o = owner()
    o.submit("address.text_link.request", { user: "user_alice", code_hash: sha(PROOF) }, system)
    expect(o.submit("address.text_link.confirm", { proof: PROOF }, mallory)).toMatchObject({ ok: true, value: { linked: false, code: "link.wrong_account" } })
    expect(o.head.link?.binding).toBeNull()
    expect(o.submit("address.text_link.confirm", { proof: PROOF }, alice)).toEqual({ ok: false, code: "link.none" })
  })

  it("expires after the TTL and burns after five wrong proofs", () => {
    const o = owner()
    o.submit("address.text_link.request", { user: "user_alice", code_hash: sha(PROOF) }, system)
    expect(o.submit("address.text_link.confirm", { proof: PROOF }, alice, NOW + LINK_TTL_MS)).toMatchObject({ value: { linked: false, code: "link.expired" } })
    const p = owner()
    p.submit("address.text_link.request", { user: "user_alice", code_hash: sha(PROOF) }, system)
    for (let i = 0; i < 5; i++) p.submit("address.text_link.confirm", { proof: `wrong${i}` }, alice)
    expect(p.submit("address.text_link.confirm", { proof: PROOF }, alice)).toEqual({ ok: false, code: "link.none" })
  })

  it("limits requests, refuses a number bound elsewhere, and needs a signed-in session to confirm", () => {
    const o = owner()
    for (let i = 0; i < 3; i++) expect(o.submit("address.text_link.request", { user: "user_alice", code_hash: sha(PROOF) }, system, NOW + i).ok).toBe(true)
    expect(o.submit("address.text_link.request", { user: "user_alice", code_hash: sha(PROOF) }, system, NOW + 10)).toEqual({ ok: false, code: "link.rate_limited" })
    o.submit("address.text_link.confirm", { proof: PROOF }, alice, NOW + 20)
    expect(o.submit("address.text_link.request", { user: "user_mallory", code_hash: sha(PROOF) }, system, NOW + 4_000_000)).toEqual({ ok: false, code: "link.bound_elsewhere" })
    expect(o.submit("address.text_link.confirm", { proof: PROOF }, { identity: "x", kind: "agent", agent: "agent_x" })).toEqual({ ok: false, code: "forbidden" })
    expect(o.submit("address.text_link.request", { user: "user_alice", code_hash: "h" }, alice)).toEqual({ ok: false, code: "forbidden" })
    expect(o.submit("address.text_link.unlink", {}, mallory)).toEqual({ ok: false, code: "forbidden" })
    expect(o.submit("address.text_link.unlink", {}, alice).ok).toBe(true)
  })

  it("never lets a stranger's request replace the owner's pending link, and caps a number per day", () => {
    const o = owner()
    o.submit("address.text_link.request", { user: "user_alice", code_hash: sha(PROOF) }, system)
    o.submit("address.text_link.request", { user: "user_mallory", code_hash: sha("other") }, system, NOW + 1)
    expect(o.submit("address.text_link.confirm", { proof: PROOF }, alice, NOW + 2)).toMatchObject({ ok: true, value: { linked: true } })
    const p = owner()
    for (let i = 0; i < 6; i++) p.submit("address.text_link.request", { user: `user_u${i}`, code_hash: sha(`p${i}`) }, system, NOW + i)
    expect(p.submit("address.text_link.request", { user: "user_alice", code_hash: sha(PROOF) }, system, NOW + 10)).toEqual({ ok: false, code: "link.rate_limited" })
  })

  it("keeps the text binding separate from linked_user and does not revive an idle binding by a text", () => {
    const o = owner()
    o.submit("address.text_link.request", { user: "user_alice", code_hash: sha(PROOF) }, system)
    o.submit("address.text_link.confirm", { proof: PROOF }, alice)
    expect(o.head.linked_user).toBeNull()
    const idle = NOW + BINDING_IDLE_MS + 1
    expect(o.submit("address.inbound.note", {}, system, idle).ok).toBe(true)
    expect(textAuthority(o.head.link!, idle + 1, "iMessage")).toBe("relink")
  })

  it("resubscribes only the recipient's own opt-out", () => {
    const o = owner()
    o.submit("address.suppress", { reason: "opted_out" }, system)
    o.submit("address.resubscribe", {}, system)
    expect(o.head.suppression).toBeNull()
    o.submit("address.suppress", { reason: "admin" }, system)
    o.submit("address.resubscribe", {}, system)
    expect(o.head.suppression?.reason).toBe("admin")
    expect(o.submit("address.resubscribe", {}, alice)).toEqual({ ok: false, code: "forbidden" })
  })

  it("STOP ends the binding", () => {
    const o = owner()
    o.submit("address.text_link.request", { user: "user_alice", code_hash: sha(PROOF) }, system)
    o.submit("address.text_link.confirm", { proof: PROOF }, alice)
    o.submit("address.suppress", { reason: "opted_out" }, system)
    expect(o.head.link?.binding).toBeNull()
  })
})

describe("text authority", () => {
  const bound = (lastInbound: number | null): LinkState => ({ pending: [], requests: [], binding: { user: "user_alice", bound_at: NOW, expires_at: NOW + BINDING_TTL_MS, last_inbound_at: lastInbound } })
  it("gives full power to iMessage, read and reply to SMS, and asks to relink when idle or expired", () => {
    expect(textAuthority(bound(NOW), NOW + 1000, "iMessage")).toBe("full")
    expect(textAuthority(bound(NOW), NOW + 1000, "SMS")).toBe("read_reply")
    expect(textAuthority(bound(NOW), NOW + 1000, "iMessage", "read_reply")).toBe("read_reply")
    expect(textAuthority(bound(NOW), NOW + 1000, "iMessage", "off")).toBe("none")
    expect(textAuthority(bound(NOW), NOW + BINDING_IDLE_MS + 1, "iMessage")).toBe("relink")
    expect(textAuthority(bound(NOW), NOW + BINDING_TTL_MS, "iMessage")).toBe("relink")
    expect(textAuthority({ pending: [], binding: null, requests: [] }, NOW, "iMessage")).toBe("relink")
    expect(textAuthority(bound(NOW), NOW + 1000, "iMessage", "full", true)).toBe("read_reply")
  })
})

describe("inbound parsing", () => {
  const ours = ["+14155550199"]
  const base = { is_outbound: false, message_handle: "h1", number: "+14155550100", to_number: "+14155550199", content: "hi chief", service: "iMessage", date_sent: new Date(NOW - 5_000).toISOString() }
  it("accepts a fresh inbound text to our line", () => {
    expect(parseInbound(base, ours, NOW)).toMatchObject({ ok: true, inbound: { handle: "h1", from: "+14155550100", line: "+14155550199", keyword: null } })
    expect(parseInbound({ ...base, content: " stop " }, ours, NOW)).toMatchObject({ ok: true, inbound: { keyword: "stop" } })
  })
  it("applies a late STOP, and treats YES as its own keyword", () => {
    expect(parseInbound({ ...base, content: "STOP", date_sent: new Date(NOW - 3_600_000).toISOString() }, ours, NOW)).toMatchObject({ ok: true, inbound: { keyword: "stop" } })
    expect(parseInbound({ ...base, content: "yes" }, ours, NOW)).toMatchObject({ ok: true, inbound: { keyword: "yes" } })
    expect(parseInbound({ ...base, content: "停止" }, ours, NOW)).toMatchObject({ ok: true, inbound: { keyword: "stop" } })
    expect(parseInbound({ ...base, to_number: "+14155550111", from_number: "+14155550199" }, ours, NOW)).toEqual({ ok: false, code: "inbound.not_our_line" })
  })

  it("refuses outbound, stale, foreign-line and self-sent payloads", () => {
    expect(parseInbound({ ...base, is_outbound: true }, ours, NOW)).toEqual({ ok: false, code: "inbound.not_inbound" })
    expect(parseInbound({ ...base, date_sent: new Date(NOW - 11 * 60_000).toISOString() }, ours, NOW)).toEqual({ ok: false, code: "inbound.stale" })
    expect(parseInbound({ ...base, to_number: "+14155550111" }, ours, NOW)).toEqual({ ok: false, code: "inbound.not_our_line" })
    expect(parseInbound({ ...base, number: "+14155550199" }, ours, NOW)).toEqual({ ok: false, code: "inbound.invalid" })
    expect(parseInbound({ ...base, date_sent: "garbage" }, ours, NOW)).toEqual({ ok: false, code: "inbound.stale" })
  })
})
