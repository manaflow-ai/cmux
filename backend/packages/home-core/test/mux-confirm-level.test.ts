import { describe, expect, it } from "vitest"
import type { Principal } from "../src/conversation/engine-types.ts"
import { LEVEL_CHANGE_TTL_MS, levelOf, MAX_AUDIT_ROWS, TABLE_LEVEL_AUDIT } from "../src/mux/confirm-level.ts"
import { INITIAL_MUX_HEAD, muxDomain, type MuxHead } from "../src/mux/domain.ts"
import { MemoryRows } from "./support/harness.ts"

const NOW = 1_790_000_000_000
const system: Principal = { identity: "system:team", kind: "system" }
const chief: Principal = { identity: "inst_c", kind: "agent", agent: "agent_chief", user: "user_owner" }
const app: Principal = { identity: "inst_m", kind: "install", install: "inst_m", install_kind: "ios", user: "user_owner" }
const daemon: Principal = { identity: "inst_d", kind: "install", install: "inst_d", install_kind: "daemon", user: "user_owner" }

const owner = (start: Partial<MuxHead> = {}) => {
  let head: MuxHead = { ...INITIAL_MUX_HEAD, ...start }
  const rows = new MemoryRows()
  let n = 0
  const submit = (op: string, params: Record<string, unknown>, p: Principal, origin: "user" | "remote" | "cli" | "script" = "user", now = NOW) => {
    const denied = muxDomain.authorize?.(head, op, params, p)
    if (denied) return { ok: false as const, code: denied.code }
    const r = muxDomain.reduce(head, op, params, { principal: p, now, tx: `t${++n}`, newId: (x) => `${x}_${n}`, rows, origin })
    if (!r.ok) return { ok: false as const, code: r.code }
    head = r.state
    rows.apply(r.writes ?? [])
    return { ok: true as const, value: r.value as Record<string, unknown>, changed: r.changed ?? true }
  }
  submit("mux.bind", { agent: "agent_chief", owner_user: "user_owner", brain: "cloud" }, system, "script")
  return { submit, rows, get head() { return head } }
}
const audit = (o: ReturnType<typeof owner>) => o.rows.range<{ kind: string; from: string; to: string }>(TABLE_LEVEL_AUDIT, { limit: 1000 }).map((r) => `${r.row.kind}:${r.row.from}>${r.row.to}`)

