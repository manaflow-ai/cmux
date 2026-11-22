import { describe, expect, it } from "vitest"
import type { Principal } from "../src/conversation/engine-types.ts"
import { INITIAL_MUX_HEAD, muxDomain, type MuxHead } from "../src/mux/domain.ts"
import { CONFIRM_TTL_MS, MAX_PENDING_CONFIRMS, needsConfirmation } from "../src/mux/text-confirm.ts"
import { MemoryRows } from "./support/harness.ts"

const NOW = 1_790_000_000_000
const system: Principal = { identity: "system:conv", kind: "system" }
const chief: Principal = { identity: "inst_c", kind: "agent", agent: "agent_chief", user: "user_owner" }
const ownerApp: Principal = { identity: "user:user_owner", kind: "session", user: "user_owner" }
const stranger: Principal = { identity: "user:user_x", kind: "session", user: "user_x" }

const owner = () => {
  let head: MuxHead = INITIAL_MUX_HEAD
  const rows = new MemoryRows()
  let n = 0
  const submit = (op: string, params: Record<string, unknown>, p: Principal, now = NOW, origin: "user" | "cli" = "user") => {
    const denied = muxDomain.authorize?.(head, op, params, p)
    if (denied) return { ok: false as const, code: denied.code }
    const r = muxDomain.reduce(head, op, params, { principal: p, now, tx: `t${++n}`, newId: (x) => `${x}_${n}`, rows, origin })
    if (!r.ok) return { ok: false as const, code: r.code }
    head = r.state
    rows.apply(r.writes ?? [])
    return { ok: true as const, value: r.value as Record<string, unknown>, changed: r.changed ?? true }
  }
  submit("mux.bind", { agent: "agent_chief", owner_user: "user_owner", brain: "cloud" }, system)
  return { submit, get head() { return head } }
}
const ask = { op: "vm.delete", params_hash: "h1", risk: "destructive", summary: "Delete VM build-box", source: { conversation: "conv_C", seq: 7 } }

describe("text confirmation rule", () => {
  it("asks only for destructive, money or irreversible actions requested by text, unless turned off", () => {
    expect(needsConfirmation({ channel: "text", risk: "destructive", level: "strict" })).toBe(true)
    expect(needsConfirmation({ channel: "text", risk: "money", level: "strict" })).toBe(true)
    expect(needsConfirmation({ channel: "text", risk: "execute", irreversible: true, level: "strict" })).toBe(true)
    expect(needsConfirmation({ channel: "text", risk: "execute", level: "strict" })).toBe(false)
    expect(needsConfirmation({ channel: "text", risk: "send-external", level: "strict" })).toBe(true)
    expect(needsConfirmation({ channel: "text", risk: "access", level: "strict" })).toBe(true)
    expect(needsConfirmation({ channel: "text", risk: "mutate-shared", level: "strict" })).toBe(false)
    expect(needsConfirmation({ channel: "app", risk: "destructive", level: "strict" })).toBe(false)
    expect(needsConfirmation({ channel: "text", risk: "destructive", level: "off" })).toBe(false)
    expect(needsConfirmation({ channel: "text", risk: "destructive", level: "destructive-only" })).toBe(true)
    expect(needsConfirmation({ channel: "text", risk: "execute", irreversible: true, level: "destructive-only" })).toBe(true)
    for (const risk of ["money", "send-external", "access"] as const) expect(needsConfirmation({ channel: "text", risk, level: "destructive-only" })).toBe(false)
  })
})

