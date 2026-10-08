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
  const kinds: Record<string, string> = { inst_mac: "mac", inst_ios: "ios", inst_x: "mac" }
  const env: UserConfirmEnv = { user: USER, installActive: (i) => !revoked.has(i), installKind: (i) => kinds[i], chiefs: ["agent_a", "agent_b"], appIdHash: APP_ID_HASH, email: "owner@example.com" }
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
    if (r.ok) expect(Buffer.from((r.value as { message: string }).message, "base64url")).toEqual(proofMessage((r.value as { sign: ProofPayload }).sign))
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
    expect(kinds).toEqual(expect.arrayContaining(["mux.text_confirm.level.sync>MuxDO:agent_a", "mux.text_confirm.level.sync>MuxDO:agent_b", "feed.post>FeedDO:user_owner", "mail.security_notice>Mail:user_owner"]))
    const feed = h.outbox.filter((o) => o.kind === "feed.post").at(-1)!.payload as { title: string; body: string }
    expect(feed.body).toContain("Strict")
    expect(feed.body).toContain("Off")
  })

  it("collapses presence key notices to one feed item and one email per hour", async () => {
    const { securityNotice } = await import("../src/user/notices.ts")
    const env = { user: USER, email: "owner@example.com" }
    const a = securityNotice(env, "key_added", 1, { install: "i1", at: 7_200_000 })
    const b = securityNotice(env, "key_added", 2, { install: "i2", at: 7_200_000 + 60_000 })
    const mail = (n: typeof a) => n.find((o) => o.kind === "mail.security_notice")!
    expect(mail(a).entity).toBe(mail(b).entity)
    expect(mail(a).target?.coalesce).toBe(mail(b).target?.coalesce)
    const feed = (n: typeof a) => (n.find((o) => o.kind === "feed.post")!.payload as { dedupe_key?: string }).dedupe_key
    expect(feed(a)).toBe(feed(b))
    const lowered = securityNotice(env, "lowered", 3, { from: "strict", to: "off", install: "i1", at: 7_200_000 })
    expect(mail(lowered).target?.coalesce).toBeUndefined()
    expect(securityNotice({ user: USER }, "lowered", 4, { from: "strict", to: "off", install: "i1", at: 1 }).some((o) => o.kind === "mail.security_notice")).toBe(false)
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

  it("a policy lock is a minimum: it wins over a valid proof, never lowers, and unlock never lowers", () => {
    const { h, macKey, later, challenge } = ready()
    const p = challenge(mac, "off")!
    h.run("user.text_confirm.lock", { level: "strict", by: "mdm", name: "Acme IT" }, system, "script", later)
    expect(h.run(LOWER_OP, { level: "off", nonce: p.nonce, presence_sig: presenceSig(macKey.priv, p) }, mac, "user", later)).toMatchObject({ ok: false, code: "text_confirm.bad_nonce" })
    expect(h.run("user.text_confirm.lower.challenge", { level: "off" }, mac, "user", later)).toMatchObject({ ok: false, code: "text_confirm.locked" })
    h.run("user.text_confirm.lock", { level: "off", by: "team_policy", name: "Manaflow" }, system, "script", later)
    expect(userLevelOf(h.state)).toBe("strict")
    h.run("user.text_confirm.lock", { level: null, by: "mdm" }, system, "script", later)
    h.run("user.text_confirm.lock", { level: null, by: "team_policy" }, system, "script", later)
    expect(userLevelOf(h.state)).toBe("strict")
    expect(h.outbox.some((o) => o.kind === "feed.post" && String((o.payload as { title: string }).title).includes("lowered"))).toBe(false)
  })

  it("binds the key to the install kind and accepts only raw 64-byte signatures", () => {
    const { h, macKey, later, challenge } = ready()
    expect(h.run("user.presence_key.register", { install: "inst_ios", jwk: macKey.jwk, platform: "mac" }, system, "script")).toMatchObject({ ok: false, code: "forbidden" })
    const p = challenge(mac, "off")!
    const der = sign("sha256", proofMessage(p), macKey.priv).toString("base64url")
    expect(h.run(LOWER_OP, { level: "off", nonce: p.nonce, presence_sig: der }, mac, "user", later)).toMatchObject({ value: { lowered: false, code: "text_confirm.bad_proof" } })
  })

  it("migration never lowers (an unset level reads as strict) and comes only from this user's chiefs", () => {
    const h = host()
    const fromChief: Principal = { identity: "system:mux:agent_a", kind: "system" }
    expect(h.run("user.text_confirm.migrate", { level: "off" }, system, "script")).toMatchObject({ ok: false, code: "forbidden" })
    expect(h.run("user.text_confirm.migrate", { level: "off" }, { identity: "system:mux:agent_stranger", kind: "system" }, "script")).toMatchObject({ ok: false, code: "forbidden" })
    h.run("user.text_confirm.migrate", { level: "off" }, fromChief, "script")
    expect(userLevelOf(h.state)).toBe("strict")
  })
})

