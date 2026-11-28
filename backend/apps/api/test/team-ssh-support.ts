import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import type { Principal } from "@cmux/ownership"
import { importJWK, SignJWT, type JWK } from "jose"
import { expect } from "vitest"

/** Shared helpers for the team SSH CA tests (team-ssh-ca.test.ts, team-ssh-presence.test.ts). */
export const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; TEAM_DO: DurableObjectNamespace; USER_DO: DurableObjectNamespace }
export const worker = (exports as unknown as { default: Fetcher }).default
export const inDO = runInDurableObject as unknown as <T>(stub: unknown, fn: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>

export interface Reply {
  ok: boolean
  value?: any
  error?: { code: string; message: string; retryable: boolean }
  replayed: boolean
}
export interface TeamStub {
  sshOp(entity: string, principal: Principal, frame: { op: string; params: unknown; idempotency_key: string }): Promise<Reply>
  readOp(entity: string, principal: Principal, op: string, params: unknown): Promise<any>
}

// ---------- SSH wire helpers for checking what the CA produced ----------
export const unb64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0))
export const b64 = (b: Uint8Array) => btoa(String.fromCharCode(...b))
const dec = new TextDecoder()
class Rd {
  o = 0
  constructor(readonly b: Uint8Array) {}
  u32() {
    const v = new DataView(this.b.buffer, this.b.byteOffset + this.o, 4).getUint32(0)
    this.o += 4
    return v
  }
  u64() {
    const v = Number(new DataView(this.b.buffer, this.b.byteOffset + this.o, 8).getBigUint64(0))
    this.o += 8
    return v
  }
  str() {
    const n = this.u32()
    const s = this.b.subarray(this.o, this.o + n)
    this.o += n
    return s
  }
  txt() {
    return dec.decode(this.str())
  }
}
const list = (b: Uint8Array) => {
  const r = new Rd(b)
  const out: Array<string> = []
  while (r.o < b.length) out.push(r.txt())
  return out
}
const pairs = (b: Uint8Array) => {
  const r = new Rd(b)
  const out: Record<string, string> = {}
  while (r.o < b.length) {
    const k = r.txt()
    const v = r.str()
    out[k] = v.length ? new Rd(v).txt() : ""
  }
  return out
}

/** Parses an OpenSSH user certificate and checks its Ed25519 signature against `caLine`. */
export const readCert = async (line: string, caLine: string) => {
  const [type, body] = line.split(" ")
  const blob = unb64(body!)
  const r = new Rd(blob)
  expect(r.txt()).toBe(type)
  r.str() // nonce
  if (type === "ssh-ed25519-cert-v01@openssh.com") r.str()
  else (r.str(), r.str())
  const serial = r.u64()
  const certType = r.u32()
  const keyId = r.txt()
  const principals = list(r.str())
  const validAfter = r.u64()
  const validBefore = r.u64()
  const critical = pairs(r.str())
  const extensions = pairs(r.str())
  r.str()
  const sigKey = r.str()
  const signed = blob.subarray(0, r.o)
  const sig = new Rd(r.str())
  expect(sig.txt()).toBe("ssh-ed25519")
  const signature = sig.str()
  expect(b64(sigKey)).toBe(caLine.split(" ")[1])
  const caPk = new Rd(sigKey)
  caPk.txt()
  const pub = await crypto.subtle.importKey("raw", caPk.str(), { name: "Ed25519" }, false, ["verify"])
  const verified = await crypto.subtle.verify("Ed25519", pub, signature, signed)
  return { serial, certType, keyId, principals, validAfter, validBefore, critical, extensions, verified }
}

