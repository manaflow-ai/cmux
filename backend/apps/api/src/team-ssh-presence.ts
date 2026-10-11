import { user as homeUser } from "@cmux/home-core"
import { toBase64, type UserKey } from "./team-ssh-wire.ts"

/**
 * User presence for full-shell team SSH certificates (team-vm-plan.md 3c, decision SSH-1, S5
 * prerequisite). It reuses the presence keys and nonces of the text confirmation level
 * (home-messaging.md section 21): UserDO owns the keys, the challenges and the App Attest
 * counters; TeamDO only binds the request. The device signs the purpose (team, Linux user,
 * key fingerprint, validity, and `request` = the idempotency key of the one `team_vm.ssh_cert`
 * call it authorizes) after Face ID, Touch ID or the device passcode.
 */

export type SshPurpose = homeUser.SshCertPurpose

export interface PresenceProof {
  readonly install: string
  readonly nonce: string
  readonly signature: string
  readonly app_attest?: string
}

/** UserDO's presence ops for this team (RPC; tests may replace them). */
export interface SshPresence {
  challenge(user: string, install: string, purpose: SshPurpose): Promise<{ ok: true; value: { sign: unknown; message: string; expires_at: number } } | { ok: false; code: string; message: string }>
  /** `asserted` only for a valid, fresh proof of exactly `purpose`; any attempt spends the nonce. */
  assert(user: string, proof: PresenceProof, purpose: SshPurpose): Promise<{ asserted: boolean; code?: string; expires_at?: number }>
}

/** OpenSSH `SHA256:` fingerprint of a public key blob (base64 without padding), as `ssh-keygen -l` prints it. */
export const keyFingerprint = async (key: UserKey): Promise<string> =>
  `SHA256:${toBase64(new Uint8Array(await crypto.subtle.digest("SHA-256", key.blob))).replace(/=+$/, "")}`

export const sshPurpose = async (team: string, request: string, key: UserKey, principal: string, validityMinutes: number): Promise<SshPurpose> => ({
  op: homeUser.SSH_CERT_OP,
  team,
  request,
  key_fingerprint: await keyFingerprint(key),
  principal,
  validity_minutes: validityMinutes,
  class: "human"
})