describe("pending confirmations in MuxDO", () => {
  it("runs request -> owner approves in the app -> chief consumes exactly that action, once", () => {
    const o = owner()
    const req = o.submit("mux.confirm.request", ask, chief)
    expect(req).toMatchObject({ ok: true, value: { state: "pending" } })
    const id = req.ok ? (req.value.id as string) : ""
    expect(o.submit("mux.confirm.consume", { confirm: id, op: "vm.delete", params_hash: "h1" }, chief)).toEqual({ ok: false, code: "confirm.pending" })
    expect(o.submit("mux.confirm.decide", { confirm: id, approve: true }, ownerApp)).toMatchObject({ ok: true, value: { state: "approved", decided_by: "user_owner" } })
    expect(o.submit("mux.confirm.decide", { confirm: id, approve: false }, ownerApp)).toEqual({ ok: false, code: "confirm.decided" })
    expect(o.submit("mux.confirm.consume", { confirm: id, op: "vm.delete", params_hash: "OTHER" }, chief)).toEqual({ ok: false, code: "confirm.mismatch" })
    expect(o.submit("mux.confirm.consume", { confirm: id, op: "vm.delete", params_hash: "h1" }, chief)).toMatchObject({ ok: true, value: { state: "consumed" } })
    expect(o.submit("mux.confirm.consume", { confirm: id, op: "vm.delete", params_hash: "h1" }, chief)).toEqual({ ok: false, code: "confirm.not_approved" })
  })

  it("lets only the owner's app decide: never the chief, a text (system), or another user", () => {
    const o = owner()
    const req = o.submit("mux.confirm.request", ask, chief)
    const id = req.ok ? (req.value.id as string) : ""
    for (const p of [chief, system, stranger, { identity: "x", kind: "agent" as const, agent: "agent_other", user: "user_owner" }])
      expect(o.submit("mux.confirm.decide", { confirm: id, approve: true }, p)).toEqual({ ok: false, code: "forbidden" })
    expect(o.submit("mux.confirm.request", ask, ownerApp)).toEqual({ ok: false, code: "forbidden" })
    // The owner's daemon or CLI install (where a chief may run) and automation origins cannot decide.
    const daemon: Principal = { identity: "inst_d", kind: "install", install: "inst_d", install_kind: "daemon", user: "user_owner" }
    const macApp: Principal = { identity: "inst_m", kind: "install", install: "inst_m", install_kind: "mac", user: "user_owner" }
    expect(o.submit("mux.confirm.decide", { confirm: id, approve: true }, daemon)).toEqual({ ok: false, code: "forbidden" })
    expect(o.submit("mux.confirm.decide", { confirm: id, approve: true }, { ...macApp, agent: "agent_chief" })).toEqual({ ok: false, code: "forbidden" })
    expect(o.submit("mux.confirm.decide", { confirm: id, approve: true }, macApp, NOW, "cli")).toEqual({ ok: false, code: "forbidden" })
    expect(o.submit("mux.confirm.decide", { confirm: id, approve: true }, macApp)).toMatchObject({ ok: true })
    expect(o.submit("mux.text_confirm.level.set", { level: "off" }, chief)).toEqual({ ok: false, code: "forbidden" })
  })

  it("declines, expires, and refuses a consume after a decline or expiry", () => {
    const o = owner()
    const a = o.submit("mux.confirm.request", ask, chief)
    const b = o.submit("mux.confirm.request", ask, chief)
    const ida = a.ok ? (a.value.id as string) : ""
    const idb = b.ok ? (b.value.id as string) : ""
    o.submit("mux.confirm.decide", { confirm: ida, approve: false }, ownerApp)
    expect(o.submit("mux.confirm.consume", { confirm: ida, op: "vm.delete", params_hash: "h1" }, chief)).toEqual({ ok: false, code: "confirm.not_approved" })
    expect(o.submit("mux.confirm.decide", { confirm: idb, approve: true }, ownerApp, NOW + CONFIRM_TTL_MS)).toEqual({ ok: false, code: "confirm.expired" })
  })

  it("caps live pending confirmations, and expired ones stop counting", () => {
    const o = owner()
    for (let i = 0; i < MAX_PENDING_CONFIRMS; i++) expect(o.submit("mux.confirm.request", ask, chief).ok).toBe(true)
    expect(o.submit("mux.confirm.request", ask, chief)).toEqual({ ok: false, code: "confirm.too_many" })
    expect(o.submit("mux.confirm.request", ask, chief, NOW + CONFIRM_TTL_MS).ok).toBe(true)
  })

  it("keeps at most 64 rows; an evicted approval fails closed", () => {
    const o = owner()
    const first = o.submit("mux.confirm.request", ask, chief)
    const id = first.ok ? (first.value.id as string) : ""
    o.submit("mux.confirm.decide", { confirm: id, approve: true }, ownerApp)
    for (let i = 0; i < 70; i++) expect(o.submit("mux.confirm.request", ask, chief, NOW + (i + 1) * CONFIRM_TTL_MS).ok).toBe(true)
    expect(o.submit("mux.confirm.consume", { confirm: id, op: "vm.delete", params_hash: "h1" }, chief, NOW + 1)).toEqual({ ok: false, code: "confirm.unknown" })
  })

  it("refuses malformed requests", () => {
    const o = owner()
    expect(o.submit("mux.confirm.request", { ...ask, risk: "nuke" }, chief)).toEqual({ ok: false, code: "invalid_params" })
    expect(o.submit("mux.confirm.request", { ...ask, source: { conversation: "c", seq: 0 } }, chief)).toEqual({ ok: false, code: "invalid_params" })
  })
})
