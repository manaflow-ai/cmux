import { describe, expect, it } from "vitest"
import type { Domain, Principal, RowWrite, StoredRow } from "../src/conversation/engine-types.ts"
import { addressDomain, INITIAL_ADDRESS_HEAD, type AddressHead } from "../src/address/domain.ts"
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
    o.submit("mux.wake", { conversation: "conv_a", seq: 2, reason: "mention" }, system)
    o.submit("mux.wake", { conversation: "conv_b", seq: 1, reason: "owner" }, system)
    expect(o.state.pending).toBe(4)
    expect(o.submit("mux.ack", { conversation: "conv_a", seq: 4 }, chief)).toMatchObject({ ok: true, value: { cursor: 4, cleared: 2 } })
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

  it("keeps the head bounded per conversation and across conversations", () => {
    const o = bound()
    for (let seq = 1; seq <= 250; seq++) o.submit("mux.wake", { conversation: "conv_big", seq, reason: "mention" }, system)
    expect(o.state.queues.conv_big!.pending).toHaveLength(200)
    expect(o.state.pending).toBe(200)
    expect([...o.rows.keys()].filter((k) => k.startsWith(`${TABLE_WAKE}/conv_big:`))).toHaveLength(200)
    for (let i = 0; i < 600; i++) {
      o.submit("mux.wake", { conversation: `conv_${i}`, seq: 1, reason: "dm" }, system, 1_790_000_000_000 + i)
      o.submit("mux.ack", { conversation: `conv_${i}`, seq: 1 }, chief, 1_790_000_000_000 + i)
    }
    expect(Object.keys(o.state.queues).length).toBeLessThanOrEqual(500)
    expect(o.state.queues.conv_big).toBeDefined()
  })

  it("refuses wakes before bind and malformed params", () => {
    const o = owner<MuxHead>(muxDomain, INITIAL_MUX_HEAD)
    expect(o.submit("mux.wake", { conversation: "conv_a", seq: 1, reason: "dm" }, system)).toEqual({ ok: false, code: "mux.unbound" })
    const b = bound()
    for (const bad of [{ conversation: "", seq: 1, reason: "dm" }, { conversation: "c", seq: 0, reason: "dm" }, { conversation: "c", seq: 1, reason: "poke" }])
      expect(b.submit("mux.wake", bad, system)).toEqual({ ok: false, code: "invalid_params" })
  })
})

describe("AddressDO deliveries", () => {
  const ensured = (channel: "email" | "sms" = "sms") => {
    const o = owner<AddressHead>(addressDomain, INITIAL_ADDRESS_HEAD)
    expect(o.submit("address.ensure", { id: "addr_A", channel, value: channel === "sms" ? "+14155550100" : "a@example.com" }, system).ok).toBe(true)
    return o
  }
  // The exact DeliveryIntent shape ConversationDO puts in its outbox (conversation/fanout.ts).
  const deliver = (o: ReturnType<typeof ensured>, invite: string, inviter: string, now?: number) =>
    o.submit("address.deliver", { invite, conversation: "conv_dm_X", address: "addr_A", channel: "sms", locale: "en", copy_variant: "A", invited_by: inviter }, system, now)

  it("sends once per invite, marks only the first text, and reports non-sends to the conversation", () => {
    const o = ensured()
    expect(deliver(o, "inv_1", "user_a")).toMatchObject({ ok: true, value: { send: true, state: "sending", first_text: true } })
    expect(deliver(o, "inv_1", "user_a")).toMatchObject({ ok: true, changed: false, value: { send: false } })
    const repeat = deliver(o, "inv_2", "user_a")
    expect(repeat).toMatchObject({ ok: true, value: { send: false, state: "repeat" } })
    // The conversation never learns why: a repeat reports as suppressed, with no provider id.
    expect(repeat.ok && repeat.outbox[0]).toEqual({
      kind: "invite.delivery.report",
      entity: "delivery:inv_2:suppressed",
      payload: { invite_id: "inv_2", delivery: { state: "suppressed" } },
      target: { class: "ConversationDO", name: "conv_dm_X" }
    })
    expect(deliver(o, "inv_3", "user_b")).toMatchObject({ value: { send: true, first_text: false } })
  })

  it("records provider results forward only and suppresses on bounce", () => {
    const o = ensured("email")
    deliver(o, "inv_1", "user_a")
    const sent = o.submit("address.delivery.record", { invite: "inv_1", state: "sent", provider_id: "re_1" }, system)
    expect(sent).toMatchObject({ ok: true, changed: true })
    expect(sent.ok && sent.outbox[0]?.payload).toEqual({ invite_id: "inv_1", delivery: { state: "sent", provider_id: "re_1" } })
    const unknown = o.submit("address.delivery.record", { invite: "inv_1", state: "indeterminate" }, system)
    expect(unknown.ok && unknown.outbox).toEqual([])
    expect(o.submit("address.delivery.record", { invite: "inv_1", state: "sending" }, system)).toMatchObject({ ok: true, changed: false })
    expect(o.submit("address.delivery.record", { invite: "inv_1", state: "bounced" }, system)).toMatchObject({ ok: true, changed: true })
    expect(o.state.suppression?.reason).toBe("bounced")
    expect(o.submit("address.delivery.record", { invite: "inv_1", state: "delivered" }, system)).toMatchObject({ ok: true, changed: false })
    expect(deliver(o, "inv_9", "user_z")).toMatchObject({ value: { send: false, state: "suppressed" } })
  })

  it("limits distinct inviters per recipient", () => {
    const o = ensured()
    for (const [i, who] of ["user_a", "user_b", "user_c"].entries()) expect(deliver(o, `inv_${i}`, who)).toMatchObject({ value: { send: true } })
    expect(deliver(o, "inv_9", "user_d")).toMatchObject({ value: { send: false, state: "recipient_limited" } })
  })

  it("only the verified owner of an email may unsuppress; everything else is system only", () => {
    const o = ensured("email")
    o.submit("address.suppress", { reason: "opted_out" }, system)
    expect(o.submit("address.deliver", { invite: "i", conversation: "c", address: "addr_Z", invited_by: "user_a" }, system)).toEqual({ ok: false, code: "address.mismatch" })
    expect(o.submit("address.unsuppress", {}, { identity: "u", kind: "session", user: "user_x", email: "other@example.com" })).toEqual({ ok: false, code: "forbidden" })
    // An unverified claim of the address is not ownership.
    expect(o.submit("address.unsuppress", {}, { identity: "u", kind: "session", user: "user_x", email: "A@Example.com" })).toEqual({ ok: false, code: "forbidden" })
    expect(o.submit("address.unsuppress", {}, { identity: "u", kind: "session", user: "user_x", email: "A@Example.com", email_verified: true })).toMatchObject({ ok: true })
    expect(o.state.suppression).toBeNull()
    o.submit("address.suppress", { reason: "admin" }, system)
    expect(o.submit("address.unsuppress", {}, { identity: "u", kind: "session", user: "user_x", email: "a@example.com", email_verified: true })).toEqual({ ok: false, code: "forbidden" })
    expect(o.submit("address.suppress", { reason: "opted_out" }, ownerSession)).toEqual({ ok: false, code: "forbidden" })
    expect(o.submit("address.ensure", { id: "addr_B", channel: "email", value: "b@example.com" }, system)).toEqual({ ok: false, code: "address.mismatch" })
  })
})
