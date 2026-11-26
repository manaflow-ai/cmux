import { describe, expect, it } from "vitest"
import {
  APPKV_MAX_APP_BYTES,
  APPKV_MAX_APPS,
  APPKV_MAX_VALUE_BYTES,
  appKvRowKey,
  makeAppKvDomain,
  TABLE_ITEM,
  type AppKvHead,
  type AppKvRow
} from "../src/appkv/index.ts"
import type { Principal } from "../src/conversation/engine-types.ts"
import { DomainHost } from "./support/harness.ts"

const USER = "user_alice"
const mac: Principal = { kind: "install", identity: "install:inst_mac", user: USER, install: "inst_mac", grant: "grant_mac" }
const phone: Principal = { kind: "install", identity: "install:inst_phone", user: USER, install: "inst_phone", grant: "grant_phone" }
const bob: Principal = { kind: "install", identity: "install:inst_bob", user: "user_bob", install: "inst_bob", grant: "grant_bob" }
const system: Principal = { kind: "system", identity: "system:test" }

/** The host's gate, as UserDO passes it: this user only. */
const host = () => new DomainHost<AppKvHead, Readonly<Record<string, unknown>>>(makeAppKvDomain((p) => (p.user === USER ? undefined : { code: "auth.forbidden", message: "not this user" })))
const rows = (h: ReturnType<typeof host>) => h.rows.all<AppKvRow>(TABLE_ITEM)

