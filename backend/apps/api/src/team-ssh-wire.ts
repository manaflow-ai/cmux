/**
 * OpenSSH wire formats for the team SSH CA (plans/cmux-next/team-vm-plan.md S3): user public
 * keys (RFC 4253 6.6, RFC 5656 3.1), user certificates (OpenSSH PROTOCOL.certkeys) and key
 * revocation lists (OpenSSH PROTOCOL.krl). Pure byte code with no I/O; signing is the caller's.
 */

const enc = new TextEncoder()

export const toBase64 = (b: Uint8Array): string => {
  let s = ""
  for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode(...b.subarray(i, i + 0x8000))
  return btoa(s)
}

const fromBase64 = (s: string): Uint8Array | null => {
  try {
    return Uint8Array.from(atob(s), (c) => c.charCodeAt(0))
  } catch {
    return null
  }
}

const concat = (parts: ReadonlyArray<Uint8Array>): Uint8Array => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0))
  let o = 0
  for (const p of parts) {
    out.set(p, o)
    o += p.length
  }
  return out
}

export const u32 = (n: number): Uint8Array => {
  const b = new Uint8Array(4)
  new DataView(b.buffer).setUint32(0, n)
  return b
}

export const u64 = (n: number): Uint8Array => {
  const b = new Uint8Array(8)
  new DataView(b.buffer).setBigUint64(0, BigInt(n))
  return b
}

/** SSH `string`: uint32 length, then the bytes. */
export const sshString = (v: Uint8Array | string): Uint8Array => {
  const b = typeof v === "string" ? enc.encode(v) : v
  return concat([u32(b.length), b])
}

class Reader {
  private o = 0
  constructor(private readonly b: Uint8Array) {}
  string(): Uint8Array | null {
    if (this.o + 4 > this.b.length) return null
    const n = new DataView(this.b.buffer, this.b.byteOffset + this.o, 4).getUint32(0)
    if (this.o + 4 + n > this.b.length) return null
    const s = this.b.subarray(this.o + 4, this.o + 4 + n)
    this.o += 4 + n
    return s
  }
  get done(): boolean {
    return this.o === this.b.length
  }
}

const text = (b: Uint8Array | null) => (b ? new TextDecoder().decode(b) : null)

export type UserKeyType = "ssh-ed25519" | "ecdsa-sha2-nistp256"

/** A parsed user public key: its wire blob and the type-specific fields a certificate repeats. */
export interface UserKey {
  readonly type: UserKeyType
  readonly blob: Uint8Array
  /** ssh-ed25519: [pk]; ecdsa-sha2-nistp256: [curve name, Q]. */
  readonly fields: ReadonlyArray<Uint8Array>
}

const LINE = /^(ssh-ed25519|ecdsa-sha2-nistp256) ([A-Za-z0-9+/]+={0,2})(?: [\x20-\x7e]{0,200})?$/

/**
 * Parses one authorized_keys style line. Only Ed25519 and ECDSA P-256 keys (a Secure Enclave
 * key is P-256); RSA, DSA and certificates are refused. The ECDSA point is checked by importing it.
 */
