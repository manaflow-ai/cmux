import type { SqlStore } from "@cmux/ownership"
import { bindMessage, parseEnrollArgs } from "./team-vm-bind.ts"

/** How the fake guest answers the bind exec (tests set it with TeamVmDO.fakeControl). */
export type FakeGuestMode = "honest" | "absent" | "wrong_instance" | "bad_signature" | "old_nonce" | "commit_fails"

const b64u = (b: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")

/**
 * The test VM behind FakeDriver.exec (ENVIRONMENT=test only): it plays `cmux host team-enroll`
 * with an ES256 install key per VM, kept in the DO's own SQLite, so a test can then act as that
 * VM (sign the auth challenge with the same key) and check what the commit step delivered.
 */
export class FakeGuest {
  constructor(private readonly sql: SqlStore) {
    sql.exec(`CREATE TABLE IF NOT EXISTS fake_guest (vm TEXT PRIMARY KEY, private_jwk TEXT NOT NULL, public_jwk TEXT NOT NULL, last_nonce TEXT, committed TEXT, enrolls INTEGER NOT NULL DEFAULT 0)`)
    sql.exec(`CREATE TABLE IF NOT EXISTS fake_guest_ctl (id INTEGER PRIMARY KEY CHECK (id = 1), mode TEXT NOT NULL DEFAULT 'honest')`)
    sql.exec(`INSERT OR IGNORE INTO fake_guest_ctl (id) VALUES (1)`)
  }

  setMode(mode: FakeGuestMode): void {
    this.sql.exec(`UPDATE fake_guest_ctl SET mode = ? WHERE id = 1`, mode)
  }

  /** What a test needs to act as the VM: its key pair and what the commit step wrote. */
  state(vm: string): { private_jwk: JsonWebKey; public_jwk: JsonWebKey; committed: Record<string, string> | null; enrolls: number } | null {
    const row = this.sql.exec<{ private_jwk: string; public_jwk: string; committed: string | null; enrolls: number }>(`SELECT private_jwk, public_jwk, committed, enrolls FROM fake_guest WHERE vm = ?`, vm)[0]
    return row ? { private_jwk: JSON.parse(row.private_jwk), public_jwk: JSON.parse(row.public_jwk), committed: row.committed ? JSON.parse(row.committed) : null, enrolls: row.enrolls } : null
  }

  private async key(vm: string): Promise<{ priv: CryptoKey; pub: JsonWebKey }> {
    let row = this.sql.exec<{ private_jwk: string; public_jwk: string }>(`SELECT private_jwk, public_jwk FROM fake_guest WHERE vm = ?`, vm)[0]
    if (!row) {
      const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
      const priv = (await crypto.subtle.exportKey("jwk", pair.privateKey)) as JsonWebKey
      const pub = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
      row = { private_jwk: JSON.stringify(priv), public_jwk: JSON.stringify({ kty: "EC", crv: "P-256", x: pub.x, y: pub.y }) }
      this.sql.exec(`INSERT INTO fake_guest (vm, private_jwk, public_jwk) VALUES (?, ?, ?)`, vm, row.private_jwk, row.public_jwk)
    }
    const priv = await crypto.subtle.importKey("jwk", JSON.parse(row.private_jwk), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"])
    return { priv, pub: JSON.parse(row.public_jwk) }
  }

  async run(vm: string, command: string): Promise<{ code: number; stdout: string }> {
    const mode = this.sql.exec<{ mode: FakeGuestMode }>(`SELECT mode FROM fake_guest_ctl WHERE id = 1`)[0]!.mode
    if (mode === "absent") return { code: 127, stdout: "" }
    const args = parseEnrollArgs(command)
    if (!args) return { code: 2, stdout: "" }
    if (args.commit) {
      if (mode === "commit_fails") return { code: 1, stdout: "" }
      this.sql.exec(`UPDATE fake_guest SET committed = ? WHERE vm = ?`, JSON.stringify(args.commit), vm)
      return { code: 0, stdout: "{\"committed\":true}\n" }
    }
    const { priv, pub } = await this.key(vm)
    const last = this.sql.exec<{ last_nonce: string | null }>(`SELECT last_nonce FROM fake_guest WHERE vm = ?`, vm)[0]?.last_nonce ?? null
    this.sql.exec(`UPDATE fake_guest SET last_nonce = ?, enrolls = enrolls + 1 WHERE vm = ?`, args.nonce, vm)
    const instance = mode === "wrong_instance" ? `${vm}-other` : vm
    const nonce = mode === "old_nonce" && last ? last : args.nonce
    const message = bindMessage(args.team, args.epoch, instance, nonce)
    const signed = mode === "bad_signature" ? `${message}x` : message
    const signature = b64u(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, priv, new TextEncoder().encode(signed)))
    return { code: 0, stdout: `${JSON.stringify({ instance_id: instance, public_jwk: pub, signature })}\n` }
  }
}
