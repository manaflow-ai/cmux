import { createHash, generateKeyPairSync, sign, type KeyObject } from "node:crypto"
import { describe, expect, it } from "vitest"
import type { OutboxItem, Principal } from "../src/conversation/engine-types.ts"
import { chiefLevelOf, reduceProjection } from "../src/mux/level-projection.ts"
import { proofMessage, LOWER_OP, type ProofPayload } from "../src/user/device-proof.ts"
import {
  authorizeUserConfirm,
  EMPTY_USER_CONFIRM,
  NEW_KEY_COOLDOWN_MS,
  CHALLENGE_TTL_MS,
  reduceUserConfirm,
  userLevelOf,
  type UserConfirmEnv,
  type UserConfirmState
} from "../src/user/text-confirm-user.ts"
import { MemoryRows } from "./support/harness.ts"

const NOW = 1_790_000_000_000
const USER = "user_owner"
const system: Principal = { identity: "system:worker", kind: "system" }
const mac: Principal = { identity: "inst_mac", kind: "install", install: "inst_mac", install_kind: "mac", user: USER }
const phone: Principal = { identity: "inst_ios", kind: "install", install: "inst_ios", install_kind: "ios", user: USER }
const web: Principal = { identity: "user:owner", kind: "session", user: USER }
const chief: Principal = { identity: "inst_c", kind: "agent", agent: "agent_chief", user: USER }
const APP_ID_HASH = createHash("sha256").update("TEAMID.com.cmuxterm.app").digest("base64url")

const keypair = () => {
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" })
  const { kty, crv, x, y } = publicKey.export({ format: "jwk" })
  return { priv: privateKey, jwk: { kty, crv, x, y } }
}
const presenceSig = (priv: KeyObject, p: ProofPayload) => sign("sha256", proofMessage(p), { key: priv, dsaEncoding: "ieee-p1363" }).toString("base64url")
const cborBytes = (b: Buffer) => Buffer.concat([b.length < 24 ? Buffer.from([0x40 + b.length]) : b.length < 256 ? Buffer.from([0x58, b.length]) : Buffer.from([0x59, b.length >> 8, b.length & 255]), b])
const cborText = (t: string) => Buffer.concat([Buffer.from([0x60 + t.length]), Buffer.from(t)])
const assertion = (priv: KeyObject, p: ProofPayload, counter: number, appIdHash = APP_ID_HASH) => {
  const auth = Buffer.concat([Buffer.from(appIdHash, "base64url"), Buffer.from([0x01]), Buffer.from([counter >>> 24, (counter >>> 16) & 255, (counter >>> 8) & 255, counter & 255])])
  const nonce = createHash("sha256").update(Buffer.concat([auth, createHash("sha256").update(proofMessage(p)).digest()])).digest()
  const sig = sign("sha256", nonce, priv)
  return Buffer.concat([Buffer.from([0xa2]), cborText("signature"), cborBytes(sig), cborText("authenticatorData"), cborBytes(auth)]).toString("base64url")
}

const host = (revoked: Set<string> = new Set()) => {
  let s: UserConfirmState = EMPTY_USER_CONFIRM
  let n = 0
  const outbox: Array<OutboxItem> = []
  const env: UserConfirmEnv = { user: USER, installActive: (i) => !revoked.has(i), chiefs: ["agent_a", "agent_b"] }
  const run = (op: string, params: Record<string, unknown>, p: Principal, origin: "user" | "remote" | "script" = "user", now = NOW) => {
    if (!authorizeUserConfirm(op, p, env)) return { ok: false as const, code: "forbidden" }
    const r = reduceUserConfirm(s, op, params, { principal: p, now, tx: `t${++n}`, newId: (x) => `${x}_${n}_${Math.random().toString(36).slice(2)}`, rows: new MemoryRows(), origin }, env)
    if (!r.ok) return r
    s = r.state
    outbox.push(...(r.outbox ?? []))
    return r
  }
  return { run, outbox, get state() { return s }, revoked }
}

/** Registers keys, waits out the cooldown, and returns a signer for one lowering. */
const ready = () => {
  const h = host(new Set())
  const macKey = keypair()
  const iosKey = keypair()
  const attestKey = keypair()
  h.run("user.presence_key.register", { install: "inst_mac", jwk: macKey.jwk, platform: "mac" }, system, "script")
  h.run("user.presence_key.register", { install: "inst_ios", jwk: iosKey.jwk, platform: "ios", app_attest: { jwk: attestKey.jwk, app_id_hash: APP_ID_HASH, counter: 0 } }, system, "script")
  const later = NOW + NEW_KEY_COOLDOWN_MS
  const challenge = (p: Principal, level: string) => {
    const r = h.run("user.text_confirm.lower.challenge", { level }, p, "user", later)
    return r.ok ? ((r.value as { sign: ProofPayload }).sign) : null
  }
  return { h, macKey, iosKey, attestKey, later, challenge }
}