export const parseUserKey = async (line: string): Promise<UserKey | null> => {
  const m = LINE.exec(line.trim())
  if (!m) return null
  const type = m[1] as UserKeyType
  const blob = fromBase64(m[2]!)
  if (!blob || blob.length > 200) return null
  const r = new Reader(blob)
  if (text(r.string()) !== type) return null
  if (type === "ssh-ed25519") {
    const pk = r.string()
    if (!pk || pk.length !== 32 || !r.done) return null
    return { type, blob, fields: [pk] }
  }
  const curve = r.string()
  const q = r.string()
  if (text(curve) !== "nistp256" || !q || q.length !== 65 || q[0] !== 4 || !r.done) return null
  try {
    await crypto.subtle.importKey("raw", q, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"])
  } catch {
    return null
  }
  return { type, blob, fields: [curve!, q] }
}

/** The wire blob of an Ed25519 public key (the CA key). */
export const ed25519Blob = (pk: Uint8Array): Uint8Array => concat([sshString("ssh-ed25519"), sshString(pk)])

export const authorizedKeyLine = (blob: Uint8Array, comment: string): string => `ssh-ed25519 ${toBase64(blob)} ${comment}`

export interface CertFields {
  readonly nonce: Uint8Array
  readonly serial: number
  readonly keyId: string
  readonly principals: ReadonlyArray<string>
  /** Seconds since the epoch. */
  readonly validAfter: number
  readonly validBefore: number
  /** name -> value; sorted by name on output. */
  readonly criticalOptions: Readonly<Record<string, string>>
  /** name -> value (null for a flag); sorted by name on output. */
  readonly extensions: Readonly<Record<string, string | null>>
  readonly caBlob: Uint8Array
}

const CERT_TYPE: Record<UserKeyType, string> = {
  "ssh-ed25519": "ssh-ed25519-cert-v01@openssh.com",
  "ecdsa-sha2-nistp256": "ecdsa-sha2-nistp256-cert-v01@openssh.com"
}
const SSH2_CERT_TYPE_USER = 1

const sorted = <T>(o: Readonly<Record<string, T>>) => Object.keys(o).sort().map((k) => [k, o[k]!] as const)

/** The certificate bytes the CA signs (everything up to and including the signature key). */
export const certToSign = (key: UserKey, f: CertFields): Uint8Array =>
  concat([
    sshString(CERT_TYPE[key.type]),
    sshString(f.nonce),
    ...key.fields.map(sshString),
    u64(f.serial),
    u32(SSH2_CERT_TYPE_USER),
    sshString(f.keyId),
    sshString(concat(f.principals.map(sshString))),
    u64(f.validAfter),
    u64(f.validBefore),
    sshString(concat(sorted(f.criticalOptions).map(([k, v]) => concat([sshString(k), sshString(sshString(v))])))),
    sshString(concat(sorted(f.extensions).map(([k, v]) => concat([sshString(k), sshString(v === null ? new Uint8Array() : sshString(v))])))),
    sshString(new Uint8Array()),
    sshString(f.caBlob)
  ])

/** The signed certificate as an OpenSSH `*-cert.pub` line. */
export const certLine = (key: UserKey, toSign: Uint8Array, ed25519Signature: Uint8Array, comment: string): string => {
  const sig = sshString(concat([sshString("ssh-ed25519"), sshString(ed25519Signature)]))
  return `${CERT_TYPE[key.type]} ${toBase64(concat([toSign, sig]))} ${comment}`
}

const KRL_MAGIC = enc.encode("SSHKRL\n\0")
const KRL_FORMAT_VERSION = 1
const KRL_SECTION_CERTIFICATES = 1
const KRL_SECTION_EXPLICIT_KEY = 2
const KRL_SECTION_CERT_SERIAL_LIST = 0x20

export interface KrlInput {
  readonly version: number
  /** Seconds since the epoch. */
  readonly generatedAt: number
  readonly comment: string
  /** Revoked certificate serials per CA public key blob. */
  readonly serials: ReadonlyArray<{ readonly caBlob: Uint8Array; readonly serials: ReadonlyArray<number> }>
  /** Revoked keys (a revoked CA key revokes every certificate it signed). */
  readonly keys: ReadonlyArray<Uint8Array>
}

/** An unsigned OpenSSH KRL (sshd `RevokedKeys`, `ssh-keygen -Q`). */
export const buildKrl = (k: KrlInput): Uint8Array => {
  const sections: Array<Uint8Array> = []
  for (const ca of k.serials) {
    const list = [...new Set(ca.serials)].filter((s) => s > 0).sort((a, b) => a - b)
    if (list.length === 0) continue
    const certs = concat([sshString(ca.caBlob), sshString(new Uint8Array()), Uint8Array.of(KRL_SECTION_CERT_SERIAL_LIST), sshString(concat(list.map(u64)))])
    sections.push(Uint8Array.of(KRL_SECTION_CERTIFICATES), sshString(certs))
  }
  if (k.keys.length > 0) sections.push(Uint8Array.of(KRL_SECTION_EXPLICIT_KEY), sshString(concat(k.keys.map(sshString))))
  return concat([KRL_MAGIC, u32(KRL_FORMAT_VERSION), u64(k.version), u64(k.generatedAt), u64(0), sshString(new Uint8Array()), sshString(k.comment), ...sections])
}