/** Serials listed in a KRL's certificate sections, and the explicitly revoked key blobs (base64). */
export const readKrl = (krlB64: string) => {
  const b = unb64(krlB64)
  expect(dec.decode(b.subarray(0, 8))).toBe("SSHKRL\n\0")
  const r = new Rd(b)
  r.o = 8
  r.u32()
  const version = r.u64()
  r.u64()
  r.u64()
  r.str()
  r.str()
  const serials: Array<number> = []
  const keys: Array<string> = []
  while (r.o < b.length) {
    const t = b[r.o++]!
    const data = r.str()
    if (t === 1) {
      const s = new Rd(data)
      s.str()
      s.str()
      while (s.o < data.length) {
        expect(data[s.o++]).toBe(0x20)
        const ls = new Rd(s.str())
        while (ls.o < ls.b.length) serials.push(ls.u64())
      }
    } else if (t === 2) {
      const s = new Rd(data)
      while (s.o < data.length) keys.push(b64(s.str()))
    }
  }
  return { version, serials, keys }
}

export const sshLine = async (kind: "ed25519" | "p256") => {
  if (kind === "ed25519") {
    const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair
    const pk = new Uint8Array((await crypto.subtle.exportKey("raw", pair.publicKey)) as ArrayBuffer)
    const enc = (s: Uint8Array | string) => {
      const v = typeof s === "string" ? new TextEncoder().encode(s) : s
      return [0, 0, (v.length >> 8) & 255, v.length & 255, ...v]
    }
    return `ssh-ed25519 ${b64(Uint8Array.from([...enc("ssh-ed25519"), ...enc(pk)]))} me@laptop`
  }
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
  const q = new Uint8Array((await crypto.subtle.exportKey("raw", pair.publicKey)) as ArrayBuffer)
  const enc = (v: Uint8Array) => [0, 0, 0, v.length, ...v]
  const t = new TextEncoder()
  return `ecdsa-sha2-nistp256 ${b64(Uint8Array.from([...enc(t.encode("ecdsa-sha2-nistp256")), ...enc(t.encode("nistp256")), ...enc(q)]))} se@mac`
}


// ---------- the CA in TeamDO ----------
export const sessionToken = async (stackUser: string, name: string) => {
  const key = await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256")
  return new SignJWT({ email: `${stackUser}@acme.com`, email_verified: true, name })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(stackUser)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(key)
}
export const api = async (token: string, path: "/v1/ops" | "/v1/read", body: Record<string, unknown>) => {
  const res = await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, body: JSON.stringify(body) })
  return (await res.json()) as any
}
export const mutate = (token: string, op: string, params: unknown, key: string = crypto.randomUUID()) => api(token, "/v1/ops", { op, params, idempotency_key: key, origin: "cli" })

/** A personal team (owner from a session) plus a seeded plain member. */
export const setup = async (stackUser: string) => {
  const token = await sessionToken(stackUser, "Lawrence Chen")
  const ensured = await mutate(token, "user.ensure", {})
  const owner = ensured.value.id as string
  const team = ensured.value.personal_team as string
  const stub = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team))
  const member = `user_${stackUser.replace(/[^0-9]/g, "").padStart(20, "9")}`
  await inDO(stub, async (instance) => {
    const engine = instance.boundEngine
    engine.state = { ...engine.currentState, members: { ...engine.currentState.members, [member]: { user: member, role: "member", display_name: "Aziz" } } }
  })
  const rpc = stub as unknown as TeamStub
  const ownerP: Principal = { identity: `session:${owner}`, kind: "session", user: owner, team }
  const memberP: Principal = { identity: `session:${member}`, kind: "session", user: member, team }
  const install = (user: string, classes: Array<string>, kind = "mac", id = "inst_00000000000000000081"): Principal => ({
    identity: id,
    kind: "install",
    user,
    team,
    install: id,
    grant: "grant_00000000000000000081",
    grant_classes: classes,
    install_kind: kind
  })
  const op = (p: Principal, name: string, params: unknown, key: string = crypto.randomUUID()) => rpc.sshOp(team, p, { op: name, params, idempotency_key: key })
  const ca = async () => (await rpc.readOp(team, ownerP, "team_vm.ssh_ca", {})) as { value: { generation: number; trusted_ca_keys: Array<string>; krl: string; krl_version: number } }
  return { token, owner, member, team, stub, ownerP, memberP, install, op, ca }
}

