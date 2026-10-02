import { describe, expect, it } from "vitest"
import type { Domain, Principal, RowWrite, StoredRow } from "../src/conversation/engine-types.ts"
import { contactDomain, INITIAL_CONTACT_HEAD, type ContactHead } from "../src/contact/domain.ts"
import { INITIAL_MUX_HEAD, muxDomain, TABLE_WAKE, type MuxHead } from "../src/mux/domain.ts"

/** A one-object owner: authorize, reduce, apply writes (what OwnerEngine does, minus the ledger). */
const owner = <S>(domain: Domain<S, Readonly<Record<string, unknown>>>, initial: S) => {
  let state = initial
  const rows = new Map<string, StoredRow>()
  const reader = {
    get: <T>(t: string, k: string) => rows.get(`${t}/${k}`) as StoredRow<T> | undefined,
    range: <T>(t: string, q: { limit: number; after?: number; before?: number; desc?: boolean }) =>
      [...rows.entries()]
        .filter(([k, r]) => k.startsWith(`${t}/`) && r.n !== null && r.n > (q.after ?? -Infinity) && r.n < (q.before ?? Infinity))
        .map(([, r]) => r)
        .sort((a, b) => (q.desc ? b.n! - a.n! : a.n! - b.n!))
        .slice(0, q.limit) as Array<StoredRow<T>>
  }
  let n = 0
  const submit = (op: string, params: Record<string, unknown>, principal: Principal, now = 1_790_000_000_000) => {
    const denied = domain.authorize?.(state, op, params, principal)
    if (denied) return { ok: false as const, code: denied.code }
    const r = domain.reduce(state, op, params, { principal, now, tx: `tx${++n}`, newId: (p) => `${p}${n}`, rows: reader })
    if (!r.ok) return { ok: false as const, code: r.code }
    state = r.state
    for (const w of (r.writes ?? []) as ReadonlyArray<RowWrite>) {
      if (w.op === "delete") rows.delete(`${w.table}/${w.key}`)
      else rows.set(`${w.table}/${w.key}`, { key: w.key, n: w.n ?? null, row: w.row })
    }
    return { ok: true as const, value: r.value, changed: r.changed ?? true, outbox: r.outbox ?? [] }
  }
  return { submit, get state() { return state }, rows }
}

const system: Principal = { identity: "system:conv", kind: "system" }
const chief: Principal = { identity: "inst_1", kind: "agent", agent: "agent_chief", user: "user_owner" }
const ownerSession: Principal = { identity: "user:user_owner", kind: "session", user: "user_owner" }
const stranger: Principal = { identity: "user:user_x", kind: "session", user: "user_x" }

describe("MuxDO wake queue", () => {
  const bound = () => {
    const o = owner<MuxHead>(muxDomain, INITIAL_MUX_HEAD)
    expect(o.submit("mux.bind", { agent: "agent_chief", owner_user: "user_owner", brain: "local" }, system).ok).toBe(true)
    return o
  }

  it("queues each wake once and ignores duplicates and acked seqs", () => {
    const o = bound()
    expect(o.submit("mux.wake", { conversation: "conv_a", seq: 3, reason: "dm" }, system)).toMatchObject({ ok: true, changed: true })
    expect(o.submit("mux.wake", { conversation: "conv_a", seq: 3, reason: "dm" }, system)).toMatchObject({ ok: true, changed: false })
    o.submit("mux.wake", { conversation: "conv_a", seq: 5, reason: "mention" }, system)
    o.submit("mux.wake", { conversation: "conv_b", seq: 1, reason: "owner" }, system)
    expect(o.state.pending).toBe(3)
    expect(o.submit("mux.ack", { conversation: "conv_a", seq: 4 }, chief)).toMatchObject({ ok: true, value: { cursor: 4, cleared: 1 } })
    expect(o.state.pending).toBe(2)
    expect(o.submit("mux.wake", { conversation: "conv_a", seq: 4, reason: "dm" }, system)).toMatchObject({ ok: true, changed: false })
    expect([...o.rows.keys()].sort()).toEqual([`${TABLE_WAKE}/conv_a:5`, `${TABLE_WAKE}/conv_b:1`])
  })

  it("lets only the chief ack, only the owner configure, only systems bind and wake", () => {
    const o = bound()
    expect(o.submit("mux.ack", { conversation: "conv_a", seq: 1 }, stranger)).toEqual({ ok: false, code: "forbidden" })
    expect(o.submit("mux.ack", { conversation: "conv_a", seq: 1 }, { ...chief, agent: "agent_other" })).toEqual({ ok: false, code: "forbidden" })
    expect(o.submit("mux.wake", { conversation: "conv_a", seq: 1, reason: "dm" }, ownerSession)).toEqual({ ok: false, code: "forbidden" })
    expect(o.submit("mux.configure", { brain: "cloud" }, stranger)).toEqual({ ok: false, code: "forbidden" })
    expect(o.submit("mux.configure", { brain: "cloud" }, ownerSession)).toMatchObject({ ok: true })
    expect(o.state.brain).toBe("cloud")
    expect(o.submit("mux.bind", { agent: "agent_other", owner_user: "user_owner", brain: "local" }, system)).toEqual({ ok: false, code: "mux.bound" })
  })

  it("refuses wakes before bind and malformed params", () => {
    const o = owner<MuxHead>(muxDomain, INITIAL_MUX_HEAD)
    expect(o.submit("mux.wake", { conversation: "conv_a", seq: 1, reason: "dm" }, system)).toEqual({ ok: false, code: "mux.unbound" })
    const b = bound()
    for (const bad of [{ conversation: "", seq: 1, reason: "dm" }, { conversation: "c", seq: 0, reason: "dm" }, { conversation: "c", seq: 1, reason: "poke" }])
      expect(b.submit("mux.wake", bad, system)).toEqual({ ok: false, code: "invalid_params" })
  })
})