describe("per-user level and lowering with a device proof", () => {
  it("applies a safer level at once and refuses a riskier one without a proof", () => {
    const h = host()
    expect(h.run("user.text_confirm.level.set", { level: "off" }, web)).toMatchObject({ ok: false, code: "text_confirm.proof_required" })
    h.state // strict by default
    expect(userLevelOf(h.state)).toBe("strict")
  })

  it("lowers with a valid Mac presence proof, syncs every chief, and notifies by feed and email", () => {
    const { h, macKey, later, challenge } = ready()
    const p = challenge(mac, "off")!
    expect(p).toMatchObject({ op: LOWER_OP, user: USER, install: "inst_mac", new_level: "off" })
    const r = h.run(LOWER_OP, { level: "off", nonce: p.nonce, presence_sig: presenceSig(macKey.priv, p) }, mac, "user", later + 1)
    expect(r).toMatchObject({ ok: true, value: { lowered: true, level: "off" } })
    expect(userLevelOf(h.state)).toBe("off")
    const kinds = h.outbox.map((o) => `${o.kind}>${o.target?.class}:${o.target?.name}`)
    expect(kinds).toEqual(expect.arrayContaining(["mux.text_confirm.level.sync>MuxDO:agent_a", "mux.text_confirm.level.sync>MuxDO:agent_b", "feed.post>FeedDO:user_owner", "mail.security_notice>MailerDO:user_owner"]))
    const feed = h.outbox.filter((o) => o.kind === "feed.post").at(-1)!.payload as { title: string; body: string }
    expect(feed.body).toContain("Strict")
    expect(feed.body).toContain("Off")
  })

  it("refuses: no proof, a stale proof, a replayed nonce, a proof for another op or level, and spends the nonce each time", () => {
    const { h, macKey, later, challenge } = ready()
    let p = challenge(mac, "off")!
    expect(h.run(LOWER_OP, { level: "off", nonce: p.nonce }, mac, "user", later)).toMatchObject({ ok: true, value: { lowered: false, code: "text_confirm.bad_proof" } })
    expect(h.run(LOWER_OP, { level: "off", nonce: p.nonce, presence_sig: presenceSig(macKey.priv, p) }, mac, "user", later)).toMatchObject({ ok: false, code: "text_confirm.bad_nonce" })
    p = challenge(mac, "off")!
    expect(h.run(LOWER_OP, { level: "off", nonce: p.nonce, presence_sig: presenceSig(macKey.priv, p) }, mac, "user", later + CHALLENGE_TTL_MS)).toMatchObject({ value: { lowered: false, code: "text_confirm.proof_expired" } })
    p = challenge(mac, "off")!
    const otherOp = presenceSig(macKey.priv, { ...p, op: "user.something_else" as typeof LOWER_OP })
    expect(h.run(LOWER_OP, { level: "off", nonce: p.nonce, presence_sig: otherOp }, mac, "user", later)).toMatchObject({ value: { lowered: false, code: "text_confirm.bad_proof" } })
    p = challenge(mac, "destructive-only")!
    const otherLevel = presenceSig(macKey.priv, { ...p, new_level: "off" })
    expect(h.run(LOWER_OP, { level: "destructive-only", nonce: p.nonce, presence_sig: otherLevel }, mac, "user", later)).toMatchObject({ value: { lowered: false, code: "text_confirm.bad_proof" } })
    p = challenge(mac, "off")!
    expect(h.run(LOWER_OP, { level: "destructive-only", nonce: p.nonce, presence_sig: presenceSig(macKey.priv, p) }, mac, "user", later)).toMatchObject({ value: { lowered: false, code: "text_confirm.proof_mismatch" } })
    expect(userLevelOf(h.state)).toBe("strict")
    expect(h.state.audit.filter((a) => a.kind === "lower_refused")).toHaveLength(5)
  })

  it("refuses a proof from a revoked device (presence key revoked, or install revoked)", () => {
    const { h, macKey, later, challenge } = ready()
    const p = challenge(mac, "off")!
    h.run("user.presence_key.revoke", { install: "inst_mac" }, web)
    expect(h.run(LOWER_OP, { level: "off", nonce: p.nonce, presence_sig: presenceSig(macKey.priv, p) }, mac, "user", later)).toMatchObject({ ok: false, code: "text_confirm.bad_nonce" })
    expect(challenge(mac, "off")).toBeNull()
    const r = ready()
    const q = r.challenge(mac, "off")!
    r.h.revoked.add("inst_mac")
    expect(r.h.run(LOWER_OP, { level: "off", nonce: q.nonce, presence_sig: presenceSig(r.macKey.priv, q) }, mac, "user", r.later)).toMatchObject({ value: { lowered: false, code: "text_confirm.no_presence_key" } })
  })

  it("on iOS needs both the presence signature and a fresh App Attest assertion (counter must grow)", () => {
    const { h, iosKey, attestKey, later, challenge } = ready()
    let p = challenge(phone, "destructive-only")!
    expect(h.run(LOWER_OP, { level: "destructive-only", nonce: p.nonce, presence_sig: presenceSig(iosKey.priv, p) }, phone, "user", later)).toMatchObject({ value: { lowered: false, code: "text_confirm.bad_proof" } })
    p = challenge(phone, "destructive-only")!
    expect(h.run(LOWER_OP, { level: "destructive-only", nonce: p.nonce, presence_sig: presenceSig(iosKey.priv, p), app_attest: assertion(attestKey.priv, p, 5, createHash("sha256").update("x").digest("base64url")) }, phone, "user", later)).toMatchObject({ value: { lowered: false } })
    p = challenge(phone, "destructive-only")!
    expect(h.run(LOWER_OP, { level: "destructive-only", nonce: p.nonce, presence_sig: presenceSig(iosKey.priv, p), app_attest: assertion(attestKey.priv, p, 5) }, phone, "user", later)).toMatchObject({ value: { lowered: true } })
    expect(h.state.presence_keys.inst_ios?.app_attest?.counter).toBe(5)
    h.run("user.text_confirm.level.set", { level: "strict" }, web, "user", later)
    p = challenge(phone, "off")!
    expect(h.run(LOWER_OP, { level: "off", nonce: p.nonce, presence_sig: presenceSig(iosKey.priv, p), app_attest: assertion(attestKey.priv, p, 5) }, phone, "user", later)).toMatchObject({ value: { lowered: false, code: "text_confirm.bad_proof" } })
  })

  it("a text, the chief, a web session, a non-user origin, or a new key in cooldown cannot lower", () => {
    const { h, macKey, later, challenge } = ready()
    for (const [p, origin] of [[system, "remote"], [chief, "remote"], [web, "user"], [mac, "remote"]] as const)
      expect(h.run("user.text_confirm.lower.challenge", { level: "off" }, p, origin, later).ok).toBe(false)
    expect(h.run("user.text_confirm.lower.challenge", { level: "off" }, mac, "user", NOW + 1)).toMatchObject({ ok: false, code: "text_confirm.key_cooling_down" })
    const p = challenge(mac, "off")!
    expect(h.run(LOWER_OP, { level: "off", nonce: p.nonce, presence_sig: presenceSig(macKey.priv, p) }, mac, "remote", later)).toMatchObject({ ok: false, code: "forbidden" })
    expect(h.run("user.presence_key.register", { install: "inst_x", jwk: macKey.jwk, platform: "mac" }, mac).ok).toBe(false)
  })

  it("a policy lock wins over a valid proof; one source cannot lift the other", () => {
    const { h, macKey, later, challenge } = ready()
    const p = challenge(mac, "off")!
    h.run("user.text_confirm.lock", { level: "strict", by: "mdm", name: "Acme IT" }, system, "script", later)
    expect(h.run(LOWER_OP, { level: "off", nonce: p.nonce, presence_sig: presenceSig(macKey.priv, p) }, mac, "user", later)).toMatchObject({ ok: false, code: "text_confirm.bad_nonce" })
    expect(h.run("user.text_confirm.lower.challenge", { level: "off" }, mac, "user", later)).toMatchObject({ ok: false, code: "text_confirm.locked" })
    h.run("user.text_confirm.lock", { level: "off", by: "team_policy", name: "Manaflow" }, system, "script", later)
    h.run("user.text_confirm.lock", { level: null, by: "team_policy" }, system, "script", later)
    expect(userLevelOf(h.state)).toBe("strict")
  })

  it("migrates per-chief values to the safest, and only ever safer", () => {
    const h = host()
    h.run("user.text_confirm.migrate", { level: "off" }, system, "script")
    expect(userLevelOf(h.state)).toBe("off")
    h.run("user.text_confirm.migrate", { level: "destructive-only" }, system, "script")
    h.run("user.text_confirm.migrate", { level: "off" }, system, "script")
    expect(userLevelOf(h.state)).toBe("destructive-only")
  })
})

