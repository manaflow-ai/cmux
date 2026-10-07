/**
 * Checks the team SSH CA's wire formats with OpenSSH itself (plans/cmux-next/team-vm-plan.md S3):
 * a fresh CA signs Ed25519 and P-256 user certificates through the same code TeamDO uses, then
 * `ssh-keygen -L` must parse each one (it verifies the signature) and `ssh-keygen -Q` must report
 * exactly the serial revoked in the KRL. Needs `ssh-keygen` on PATH; writes only to a temp dir.
 *
 *   bun backend/apps/api/scripts/ssh-ca-check.ts
 */
import { execFileSync, spawnSync } from "node:child_process"
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { SSH_AGENT_FORCE_COMMAND, SSH_TEAMS_EXTENSION } from "@cmux/protocol"
import { keyFingerprint } from "../src/team-ssh-presence.ts"
import { authorizedKeyLine, buildKrl, certLine, certToSign, ed25519Blob, parseUserKey } from "../src/team-ssh-wire.ts"

const dir = mkdtempSync(join(tmpdir(), "cmux-ssh-ca-check-"))
const fail = (msg: string): never => {
  console.error(`ssh-ca-check: ${msg}`)
  process.exit(1)
}
try {
  const ca = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair
  const caBlob = ed25519Blob(new Uint8Array(await crypto.subtle.exportKey("raw", ca.publicKey)))
  writeFileSync(join(dir, "ca.pub"), `${authorizedKeyLine(caBlob, "cmux-team-ca-1")}\n`)
  const now = Math.floor(Date.now() / 1000)
  const certs: Array<string> = []
  for (const [serial, type] of [
    [1, "ed25519"],
    [2, "ecdsa"]
  ] as const) {
    const file = join(dir, `user${serial}`)
    execFileSync("ssh-keygen", ["-q", "-t", type, ...(type === "ecdsa" ? ["-b", "256"] : []), "-N", "", "-C", "check", "-f", file])
    const key = (await parseUserKey(readFileSync(`${file}.pub`, "utf8"))) ?? fail(`could not parse the ${type} key ssh-keygen made`)
    // The fingerprint a device shows before it approves a full-shell certificate must be the one ssh-keygen prints.
    const printed = execFileSync("ssh-keygen", ["-l", "-E", "sha256", "-f", `${file}.pub`], { encoding: "utf8" }).split(" ")[1]
    if ((await keyFingerprint(key)) !== printed) fail(`fingerprint ${await keyFingerprint(key)} is not ssh-keygen's ${printed}`)
    const toSign = certToSign(key, {
      nonce: crypto.getRandomValues(new Uint8Array(32)),
      serial,
      keyId: `user_check/session/session/${serial}`,
      principals: ["check-agents"],
      validAfter: now - 60,
      validBefore: now + 1800,
      criticalOptions: { "force-command": SSH_AGENT_FORCE_COMMAND },
      extensions: { "permit-pty": null, [SSH_TEAMS_EXTENSION]: "team_check" },
      caBlob
    })
    const sig = new Uint8Array(await crypto.subtle.sign("Ed25519", ca.privateKey, toSign))
    writeFileSync(`${file}-cert.pub`, `${certLine(key, toSign, sig, "check")}\n`)
    const listed = execFileSync("ssh-keygen", ["-L", "-f", `${file}-cert.pub`], { encoding: "utf8" })
    for (const want of [`Serial: ${serial}`, "check-agents", `force-command ${SSH_AGENT_FORCE_COMMAND}`, "permit-pty", `Key ID: "user_check/session/session/${serial}"`])
      if (!listed.includes(want)) fail(`ssh-keygen -L of certificate ${serial} lacks "${want}":\n${listed}`)
    certs.push(`${file}-cert.pub`)
  }
  writeFileSync(join(dir, "krl"), buildKrl({ version: 7, generatedAt: now, comment: "check", serials: [{ caBlob, serials: [2] }], keys: [] }))
  const q = spawnSync("ssh-keygen", ["-Q", "-f", join(dir, "krl"), ...certs], { encoding: "utf8" })
  const lines = q.stdout.trim().split("\n")
  if (!lines[0]?.endsWith(": ok") || !lines[1]?.endsWith(": REVOKED")) fail(`ssh-keygen -Q gave:\n${q.stdout}${q.stderr}`)
  console.log("ssh-ca-check: ssh-keygen parsed both certificates and the KRL revokes only serial 2")
} finally {
  rmSync(dir, { recursive: true, force: true })
}
