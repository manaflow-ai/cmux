import { describe, expect, it } from "bun:test"
import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { Admission, userIdForLogin } from "../src/admission.ts"
import type { ObjectState } from "../src/do-runtime/object-state.ts"
import { DoRuntime, type ObjectClass } from "../src/do-runtime/runtime.ts"
import { isTailnetAddress, parseStatus, parseWhois } from "../src/tailscale.ts"
import { PEERS, tailnet } from "./support.ts"

/** A tiny object: counts calls in SQL, and records alarm fires. */
class Counter {
  constructor(private readonly ctx: ObjectState) {
    ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS n (k TEXT PRIMARY KEY, v INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS fired (at INTEGER NOT NULL)")
  }
  async bump(k: string, arg: { list: Array<number> }) {
    arg.list.push(99) // a copy: the caller's object must not change
    this.ctx.storage.sql.exec("INSERT INTO n (k, v) VALUES (?, 1) ON CONFLICT(k) DO UPDATE SET v = v + 1", k)
    return this.ctx.storage.sql.exec<{ v: number }>("SELECT v FROM n WHERE k = ?", k).one().v
  }
  async arm(at: number) {
    await this.ctx.storage.setAlarm(at)
  }
  async fires() {
    return this.ctx.storage.sql.exec("SELECT at FROM fired").toArray().length
  }
  async alarm() {
    this.ctx.storage.sql.exec("INSERT INTO fired (at) VALUES (?)", Date.now())
  }
}

describe("DoRuntime", () => {
  it("one object per name, copied RPC arguments, multi-statement batches, durable rows", async () => {
    const dir = mkdtempSync(join(tmpdir(), "do-runtime-"))
    const rt = new DoRuntime(dir, {})
    rt.register("COUNTER", "Counter", Counter as unknown as ObjectClass)
    const ns = rt.env.COUNTER as { idFromName(n: string): { name: string }; get(id: { name: string }): Counter }
    const arg = { list: [1] }
    expect(await ns.get(ns.idFromName("a")).bump("x", arg)).toBe(1)
    expect(await ns.get(ns.idFromName("a")).bump("x", arg)).toBe(2)
    expect(await ns.get(ns.idFromName("b")).bump("x", arg)).toBe(1)
    expect(arg.list).toEqual([1])
    rt.stop()
    const again = new DoRuntime(dir, {})
    again.register("COUNTER", "Counter", Counter as unknown as ObjectClass)
    expect(await (again.stub("COUNTER", "a") as unknown as Counter).bump("x", { list: [] })).toBe(3)
    again.stop()
  })

  it("an alarm set before a restart fires after it", async () => {
    const dir = mkdtempSync(join(tmpdir(), "do-runtime-"))
    const rt = new DoRuntime(dir, {})
    rt.register("COUNTER", "Counter", Counter as unknown as ObjectClass)
    await (rt.stub("COUNTER", "a") as unknown as Counter).arm(Date.now() - 1)
    rt.stop()
    const again = new DoRuntime(dir, {})
    again.register("COUNTER", "Counter", Counter as unknown as ObjectClass)
    expect(await again.rearmAlarms()).toBe(1)
    await again.quiesce()
    expect(await (again.stub("COUNTER", "a") as unknown as Counter).fires()).toBe(1)
    again.stop()
  })
})

describe("Tailscale admission", () => {
  it("parses WhoIs: a person, a tagged node", () => {
    expect(parseWhois(`Warning: version skew\n{"Node":{"Name":"bob-mac.tail0.ts.net.","Tags":[]},"UserProfile":{"LoginName":"Bob@Example.com","DisplayName":"Bob"}}`)).toEqual({ ok: true, login: "bob@example.com", display_name: "Bob", node: "bob-mac.tail0.ts.net" })
    expect(parseWhois(`{"Node":{"Name":"ci.tail0.ts.net.","Tags":["tag:ci"]},"UserProfile":{"LoginName":"tagged-devices"}}`)).toEqual({ ok: false, code: "tagged_node" })
    expect(parseStatus(`{"Self":{"TailscaleIPs":["100.89.1.2"],"DNSName":"mini.tail0.ts.net.","UserID":7,"Tags":["tag:server"]},"User":{"7":{"LoginName":"a@b.c"}}}`)).toEqual({ addresses: ["100.89.1.2"], dns_name: "mini.tail0.ts.net", login: null, tagged: true })
  })

  it("tailnet ranges only", () => {
    for (const a of ["100.64.0.1", "100.127.255.254", "fd7a:115c:a1e0::4b36:d670", "::ffff:100.100.1.1"]) expect(isTailnetAddress(a)).toBe(true)
    for (const a of ["100.63.0.1", "100.128.0.1", "10.0.0.1", "192.168.1.2", "fe80::1", "8.8.8.8"]) expect(isTailnetAddress(a)).toBe(false)
  })

  it("admits owner, allow list and loopback; one stable user id per login", async () => {
    const net = tailnet()
    const admission = new Admission(net, () => ({ owner: "alice@example.com", allow: ["BOB@example.com"] }), () => [PEERS.self])
    const alice = await admission.admit(PEERS.alice)
    expect(alice.ok && alice.principal.user).toBe(userIdForLogin("ALICE@example.com"))
    expect((await admission.admit(PEERS.bob)).ok).toBe(true)
    expect((await admission.admit("127.0.0.1")).ok).toBe(true)
    expect(await admission.admit(PEERS.carol)).toEqual({ ok: false, code: "not_allowed", reason: "not_in_allow_list" })
    expect(await admission.admit(PEERS.tagged)).toEqual({ ok: false, code: "not_allowed", reason: "tagged_node" })
    expect(await admission.admit(PEERS.self)).toEqual({ ok: false, code: "not_allowed", reason: "self_address" })
    expect(await admission.admit(PEERS.outside)).toEqual({ ok: false, code: "not_allowed", reason: "not_tailnet" })
  })
})