describe("appkv domain (storage:synced)", () => {
  it("two installs of one user write one store; the last write to a key wins", () => {
    const h = host()
    expect(h.run(mac, "appkv.set", { app: "cmux/todo", key: "item:1", value: { title: "milk", done: false } }, "k1").ok).toBe(true)
    h.now += 5
    const second = h.run(phone, "appkv.set", { app: "cmux/todo", key: "item:1", value: { title: "milk", done: true } }, "k2")
    expect(second.ok && second.value).toMatchObject({ app: "cmux/todo", key: "item:1", value: { title: "milk", done: true }, revision: 2, updated_ms: h.now })
    expect(rows(h)).toEqual([{ app: "cmux/todo", key: "item:1", value: { title: "milk", done: true }, revision: 2, updated_ms: h.now }])
    expect(h.rows.get(TABLE_ITEM, appKvRowKey("cmux/todo", "item:1"))?.n).toBe(2)
    expect(h.state.apps["cmux/todo"]).toEqual({ keys: 1, bytes: "item:1".length + JSON.stringify({ title: "milk", done: true }).length })
  })

  it("a delete removes the row and its usage; deleting a missing key is a no-op", () => {
    const h = host()
    h.run(mac, "appkv.set", { app: "cmux/todo", key: "a", value: 1 }, "s")
    const del = h.run(phone, "appkv.delete", { app: "cmux/todo", key: "a" }, "d")
    expect(del.ok && del.value).toEqual({ app: "cmux/todo", key: "a", existed: true })
    expect(rows(h)).toEqual([])
    expect(h.state.apps).toEqual({})
    const again = h.run(phone, "appkv.delete", { app: "cmux/todo", key: "a" }, "d2")
    expect(again.ok && again.changed).toBe(false)
    expect(again.ok && again.value).toEqual({ app: "cmux/todo", key: "a", existed: false })
  })

  it("an idempotent retry replays the first answer and writes nothing new", () => {
    const h = host()
    const first = h.run(mac, "appkv.set", { app: "notes", key: "k", value: "one" }, "same-key")
    h.run(phone, "appkv.set", { app: "notes", key: "k", value: "two" }, "other")
    const retry = h.run(mac, "appkv.set", { app: "notes", key: "k", value: "one" }, "same-key")
    expect(retry.replayed).toBe(true)
    expect(retry.ok && first.ok && retry.value).toEqual(first.ok && first.value)
    expect(rows(h)[0]!.value).toBe("two")
    expect(h.state.revision).toBe(2)
  })

  it("setting the same value again changes nothing", () => {
    const h = host()
    h.run(mac, "appkv.set", { app: "notes", key: "k", value: { a: [1, 2] } }, "1")
    const same = h.run(phone, "appkv.set", { app: "notes", key: "k", value: { a: [1, 2] } }, "2")
    expect(same.ok && same.changed).toBe(false)
    expect(h.state.revision).toBe(1)
  })

  it("compares nested object values independent of field order while preserving array order", () => {
    const h = host()
    h.run(mac, "appkv.set", { app: "notes", key: "k", value: { a: { x: 1, y: 2 }, b: [1, 2] } }, "1")
    const same = h.run(phone, "appkv.set", { app: "notes", key: "k", value: { b: [1, 2], a: { y: 2, x: 1 } } }, "2")
    expect(same.ok && same.changed).toBe(false)
    expect(h.state.revision).toBe(1)
    h.run(phone, "appkv.set", { app: "notes", key: "k", value: { b: [2, 1], a: { y: 2, x: 1 } } }, "3")
    expect(h.state.revision).toBe(2)
  })

  it("rejects malformed Unicode before hashing instead of overwriting or deleting another key", () => {
    const h = host()
    h.run(mac, "appkv.set", { app: "a", key: "\ufffd", value: "keep" }, "seed")
    for (const bad of ["\ud800", "\udfff", "x\ud800y"]) {
      for (const op of ["appkv.set", "appkv.delete"]) {
        expect(h.run(mac, op, { app: "a", key: bad, value: 1 }, `${op}-key-${bad}`)).toMatchObject({ ok: false, code: "validation.invalid" })
        expect(h.run(mac, op, { app: bad, key: "k", value: 1 }, `${op}-app-${bad}`)).toMatchObject({ ok: false, code: "validation.invalid" })
      }
    }
    expect(rows(h)).toEqual([expect.objectContaining({ key: "\ufffd", value: "keep" })])
    expect(h.run(mac, "appkv.set", { app: "\ud83d\udcdd", key: "\ud83d\udd11", value: 1 }, "paired").ok).toBe(true)
    expect(h.run(mac, "appkv.set", { app: "a\u0085", key: "k", value: 1 }, "control")).toMatchObject({ ok: false, code: "validation.invalid" })
  })

  it("refuses another user, system principals and unknown ops", () => {
    const h = host()
    expect(h.run(bob, "appkv.set", { app: "a", key: "k", value: 1 }, "b")).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(h.run(system, "appkv.set", { app: "a", key: "k", value: 1 }, "s")).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(h.run(mac, "appkv.clear", { app: "a" }, "c")).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(rows(h)).toEqual([])
  })

  it("validates app, key and value", () => {
    const h = host()
    const bad = (params: Record<string, unknown>) => h.run(mac, "appkv.set", params, crypto.randomUUID())
    expect(bad({ app: "", key: "k", value: 1 })).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(bad({ app: "a\nb", key: "k", value: 1 })).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(bad({ app: "a".repeat(129), key: "k", value: 1 })).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(bad({ app: "a", key: "", value: 1 })).toMatchObject({ ok: false, code: "validation.invalid" })
    // 256 bytes is the bound in UTF-8 bytes, not characters: 86 three-byte characters are 258 bytes.
    expect(bad({ app: "a", key: "€".repeat(86), value: 1 })).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(bad({ app: "a", key: "k".repeat(256), value: 1 }).ok).toBe(true)
    expect(bad({ app: "a", key: "k" })).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(bad({ app: "a", key: "k", value: null }).ok).toBe(true)
  })

  it("enforces 64 KiB per value and 4 MiB per app with app.limit", () => {
    const h = host()
    const big = "x".repeat(APPKV_MAX_VALUE_BYTES - 2) // JSON adds the two quotes
    expect(h.run(mac, "appkv.set", { app: "a", key: "fits", value: big }, "f").ok).toBe(true)
    expect(h.run(mac, "appkv.set", { app: "a", key: "over", value: big + "x" }, "o")).toMatchObject({ ok: false, code: "app.limit" })
    // Fill the app to just under 4 MiB, then one more value does not fit; another app still does.
    const perKey = 1 + APPKV_MAX_VALUE_BYTES // one-character keys "0".."9", then two characters
    let i = 0
    while (h.state.apps["b"] === undefined || h.state.apps["b"].bytes + perKey + 1 <= APPKV_MAX_APP_BYTES) {
      const r = h.run(mac, "appkv.set", { app: "b", key: String(i), value: big }, `fill${i}`)
      expect(r.ok, JSON.stringify(r)).toBe(true)
      i++
    }
    expect(h.run(mac, "appkv.set", { app: "b", key: "one-more", value: big }, "full")).toMatchObject({ ok: false, code: "app.limit" })
    expect(h.state.apps["b"]!.bytes).toBeLessThanOrEqual(APPKV_MAX_APP_BYTES)
    // Overwriting an existing key with a smaller value still fits: usage counts the old value out.
    expect(h.run(mac, "appkv.set", { app: "b", key: "0", value: "small" }, "shrink").ok).toBe(true)
    expect(h.run(mac, "appkv.set", { app: "c", key: "k", value: big }, "other-app").ok).toBe(true)
  })

  it(`holds at most ${APPKV_MAX_APPS} apps`, () => {
    const h = host()
    for (let i = 0; i < APPKV_MAX_APPS; i++) expect(h.run(mac, "appkv.set", { app: `app${i}`, key: "k", value: i }, `a${i}`).ok).toBe(true)
    expect(h.run(mac, "appkv.set", { app: "one-too-many", key: "k", value: 1 }, "x")).toMatchObject({ ok: false, code: "app.limit" })
    expect(h.run(mac, "appkv.set", { app: "app0", key: "k2", value: 1 }, "y").ok).toBe(true)
  })

  it("app ids that name Object.prototype members (__proto__, toString, constructor) are counted and limited like any other", () => {
    const big = "x".repeat(APPKV_MAX_VALUE_BYTES - 2)
    const perKey = 1 + APPKV_MAX_VALUE_BYTES
    for (const app of ["__proto__", "toString", "constructor", "hasOwnProperty"]) {
      const h = host()
      expect(h.run(mac, "appkv.set", { app, key: "a", value: 1 }, "first").ok).toBe(true)
      // Usage is the app's own entry, a number, not a prototype member or NaN.
      expect(Object.hasOwn(h.state.apps, app)).toBe(true)
      expect(h.state.apps[app]).toEqual({ keys: 1, bytes: "a".length + "1".length })
      expect(Object.getPrototypeOf(h.state.apps)).toBe(Object.prototype)
      // The 4 MiB per-app limit holds for it.
      let i = 0
      while (h.state.apps[app]!.bytes + perKey + 1 <= APPKV_MAX_APP_BYTES) expect(h.run(mac, "appkv.set", { app, key: String(i), value: big }, `fill${i++}`).ok).toBe(true)
      expect(h.run(mac, "appkv.set", { app, key: "one-more", value: big }, "full")).toMatchObject({ ok: false, code: "app.limit" })
      // A delete of its last key removes the entry.
      for (const row of rows(h)) h.run(mac, "appkv.delete", { app, key: row.key }, `del-${row.key}`)
      expect(h.state.apps).toEqual({})
    }
    // It counts toward the app limit, too.
    const h = host()
    expect(h.run(mac, "appkv.set", { app: "__proto__", key: "k", value: 0 }, "p").ok).toBe(true)
    for (let i = 1; i < APPKV_MAX_APPS; i++) expect(h.run(mac, "appkv.set", { app: `app${i}`, key: "k", value: i }, `a${i}`).ok).toBe(true)
    expect(h.run(mac, "appkv.set", { app: "one-too-many", key: "k", value: 1 }, "x")).toMatchObject({ ok: false, code: "app.limit" })
  })
})