describe("text confirmation levels", () => {
  it("defaults to strict and migrates the old boolean (on -> strict, off -> off)", () => {
    expect(levelOf(owner().head)).toBe("strict")
    expect(levelOf(owner({ text_confirm: "destructive" }).head)).toBe("strict")
    expect(levelOf(owner({ text_confirm: "off" }).head)).toBe("off")
  })

  it("applies a safer level at once and audits it", () => {
    const o = owner({ text_confirm_level: "off" })
    expect(o.submit("mux.text_confirm.level.set", { level: "strict" }, app)).toMatchObject({ ok: true, value: { level: "strict" } })
    expect(levelOf(o.head)).toBe("strict")
    expect(audit(o)).toEqual(["set:off>strict"])
  })

  it("needs a second in-app confirmation for a riskier level, within 5 minutes, and audits each step", () => {
    const o = owner()
    const req = o.submit("mux.text_confirm.level.set", { level: "off" }, app)
    expect(req).toMatchObject({ ok: true, value: { level: "strict" } })
    expect(levelOf(o.head)).toBe("strict")
    const id = req.ok ? ((req.value.pending as { id: string }).id) : ""
    expect(o.submit("mux.text_confirm.level.confirm", { change: id, approve: true }, app)).toMatchObject({ ok: true, value: { level: "off" } })
    expect(levelOf(o.head)).toBe("off")
    expect(audit(o)).toEqual(["raise_requested:strict>off", "raise_confirmed:strict>off"])
    const p = owner()
    const r2 = p.submit("mux.text_confirm.level.set", { level: "destructive-only" }, app)
    const id2 = r2.ok ? ((r2.value.pending as { id: string }).id) : ""
    expect(p.submit("mux.text_confirm.level.confirm", { change: id2, approve: true }, app, "user", NOW + LEVEL_CHANGE_TTL_MS)).toMatchObject({ ok: true, value: { expired: true } })
    expect(levelOf(p.head)).toBe("strict")
  })

  it("a text, the chief, a daemon install or automation can neither lower the level nor confirm a raise", () => {
    const o = owner()
    const req = o.submit("mux.text_confirm.level.set", { level: "off" }, app)
    const id = req.ok ? ((req.value.pending as { id: string }).id) : ""
    // A text reaches MuxDO as a system or chief principal with origin remote.
    for (const [p, origin] of [[system, "remote"], [chief, "remote"], [daemon, "user"], [app, "remote"], [app, "cli"]] as const) {
      expect(o.submit("mux.text_confirm.level.set", { level: "off" }, p, origin).ok).toBe(false)
      expect(o.submit("mux.text_confirm.level.confirm", { change: id, approve: true }, p, origin).ok).toBe(false)
    }
    expect(levelOf(o.head)).toBe("strict")
  })

  it("a policy lock wins, names who locked it, clears a pending raise, and unlock keeps the level", () => {
    const o = owner()
    const req = o.submit("mux.text_confirm.level.set", { level: "off" }, app)
    const id = req.ok ? ((req.value.pending as { id: string }).id) : ""
    expect(o.submit("mux.text_confirm.lock", { level: "strict", by: "team_policy", name: "Manaflow" }, system, "script")).toMatchObject({ ok: true })
    expect(o.head.text_confirm_lock?.team_policy).toMatchObject({ level: "strict", by: "team_policy", name: "Manaflow" })
    expect(o.submit("mux.text_confirm.level.confirm", { change: id, approve: true }, app)).toEqual({ ok: false, code: "text_confirm.no_pending_change" })
    expect(o.submit("mux.text_confirm.level.set", { level: "off" }, app)).toEqual({ ok: false, code: "text_confirm.locked" })
    expect(o.submit("mux.text_confirm.level.set", { level: "destructive-only" }, app)).toEqual({ ok: false, code: "text_confirm.locked" })
    expect(o.submit("mux.text_confirm.lock", { level: "off", by: "mdm", name: "x" }, app)).toEqual({ ok: false, code: "forbidden" })
    expect(levelOf(o.head)).toBe("strict")
    o.submit("mux.text_confirm.lock", { level: null, by: "team_policy" }, system, "script")
    expect(o.head.text_confirm_lock?.team_policy).toBeUndefined()
    expect(levelOf(o.head)).toBe("strict")
    expect(audit(o)).toEqual(["raise_requested:strict>off", "lock:strict>strict", "unlock:strict>strict"])
    expect(o.rows.range<{ by: string }>(TABLE_LEVEL_AUDIT, { limit: 10 }).at(-1)?.row.by).toBe("system:team")
  })

  it("keeps one lock per source: the safest wins and one source cannot lift the other", () => {
    const o = owner()
    o.submit("mux.text_confirm.lock", { level: "strict", by: "mdm", name: "Acme IT" }, system, "script")
    o.submit("mux.text_confirm.lock", { level: "off", by: "team_policy", name: "Manaflow" }, system, "script")
    expect(levelOf(o.head)).toBe("strict")
    o.submit("mux.text_confirm.lock", { level: null, by: "team_policy" }, system, "script")
    expect(levelOf(o.head)).toBe("strict")
    expect(o.head.text_confirm_lock?.mdm?.name).toBe("Acme IT")
    // Selecting the locked level is a no-op, not an error.
    expect(o.submit("mux.text_confirm.level.set", { level: "strict" }, app)).toMatchObject({ ok: true, changed: false })
  })

  it("refuses a stale raise when the level moved since it was asked", () => {
    const o = owner()
    const req = o.submit("mux.text_confirm.level.set", { level: "off" }, app)
    const id = req.ok ? ((req.value.pending as { id: string }).id) : ""
    // Simulate a level change that left the pending raise in place (not reachable through the ops today).
    o.submit("mux.text_confirm.lock", { level: "destructive-only", by: "mdm", name: "x" }, system, "script")
    expect(o.submit("mux.text_confirm.level.confirm", { change: id, approve: true }, app)).toEqual({ ok: false, code: "text_confirm.no_pending_change" })
    expect(levelOf(o.head)).toBe("destructive-only")
  })

  it("a declined raise keeps the level; the audit keeps at most 100 rows", () => {
    const o = owner()
    for (let i = 0; i < 60; i++) {
      const r = o.submit("mux.text_confirm.level.set", { level: "off" }, app)
      const id = r.ok ? ((r.value.pending as { id: string }).id) : ""
      o.submit("mux.text_confirm.level.confirm", { change: id, approve: false }, app)
    }
    expect(levelOf(o.head)).toBe("strict")
    expect(o.rows.range(TABLE_LEVEL_AUDIT, { limit: 1000 }).length).toBe(MAX_AUDIT_ROWS)
  })
})

describe("Settings copy for the levels", () => {
  it("has every key in all 21 locales, keeps {name}, and states the number-takeover risk", async () => {
    const { readFileSync } = await import("node:fs")
    const copy = JSON.parse(readFileSync(new URL("../copy/text-confirm-levels.json", import.meta.url), "utf8")) as { strings: Record<string, Record<string, { value: string; state: string }>> }
    const keys = Object.keys(copy.strings)
    expect(keys).toHaveLength(9)
    for (const key of keys) {
      expect(Object.keys(copy.strings[key]!)).toHaveLength(21)
      for (const [locale, entry] of Object.entries(copy.strings[key]!)) {
        expect(entry.value.length).toBeGreaterThan(0)
        expect(entry.state).toBe(locale === "en" || locale === "ja" ? "translated" : "needs_review")
        if (key === "textConfirm.lockedBy") expect(entry.value).toContain("{name}")
      }
    }
    expect(copy.strings["textConfirm.simSwapRisk"]!.en!.value).toMatch(/SIM swap/)
  })
})