describe("presence proofs for another owner's request (full-shell team SSH certificates)", () => {
  const team: Principal = { identity: "system:team:team_a", kind: "system" }
  const purpose = (over: Record<string, unknown> = {}) => ({
    op: "team_vm.ssh_cert",
    team: "team_a",
    request: "req-1",
    key_fingerprint: `SHA256:${"A".repeat(43)}`,
    principal: "lawrence",
    validity_minutes: 30,
    class: "human",
    ...over
  })
  type Signed = Parameters<typeof proofMessage>[0]
  const ask = (h: ReturnType<typeof ready>["h"], install: string, at: number, pp = purpose()) => {
    const r = h.run("user.presence.challenge", { install, purpose: pp }, team, "script", at)
    if (!r.ok) return r
    const v = r.value as { sign: Signed; message: string; expires_at: number }
    expect(Buffer.from(v.message, "base64url")).toEqual(proofMessage(v.sign))
    return v
  }

  it("only a team's own object asks and asserts, for its own team", () => {
    const { h, later } = ready()
    for (const p of [mac, web, chief, system, { identity: "system:mux:agent_a", kind: "system" } as Principal])
      expect(h.run("user.presence.challenge", { install: "inst_mac", purpose: purpose() }, p, "script", later)).toMatchObject({ ok: false, code: "forbidden" })
    expect(h.run("user.presence.challenge", { install: "inst_mac", purpose: purpose({ team: "team_b" }) }, team, "script", later)).toMatchObject({ ok: false, code: "invalid_params" })
    expect(h.run("user.presence.challenge", { install: "inst_mac", purpose: purpose({ class: "agent" }) }, team, "script", later)).toMatchObject({ ok: false, code: "invalid_params" })
    expect(h.run("user.presence.challenge", { install: "inst_mac", purpose: { ...purpose(), extra: 1 } }, team, "script", later)).toMatchObject({ ok: false, code: "invalid_params" })
  })

  it("asserts a valid Mac proof of exactly the challenged purpose, once", () => {
    const { h, macKey, later } = ready()
    const v = ask(h, "inst_mac", later) as { sign: Signed; expires_at: number }
    expect(v.sign).toMatchObject({ ...purpose(), user: USER, install: "inst_mac" })
    const params = { install: "inst_mac", nonce: (v.sign as { nonce: string }).nonce, purpose: purpose(), presence_sig: presenceSig(macKey.priv, v.sign as ProofPayload) }
    expect(h.run("user.presence.assert", params, team, "script", later + 1)).toMatchObject({ ok: true, value: { asserted: true, expires_at: v.expires_at } })
    expect(h.run("user.presence.assert", params, team, "script", later + 2)).toMatchObject({ ok: false, code: "text_confirm.bad_nonce" })
    // The level did not change and nothing was announced; the assertion is audited.
    expect(userLevelOf(h.state)).toBe("strict")
    expect(h.state.audit.at(-1)).toMatchObject({ kind: "presence_asserted", install: "inst_mac", purpose: "team_vm.ssh_cert@team_a" })
  })

  it("refuses another purpose, an expired proof, a bad signature and a cooling key, and spends the nonce", () => {
    const { h, macKey, iosKey, attestKey, later } = ready()
    const assert = (v: { sign: Signed }, over: Record<string, unknown>, at = later + 1) =>
      h.run("user.presence.assert", { install: "inst_mac", nonce: (v.sign as { nonce: string }).nonce, purpose: purpose(), presence_sig: presenceSig(macKey.priv, v.sign as ProofPayload), ...over }, team, "script", at)
    let v = ask(h, "inst_mac", later) as { sign: Signed; expires_at: number }
    expect(assert(v, { purpose: purpose({ request: "req-2" }) })).toMatchObject({ ok: true, value: { asserted: false, code: "text_confirm.proof_mismatch" } })
    expect(assert(v, {})).toMatchObject({ ok: false, code: "text_confirm.bad_nonce" })
    v = ask(h, "inst_mac", later) as { sign: Signed; expires_at: number }
    expect(assert(v, {}, later + CHALLENGE_TTL_MS)).toMatchObject({ value: { asserted: false, code: "text_confirm.proof_expired" } })
    v = ask(h, "inst_mac", later) as { sign: Signed; expires_at: number }
    expect(assert(v, { presence_sig: presenceSig(keypair().priv, v.sign as ProofPayload) })).toMatchObject({ value: { asserted: false, code: "text_confirm.bad_proof" } })
    // A signature over the purpose with another op (a lowering) never asserts.
    v = ask(h, "inst_mac", later) as { sign: Signed; expires_at: number }
    expect(assert(v, { presence_sig: presenceSig(macKey.priv, { ...(v.sign as ProofPayload), op: LOWER_OP }) })).toMatchObject({ value: { asserted: false, code: "text_confirm.bad_proof" } })
    // iOS needs the App Attest assertion too, with a growing counter.
    const w = ask(h, "inst_ios", later) as { sign: Signed }
    const base = { install: "inst_ios", nonce: (w.sign as { nonce: string }).nonce, purpose: purpose(), presence_sig: presenceSig(iosKey.priv, w.sign as ProofPayload) }
    expect(h.run("user.presence.assert", { ...base, app_attest: assertion(attestKey.priv, w.sign as ProofPayload, 1) }, team, "script", later + 1)).toMatchObject({ value: { asserted: true } })
    // A key in its 24 h cooldown cannot be asked.
    h.run("user.presence_key.register", { install: "inst_x", jwk: keypair().jwk, platform: "mac" }, system, "script", later)
    expect(h.run("user.presence.challenge", { install: "inst_x", purpose: purpose() }, team, "script", later + 1)).toMatchObject({ ok: false, code: "text_confirm.key_cooling_down" })
  })

  it("never mixes with lowering: an SSH nonce never lowers the level and a lowering nonce never asserts; neither evicts the other", () => {
    const { h, macKey, later, challenge } = ready()
    const lower = challenge(mac, "off")!
    for (let i = 0; i < 12; i++) expect(h.run("user.presence.challenge", { install: "inst_mac", purpose: purpose({ team: `team_${i}` }) }, { identity: `system:team:team_${i}`, kind: "system" }, "script", later).ok).toBe(true)
    const v = ask(h, "inst_mac", later) as { sign: Signed }
    expect(h.run(LOWER_OP, { level: "off", nonce: (v.sign as { nonce: string }).nonce, presence_sig: presenceSig(macKey.priv, v.sign as ProofPayload) }, mac, "user", later + 1)).toMatchObject({ ok: false, code: "text_confirm.bad_nonce" })
    expect(h.run("user.presence.assert", { install: "inst_mac", nonce: lower.nonce, purpose: purpose(), presence_sig: presenceSig(macKey.priv, lower) }, team, "script", later + 1)).toMatchObject({ ok: false, code: "text_confirm.bad_nonce" })
    expect(h.run(LOWER_OP, { level: "off", nonce: lower.nonce, presence_sig: presenceSig(macKey.priv, lower) }, mac, "user", later + 1)).toMatchObject({ ok: true, value: { lowered: true } })
  })
})

describe("chief projection authority (MuxDO)", () => {
  it("accepts a level only from the owner's UserDO", async () => {
    const { muxDomain, INITIAL_MUX_HEAD } = await import("../src/mux/domain.ts")
    const head = { ...INITIAL_MUX_HEAD, agent: "agent_a", owner_user: USER }
    const sync = (identity: string) => muxDomain.authorize?.(head, "mux.text_confirm.level.sync", { level: "off", rev: 99 }, { identity, kind: "system" })
    expect(sync(`system:user:${USER}`)).toBeUndefined()
    expect(sync("system:feed:user_owner")).toMatchObject({ code: "forbidden" })
    expect(sync("system:user:user_other")).toMatchObject({ code: "forbidden" })
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