describe("chief projection (MuxDO)", () => {
  const ctx = (n: number) => ({ principal: system, now: NOW, tx: `t${n}`, newId: (x: string) => `${x}${n}`, rows: new MemoryRows(), origin: "script" as const })
  it("keeps the newest rev and sends the old per-chief level to UserDO once", () => {
    let head = { owner_user: USER, text_confirm: "off" as const }
    expect(chiefLevelOf(head)).toBe("off")
    const m = reduceProjection(head, "mux.text_confirm.migrate", {}, ctx(1))
    expect(m.ok && m.outbox).toEqual([{ kind: "user.text_confirm.migrate", entity: "migrate:t1", payload: { level: "off" }, target: { class: "UserDO", name: USER } }])
    head = (m.ok ? m.state : head) as typeof head
    expect(reduceProjection(head, "mux.text_confirm.migrate", {}, ctx(2))).toMatchObject({ ok: true, changed: false })
    const s1 = reduceProjection(head, "mux.text_confirm.level.sync", { level: "strict", rev: 3 }, ctx(3))
    const h1 = s1.ok ? s1.state : head
    expect(reduceProjection(h1, "mux.text_confirm.level.sync", { level: "off", rev: 2 }, ctx(4))).toMatchObject({ ok: true, changed: false })
    expect(chiefLevelOf(h1)).toBe("strict")
  })
})