describe("ContactDO deliveries", () => {
  const ensured = (channel: "email" | "sms" = "sms") => {
    const o = owner<ContactHead>(contactDomain, INITIAL_CONTACT_HEAD)
    expect(o.submit("contact.ensure", { contact: "contact_A", channel, address: channel === "sms" ? "+14155550100" : "a@example.com" }, system).ok).toBe(true)
    return o
  }
  const deliver = (o: ReturnType<typeof ensured>, invite: string, inviter: string, now?: number) =>
    o.submit("contact.deliver", { invite, conversation: "conv_dm_X", inviter }, system, now)

  it("sends once per invite, marks only the first text, and reports non-sends to the conversation", () => {
    const o = ensured()
    expect(deliver(o, "inv_1", "user_a")).toMatchObject({ ok: true, value: { send: true, state: "sending", first_text: true } })
    expect(deliver(o, "inv_1", "user_a")).toMatchObject({ ok: true, changed: false, value: { send: false } })
    const repeat = deliver(o, "inv_2", "user_a")
    expect(repeat).toMatchObject({ ok: true, value: { send: false, state: "repeat" } })
    expect(repeat.ok && repeat.outbox[0]).toMatchObject({ kind: "invite.delivery.report", entity: "delivery:inv_2:repeat", target: { class: "ConversationDO", name: "conv_dm_X" } })
    expect(deliver(o, "inv_3", "user_b")).toMatchObject({ value: { send: true, first_text: false } })
  })

  it("records provider results forward only and suppresses on bounce", () => {
    const o = ensured("email")
    deliver(o, "inv_1", "user_a")
    expect(o.submit("contact.delivery.record", { invite: "inv_1", state: "sent", provider_id: "re_1" }, system)).toMatchObject({ ok: true, changed: true })
    expect(o.submit("contact.delivery.record", { invite: "inv_1", state: "sending" }, system)).toMatchObject({ ok: true, changed: false })
    expect(o.submit("contact.delivery.record", { invite: "inv_1", state: "bounced" }, system)).toMatchObject({ ok: true, changed: true })
    expect(o.state.suppression?.reason).toBe("bounced")
    expect(o.submit("contact.delivery.record", { invite: "inv_1", state: "delivered" }, system)).toMatchObject({ ok: true, changed: false })
    expect(deliver(o, "inv_9", "user_z")).toMatchObject({ value: { send: false, state: "suppressed" } })
  })

  it("limits distinct inviters per recipient", () => {
    const o = ensured()
    for (const [i, who] of ["user_a", "user_b", "user_c"].entries()) expect(deliver(o, `inv_${i}`, who)).toMatchObject({ value: { send: true } })
    expect(deliver(o, "inv_9", "user_d")).toMatchObject({ value: { send: false, state: "recipient_limited" } })
  })

  it("only the verified owner of an email may unsuppress; everything else is system only", () => {
    const o = ensured("email")
    o.submit("contact.suppress", { reason: "opted_out" }, system)
    expect(o.submit("contact.unsuppress", {}, { identity: "u", kind: "session", user: "user_x", email: "other@example.com" })).toEqual({ ok: false, code: "forbidden" })
    expect(o.submit("contact.unsuppress", {}, { identity: "u", kind: "session", user: "user_x", email: "A@Example.com" })).toMatchObject({ ok: true })
    expect(o.state.suppression).toBeNull()
    expect(o.submit("contact.suppress", { reason: "opted_out" }, ownerSession)).toEqual({ ok: false, code: "forbidden" })
    expect(o.submit("contact.ensure", { contact: "contact_B", channel: "email", address: "b@example.com" }, system)).toEqual({ ok: false, code: "contact.mismatch" })
  })
})
