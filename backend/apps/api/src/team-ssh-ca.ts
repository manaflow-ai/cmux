import type { OwnerFrame, Principal, RejectFrame, ResultFrame } from "@cmux/ownership"
import { SSH_AGENT_FORCE_COMMAND, SSH_TEAMS_EXTENSION, TeamVmSshCaRotate, TeamVmSshCert, TeamVmSshCertChallenge, TeamVmSshCertRevoke } from "@cmux/protocol"
import { decodeParams } from "./domains/common.ts"
import { KRL_GRACE_MS, linuxUserFor, MAX_CERT_MS } from "./domains/team-ssh.ts"
import type { TeamState } from "./domains/team.ts"
import { open, seal, type SealedSecret } from "./integrations/crypto.ts"
import type { DomainReply } from "./team-domain-external.ts"
import { keyFingerprint, sshPurpose, type PresenceProof, type SshPresence } from "./team-ssh-presence.ts"
import { authorizedKeyLine, certLine, certToSign, ed25519Blob, parseUserKey, toBase64, type UserKey } from "./team-ssh-wire.ts"
import type { RowReader } from "@cmux/ownership"
import { hostByInstall, memberOf, roleOf } from "./domains/team-members.ts"

/**
 * The team SSH CA in TeamDO (plans/cmux-next/team-vm-plan.md S3). The Ed25519 CA key is made in
 * workerd, sealed under INTEGRATIONS_KEK with AAD bound to team and generation, and stored only in
 * the `ssh_ca_keys` side table; it never enters an op, an event, a reply or a log. Public results
 * commit as internal ops (team-ssh.ts), so the CA public key, revocations and accounts have one
 * writer and an audit record.
 */

const enc = new TextEncoder()
const aad = (team: string, generation: number) => enc.encode(`cmux-sshca-v1|${team}|${generation}`)
/** Issued certificates per caller identity, and per user across all their installs, in RATE_WINDOW_MS. */
const RATE_LIMIT = 30
const USER_RATE_LIMIT = 60
/** SSH CA requests of any kind per caller identity in RATE_WINDOW_MS (bounds the replay table). */
const REQUEST_LIMIT = 60
const RATE_WINDOW_MS = 10 * 60_000
/** A presence assertion is used at most this long after its challenge expired (a replayed assertion never revives an old approval). */
const PRESENCE_GRACE_MS = 2 * 60_000
const DEFAULT_MINUTES = 30
/** Clock skew allowance for valid_after. */
const SKEW_MS = 60_000
/** Replay records and the issued log are kept this long after expiry, then dropped. */
const RETAIN_MS = 24 * 60 * 60_000

export interface SshCaDeps {
  /** The current state (it changes after every submitSystem). */
  readonly state: () => TeamState
  /** TeamDO rows (members and hosts, team-members.ts). */
  readonly rows?: RowReader
  readonly team: string
  readonly stream: string
  readonly kek: string | undefined
  readonly sql: SqlStorage
  readonly now: () => number
  readonly submitSystem: (op: string, params: unknown, key: string) => { frames: ReadonlyArray<OwnerFrame> }
  /** UserDO's presence proofs (full-shell certificates); absent means none can be issued. */
  readonly presence?: SshPresence
  /**
   * Requests running in this object instance now (owned by the TeamDO instance, so a reset object starts empty):
   * a stored request without a reply that is not here crashed. Required: without it there is no duplicate guard.
   */
  readonly running: Set<string>
}

export const ensureSshTables = (sql: SqlStorage) => {
  sql.exec(`CREATE TABLE IF NOT EXISTS ssh_ca_keys (generation INTEGER PRIMARY KEY, sealed TEXT NOT NULL, public_key TEXT NOT NULL)`)
  sql.exec(`CREATE TABLE IF NOT EXISTS ssh_serial (id INTEGER PRIMARY KEY CHECK (id = 1), next INTEGER NOT NULL)`)
  sql.exec(`INSERT OR IGNORE INTO ssh_serial (id, next) VALUES (1, 1)`)
  sql.exec(
    `CREATE TABLE IF NOT EXISTS ssh_certs (serial INTEGER PRIMARY KEY, identity TEXT NOT NULL, user TEXT NOT NULL, install TEXT, key_id TEXT NOT NULL, class TEXT NOT NULL, generation INTEGER NOT NULL, issued_at INTEGER NOT NULL, valid_before INTEGER NOT NULL)`
  )
  sql.exec(`CREATE INDEX IF NOT EXISTS ssh_certs_identity ON ssh_certs (identity, issued_at)`)
  sql.exec(`CREATE INDEX IF NOT EXISTS ssh_certs_user ON ssh_certs (user, issued_at)`)
  // Installs that UserDO revoked (S4): no new certificate, kept a day (tokens live 10 minutes).
  sql.exec(`CREATE TABLE IF NOT EXISTS ssh_revoked_installs (install TEXT PRIMARY KEY, user TEXT NOT NULL, at INTEGER NOT NULL)`)
  sql.exec(`CREATE TABLE IF NOT EXISTS ssh_requests (identity TEXT NOT NULL, idem TEXT NOT NULL, op TEXT NOT NULL, hash TEXT NOT NULL, reply TEXT, at INTEGER NOT NULL, PRIMARY KEY (identity, idem))`)
  // Everything but the signature of a certificate a request is signing, written with its ssh_certs row before the
  // signing await: a request that crashes signs the same bytes again (Ed25519 is deterministic), never a second certificate.
  sql.exec(
    `CREATE TABLE IF NOT EXISTS ssh_prepared (identity TEXT NOT NULL, idem TEXT NOT NULL, serial INTEGER NOT NULL, generation INTEGER NOT NULL, body TEXT NOT NULL, at INTEGER NOT NULL, PRIMARY KEY (identity, idem))`
  )
}


/** Imported signing keys per team and generation (the sealed row is opened once per isolate). */
const signers = new Map<string, Promise<CryptoKey>>()

const hex = (b: ArrayBuffer) => Array.from(new Uint8Array(b), (x) => x.toString(16).padStart(2, "0")).join("")
const role = (s: TeamState, user: string | undefined, rows?: RowReader) => roleOf(s, rows, user)
const isAdmin = (s: TeamState, user: string | undefined, rows?: RowReader) => role(s, user, rows) === "owner" || role(s, user, rows) === "admin"

class Refusal {
  constructor(
    readonly code: string,
    readonly message: string,
    readonly retryable = false
  ) {}
}

const committed = (res: { frames: ReadonlyArray<OwnerFrame> }): unknown => {
  const rej = res.frames.find((f): f is RejectFrame => f.t === "reject")
  if (rej) throw new Refusal(rej.code, rej.message, rej.retryable)
  return res.frames.find((f): f is ResultFrame => f.t === "result")?.value
}

/**
 * Makes the CA of generation `current + 1` when `rotate` or when no CA exists, and commits it. A
 * sealed row left by a crash before the commit is reused, so a retry never makes a second key.
 */
const ensureCa = async (deps: SshCaDeps, by: string, rotate: { compromised: boolean } | null) => {
  const cur = deps.state().ssh_ca?.generation ?? 0
  if (!rotate && cur > 0) return
  if (!deps.kek) throw new Refusal("team_vm.ssh_ca_not_configured", "the SSH CA needs INTEGRATIONS_KEK on this deployment")
  const generation = cur + 1
  const stored = () => deps.sql.exec<{ public_key: string }>(`SELECT public_key FROM ssh_ca_keys WHERE generation = ?`, generation).toArray()[0]
  // A row left by a crashed attempt may predate the compromise: a compromised rotation always makes a fresh key.
  if (rotate?.compromised) deps.sql.exec(`DELETE FROM ssh_ca_keys WHERE generation > ?`, cur)
  let made: string | null = null
  if (!stored()) {
    const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair
    const pkcs8 = new Uint8Array((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer)
    const publicKey = authorizedKeyLine(ed25519Blob(new Uint8Array((await crypto.subtle.exportKey("raw", pair.publicKey)) as ArrayBuffer)), `cmux-team-ca-${generation}`)
    const sealed = await seal(deps.kek, toBase64(pkcs8), aad(deps.team, generation))
    pkcs8.fill(0)
    // A concurrent caller may have stored this generation during the awaits; its key wins.
    deps.sql.exec(`INSERT OR IGNORE INTO ssh_ca_keys (generation, sealed, public_key) VALUES (?, ?, ?)`, generation, JSON.stringify(sealed), publicKey)
    made = publicKey
  }
  if (rotate?.compromised && stored()?.public_key !== made) throw new Refusal("revision.conflict", "another CA change ran at the same time; try again", true)
  // Another request committed this generation during the awaits (two first certificates at once).
  // A rotation that lost the race is refused (retryable), so a `compromised` request is never folded into a plain one.
  if ((deps.state().ssh_ca?.generation ?? 0) >= generation) {
    if (rotate) throw new Refusal("revision.conflict", "another CA rotation finished first; try again", true)
    return
  }
  committed(deps.submitSystem("team_vm.ssh_ca_installed", { generation, public_key: stored()!.public_key, compromised: rotate?.compromised ?? false, by }, `ssh-ca:${generation}`))
  // Only the current key signs; older sealed keys are deleted once the new one is committed.
  deps.sql.exec(`DELETE FROM ssh_ca_keys WHERE generation < ?`, generation)
  for (let g = 1; g < generation; g++) signers.delete(`${deps.team}:${g}`)
}

const signer = (deps: SshCaDeps, generation: number): Promise<CryptoKey> => {
  const cacheKey = `${deps.team}:${generation}`
  let k = signers.get(cacheKey)
  if (!k) {
    const row = deps.sql.exec<{ sealed: string }>(`SELECT sealed FROM ssh_ca_keys WHERE generation = ?`, generation).toArray()[0]
    if (!row || !deps.kek) return Promise.reject(new Refusal("team_vm.ssh_ca_not_configured", "the SSH CA key is not available", true))
    const kek = deps.kek
    k = (async () => {
      const pkcs8 = Uint8Array.from(atob(await open(kek, JSON.parse(row.sealed) as SealedSecret, aad(deps.team, generation))), (c) => c.charCodeAt(0))
      try {
        return await crypto.subtle.importKey("pkcs8", pkcs8, { name: "Ed25519" }, false, ["sign"])
      } finally {
        pkcs8.fill(0)
      }
    })()
    k.catch(() => signers.delete(cacheKey))
    signers.set(cacheKey, k)
  }
  return k
}

type CertParams = { public_key: string; validity_minutes?: number; class?: "human" | "agent"; presence?: PresenceProof }
type ChallengeParams = { public_key: string; validity_minutes?: number; presence_install: string; request: string }

/**
 * Which class this caller may have. A person's signed-in session: either, but `human` only with a
 * fresh presence proof (decision SSH-1). An install token: only `agent` (force-command), with
 * mutate-own, because a token does not show whether a person or an agent holds it (D28). An agent
 * principal: `agent` only. A team server: nothing (server.md: servers never get SSH access).
 */
const classFor = (s: TeamState, p: Principal, params: CertParams, rows?: RowReader): "human" | "agent" => {
  if (p.kind === "install" && p.install && (s.server_revocations?.[p.install] || hostByInstall(s, rows, p.install)?.kind === "server"))
    throw new Refusal("team_vm.ssh_class_refused", "a team server does not get SSH certificates")
  const classes = p.grant_classes ?? []
  const human = !p.agent && p.kind === "session"
  const agent = p.kind === "session" || (p.kind === "install" && classes.includes("mutate-own"))
  // A person's session asks for a full shell unless it names `agent`: without a proof that is an explicit
  // error (the client then asks for presence), never a silent restricted certificate.
  const cls = params.class ?? (p.kind === "session" && !p.agent ? "human" : "agent")
  if (cls === "human" ? !human : !agent) throw new Refusal("team_vm.ssh_class_refused", `this caller may not have a ${cls} certificate`)
  if (cls === "human" && !params.presence)
    throw new Refusal("team_vm.ssh_presence_required", "a full-shell certificate needs a fresh presence proof: call team_vm.ssh_cert.challenge, approve it on your device, then send presence")
  if (cls === "agent" && params.presence) throw new Refusal("validation.invalid", "presence is only for class human")
  return cls
}

/** The prepared certificate of one request: everything the CA signs except the CA's own fields. */
interface Prepared {
  readonly serial: number
  readonly generation: number
  readonly nonce: string
  readonly key_id: string
  readonly principals: ReadonlyArray<string>
  readonly class: "human" | "agent"
  readonly valid_after: number
  readonly valid_before: number
  /** The request (op and params hash) and the public key it was prepared for; a resume needs both to match. */
  readonly request_hash: string
  readonly key_fingerprint: string
}

const forget = (sql: SqlStorage, identity: string, idem: string, serial?: number) => {
  sql.exec(`DELETE FROM ssh_prepared WHERE identity = ? AND idem = ?`, identity, idem)
  if (serial !== undefined) sql.exec(`DELETE FROM ssh_certs WHERE serial = ?`, serial)
}

/** Signs a prepared certificate with its generation's key; null when the CA rotated meanwhile (the caller prepares again). */
const signPrepared = async (deps: SshCaDeps, team: string, key: UserKey, prep: Prepared) => {
  const ca = deps.state().ssh_ca
  if (!ca || ca.generation !== prep.generation) return null
  const signingKey = await signer(deps, ca.generation)
  const toSign = certToSign(key, {
    nonce: Uint8Array.from(atob(prep.nonce), (c) => c.charCodeAt(0)),
    serial: prep.serial,
    keyId: prep.key_id,
    principals: prep.principals,
    validAfter: Math.floor(prep.valid_after / 1000),
    validBefore: Math.floor(prep.valid_before / 1000),
    criticalOptions: prep.class === "agent" ? { "force-command": SSH_AGENT_FORCE_COMMAND } : {},
    extensions: { ...(prep.class === "human" ? { "permit-pty": null, "permit-port-forwarding": null } : {}), [SSH_TEAMS_EXTENSION]: team },
    caBlob: Uint8Array.from(atob(ca.public_key.split(" ")[1]!), (c) => c.charCodeAt(0))
  })
  const signature = new Uint8Array(await crypto.subtle.sign("Ed25519", signingKey, toSign))
  if (deps.state().ssh_ca?.generation !== ca.generation) return null
  return {
    certificate: certLine(key, toSign, signature, prep.key_id),
    serial: prep.serial,
    key_id: prep.key_id,
    principals: prep.principals,
    class: prep.class,
    valid_after: prep.valid_after,
    valid_before: prep.valid_before,
    ca_generation: ca.generation,
    ca_public_key: ca.public_key
  }
}

/**
 * A request that crashed after it prepared its certificate: the same bytes signed again, so the
 * same serial and certificate. Null when that certificate can no longer be given (the CA rotated,
 * it expired): it never left this object, so the request prepares again.
 */
const resume = async (deps: SshCaDeps, p: Principal, params: CertParams, idem: string, key: UserKey, prep: Prepared, bound: { hash: string; fingerprint: string }) => {
  // Prepared for another request or key (its request record expired, for example): never sign it with this key.
  if (prep.request_hash !== bound.hash || prep.key_fingerprint !== bound.fingerprint) {
    forget(deps.sql, p.identity, idem, prep.serial)
    return null
  }
  try {
    // The same caller checks as a new request (a team server, a removed member or a revoked install gets nothing).
    classFor(deps.state(), p, params, deps.rows)
    if (!memberOf(deps.state(), deps.rows, p.user)) throw new Refusal("auth.forbidden", "not a member of this team")
    if (p.install && deps.sql.exec(`SELECT 1 FROM ssh_revoked_installs WHERE install = ?`, p.install).toArray().length > 0) throw new Refusal("auth.forbidden", "this install was revoked")
  } catch (e) {
    forget(deps.sql, p.identity, idem, prep.serial)
    throw e
  }
  const live = prep.valid_before > deps.now() && !deps.state().ssh_revoked?.[String(prep.serial)]
  const value = live ? await signPrepared(deps, deps.team, key, prep) : null
  if (!value) forget(deps.sql, p.identity, idem, prep.serial)
  return value
}

/** The person approved exactly this request on their device (UserDO checks the key, nonce and signature). */
const assertPresence = async (deps: SshCaDeps, p: Principal, idem: string, key: UserKey, principal: string, minutes: number, proof: PresenceProof) => {
  if (!deps.presence) throw new Refusal("team_vm.ssh_presence_refused", "user presence is not available on this deployment")
  const r = await deps.presence.assert(p.user!, proof, await sshPurpose(deps.team, idem, key, principal, minutes))
  if (!r.asserted) throw new Refusal("team_vm.ssh_presence_refused", `the presence proof was refused (${r.code ?? "unknown"})`)
  // A replayed assertion (UserDO's ledger) answers the same; it never makes an old approval new.
  if (typeof r.expires_at !== "number" || deps.now() > r.expires_at + PRESENCE_GRACE_MS) throw new Refusal("team_vm.ssh_presence_refused", "the presence proof expired; ask again")
}

/** team_vm.ssh_cert.challenge: a single-use presence challenge on the person's device for one full-shell request. */
const challenge = async (deps: SshCaDeps, p: Principal, params: ChallengeParams) => {
  if (p.kind !== "session" || p.agent) throw new Refusal("team_vm.ssh_class_refused", "a full-shell certificate needs a person's signed-in session")
  const key = await parseUserKey(params.public_key)
  if (!key) throw new Refusal("team_vm.ssh_key_invalid", "public_key must be one ssh-ed25519 or ecdsa-sha2-nistp256 authorized_keys line")
  if (!deps.presence) throw new Refusal("team_vm.ssh_presence_refused", "user presence is not available on this deployment")
  committed(deps.submitSystem("team_vm.ssh_account_allocated", { user: p.user }, `ssh-account:${p.user}`))
  const account = deps.state().vm_accounts?.[p.user!]
  if (!account) throw new Refusal("auth.forbidden", "not a member of this team")
  const minutes = Math.min(params.validity_minutes ?? DEFAULT_MINUTES, MAX_CERT_MS / 60_000)
  const r = await deps.presence.challenge(p.user!, params.presence_install, await sshPurpose(deps.team, params.request, key, linuxUserFor(account, "human"), minutes))
  if (!r.ok) throw new Refusal("team_vm.ssh_presence_refused", `no presence challenge for that device (${r.code})`)
  return r.value
}

const issue = async (deps: SshCaDeps, p: Principal, params: CertParams, idem: string, hash: string) => {
  const user = p.user!
  const key = await parseUserKey(params.public_key)
  if (!key) throw new Refusal("team_vm.ssh_key_invalid", "public_key must be one ssh-ed25519 or ecdsa-sha2-nistp256 authorized_keys line")
  const bound = { hash, fingerprint: await keyFingerprint(key) }
  const row = deps.sql.exec<{ body: string }>(`SELECT body FROM ssh_prepared WHERE identity = ? AND idem = ?`, p.identity, idem).toArray()[0]
  if (row) {
    const again = await resume(deps, p, params, idem, key, JSON.parse(row.body) as Prepared, bound)
    if (again) return again
  }
  const cls = classFor(deps.state(), p, params)
  const since = deps.now() - RATE_WINDOW_MS
  const byIdentity = deps.sql.exec<{ n: number }>(`SELECT count(*) AS n FROM ssh_certs WHERE identity = ? AND issued_at > ?`, p.identity, since).toArray()[0]!.n
  const byUser = deps.sql.exec<{ n: number }>(`SELECT count(*) AS n FROM ssh_certs WHERE user = ? AND issued_at > ?`, user, since).toArray()[0]!.n
  if (byIdentity >= RATE_LIMIT || byUser >= USER_RATE_LIMIT)
    throw new Refusal("team_vm.ssh_rate_limited", `at most ${RATE_LIMIT} certificates per caller and ${USER_RATE_LIMIT} per person in ${RATE_WINDOW_MS / 60_000} minutes`, true)
  committed(deps.submitSystem("team_vm.ssh_account_allocated", { user }, `ssh-account:${user}`))
  const minutes = Math.min(params.validity_minutes ?? DEFAULT_MINUTES, MAX_CERT_MS / 60_000)
  const named = deps.state().vm_accounts?.[user]
  if (!named) throw new Refusal("auth.forbidden", "not a member of this team")
  if (cls === "human") await assertPresence(deps, p, idem, key, linuxUserFor(named, "human"), minutes, params.presence!)
  await ensureCa(deps, user, null)
  // A rotation during the signing await makes this certificate one of the old CA; sign again with the new one.
  for (let attempt = 0; attempt < 3; attempt++) {
    const ca = deps.state().ssh_ca!
    const account = deps.state().vm_accounts?.[user]
    if (!account || !memberOf(deps.state(), deps.rows, user)) throw new Refusal("auth.forbidden", "not a member of this team")
    // Opened before the row is written, so the prepared row and the ssh_certs row commit together.
    await signer(deps, ca.generation)
    if (deps.state().ssh_ca?.generation !== ca.generation) continue
    // Checked again after the await, in the same synchronous segment as the rows: a member removed meanwhile gets nothing.
    const current = deps.state().vm_accounts?.[user]
    if (!current || !memberOf(deps.state(), deps.rows, user)) throw new Refusal("auth.forbidden", "not a member of this team")
    // The person approved this Linux user; a certificate never names another one.
    if (linuxUserFor(current, "human") !== linuxUserFor(named, "human")) throw new Refusal("revision.conflict", "the Linux account changed during the request; try again", true)
    const now = deps.now()
    const serial = deps.sql.exec<{ serial: number }>(`UPDATE ssh_serial SET next = next + 1 WHERE id = 1 RETURNING next - 1 AS serial`).toArray()[0]!.serial
    const nonce = crypto.getRandomValues(new Uint8Array(32))
    const keyId = `${p.agent ?? user}/${p.grant ?? "session"}/${p.install ?? "session"}/${hex(nonce.slice(0, 6).buffer)}`
    // An install revoked during this request's awaits gets nothing (the notice came before this row).
    if (p.install && deps.sql.exec(`SELECT 1 FROM ssh_revoked_installs WHERE install = ?`, p.install).toArray().length > 0) throw new Refusal("auth.forbidden", "this install was revoked")
    const prep: Prepared = {
      serial,
      generation: ca.generation,
      nonce: toBase64(nonce),
      key_id: keyId,
      principals: [linuxUserFor(current, cls)],
      class: cls,
      valid_after: now - SKEW_MS,
      valid_before: now + minutes * 60_000,
      request_hash: bound.hash,
      key_fingerprint: bound.fingerprint
    }
    // Logged before the signing await, so the rate limit and a concurrent revoke by user or install see it, and with
    // the prepared certificate in the same write, so a crash during signing resumes this certificate (resume).
    deps.sql.exec(
      `INSERT INTO ssh_certs (serial, identity, user, install, key_id, class, generation, issued_at, valid_before) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      serial,
      p.identity,
      user,
      p.install ?? null,
      keyId,
      cls,
      ca.generation,
      now,
      prep.valid_before
    )
    deps.sql.exec(`INSERT OR REPLACE INTO ssh_prepared (identity, idem, serial, generation, body, at) VALUES (?, ?, ?, ?, ?, ?)`, p.identity, idem, serial, ca.generation, JSON.stringify(prep), now)
    let value: Awaited<ReturnType<typeof signPrepared>>
    try {
      value = await signPrepared(deps, deps.team, key, prep)
    } catch (e) {
      forget(deps.sql, p.identity, idem, serial)
      throw e
    }
    if (value) return value
    // The CA rotated during signing: this certificate would be one of the old CA; sign again with the new one.
    forget(deps.sql, p.identity, idem, serial)
  }
  throw new Refusal("revision.conflict", "the SSH CA rotated during signing; try again", true)
}

type RevokeParams = { serial?: number; user?: string; install?: string; reason?: string }

const revoke = (deps: SshCaDeps, p: Principal, params: RevokeParams, key: string) => {
  const admin = isAdmin(deps.state(), p.user, deps.rows)
  const selectors = [params.serial, params.user, params.install].filter((v) => v !== undefined)
  if (selectors.length !== 1) throw new Refusal("validation.invalid", "give exactly one of serial, user or install")
  const now = deps.now()
  const column = params.serial !== undefined ? "serial" : params.user !== undefined ? "user" : "install"
  const rows = deps.sql
    .exec<{ serial: number; user: string; valid_before: number; generation: number }>(`SELECT serial, user, valid_before, generation FROM ssh_certs WHERE ${column} = ? AND valid_before > ?`, selectors[0]!, now)
    .toArray()
  // Members revoke only their own certificates; owners and admins anyone's.
  if (!admin && (rows.some((r) => r.user !== p.user) || (params.user !== undefined && params.user !== p.user)))
    throw new Refusal("auth.forbidden", "members may revoke only their own certificates")
  const serials = rows.map((r) => ({ serial: r.serial, valid_before: r.valid_before, generation: r.generation }))
  const by = p.agent ?? p.user ?? p.identity
  if (serials.length === 0) return { revoked: [], krl_version: deps.state().ssh_krl?.version ?? 0 }
  // The request's own replay row (ssh_requests) is the idempotency record; the ledger key is per attempt, so a
  // refused attempt (a full list) is not replayed after the cause is gone.
  return committed(deps.submitSystem("team_vm.ssh_certs_revoked", { serials, by, admin, reason: params.reason ?? "" }, `ssh-revoke:${key}`)) as { revoked: Array<number>; krl_version: number }
}

/** UserDO revoked `install` of `user` (S4): record it, then revoke its unexpired certificates. Idempotent. */
export const revokeInstallCerts = async (deps: SshCaDeps, user: string, install: string): Promise<{ ok: boolean; revoked: Array<number> }> => {
  ensureSshTables(deps.sql)
  const now = deps.now()
  deps.sql.exec(`DELETE FROM ssh_revoked_installs WHERE at < ?`, now - RETAIN_MS)
  deps.sql.exec(`INSERT OR IGNORE INTO ssh_revoked_installs (install, user, at) VALUES (?, ?, ?)`, install, user, now)
  const serials = deps.sql
    .exec<{ serial: number; valid_before: number; generation: number }>(`SELECT serial, valid_before, generation FROM ssh_certs WHERE install = ? AND user = ? AND valid_before > ?`, install, user, now - KRL_GRACE_MS)
    .toArray()
    .map((r) => ({ serial: r.serial, valid_before: r.valid_before, generation: r.generation }))
  if (serials.length === 0 || !deps.state().team) return { ok: true, revoked: [] }
  const key = hex(await crypto.subtle.digest("SHA-256", enc.encode(`${user}|${install}|${serials.map((s) => s.serial).join(",")}`)))
  try {
    const v = committed(deps.submitSystem("team_vm.ssh_certs_revoked", { serials, by: `system:user:${user}`, admin: true, system: true, reason: "install revoked" }, `ssh-install-revoked:${key}`)) as { revoked: Array<number> }
    return { ok: true, revoked: v.revoked }
  } catch (e) {
    console.error(JSON.stringify({ msg: "install certificate revocation refused", install, code: e instanceof Refusal ? e.code : "error" }))
    return { ok: false, revoked: [] }
  }
}

const rotate = async (deps: SshCaDeps, p: Principal, compromised: boolean) => {
  if (p.kind !== "session" || p.agent || !isAdmin(deps.state(), p.user, deps.rows)) throw new Refusal("auth.forbidden", "only team owners and admins rotate the SSH CA, in a person's session")
  await ensureCa(deps, p.user!, { compromised })
  const ca = deps.state().ssh_ca!
  return { generation: ca.generation, ca_public_key: ca.public_key, previous_trusted_until: ca.previous?.trusted_until ?? null }
}

/**
 * team_vm.ssh_cert.challenge, team_vm.ssh_cert, team_vm.ssh_cert.revoke and team_vm.ssh_ca.rotate.
 * Each request is recorded by (caller identity, idempotency key) before it runs, so a replay
 * returns the first reply, a concurrent duplicate is refused instead of signing twice, and a
 * request that the object lost in a crash runs again under the same record (a certificate it had
 * prepared is signed again, the same one).
 */
export const sshExternal = async (deps: SshCaDeps, p: Principal, frame: { op: string; params: unknown; idempotency_key: string }): Promise<DomainReply> => {
  const base = { op: frame.op, transaction: "", idempotency_key: frame.idempotency_key, stream: deps.stream, sequence: 0, replayed: false }
  const fail = (code: string, message: string, retryable = false): DomainReply => ({ ...base, ok: false, error: { code, message, retryable } })
  if (!p.user || !memberOf(deps.state(), deps.rows, p.user) || p.team !== deps.team) return fail("auth.forbidden", "not a member of this team")
  const defs = { "team_vm.ssh_cert": TeamVmSshCert, "team_vm.ssh_cert.challenge": TeamVmSshCertChallenge, "team_vm.ssh_cert.revoke": TeamVmSshCertRevoke, "team_vm.ssh_ca.rotate": TeamVmSshCaRotate } as const
  const def = Object.hasOwn(defs, frame.op) ? defs[frame.op as keyof typeof defs] : null
  if (!def) return fail("validation.invalid", `unknown op ${frame.op}`)
  if (p.kind === "install" && !p.grant_classes?.includes(def.risk) && frame.op !== "team_vm.ssh_cert") return fail("auth.forbidden", `grant does not cover ${def.risk}`)
  const d = decodeParams<Record<string, unknown>>(def, frame.params)
  if (!d.ok) return fail(d.code, d.message)
  ensureSshTables(deps.sql)
  const now = deps.now()
  const hash = hex(await crypto.subtle.digest("SHA-256", enc.encode(JSON.stringify([frame.op, d.value]))))
  deps.sql.exec(`DELETE FROM ssh_requests WHERE at < ?`, now - RETAIN_MS)
  deps.sql.exec(`DELETE FROM ssh_prepared WHERE at < ?`, now - RETAIN_MS)
  deps.sql.exec(`DELETE FROM ssh_certs WHERE valid_before < ?`, now - RETAIN_MS)
  const prior = deps.sql.exec<{ op: string; hash: string; reply: string | null; at: number }>(`SELECT op, hash, reply, at FROM ssh_requests WHERE identity = ? AND idem = ?`, p.identity, frame.idempotency_key).toArray()[0]
  const run = `${p.identity}|${frame.idempotency_key}`
  const running = deps.running
  if (prior) {
    if (prior.op !== frame.op || prior.hash !== hash) return fail("idempotency.conflict", "this idempotency key was used for another request")
    if (prior.reply !== null) return { ...base, ok: true, value: JSON.parse(prior.reply), replayed: true }
    if (running.has(run)) return fail("revision.conflict", "the same request is still running", true)
    // Not running here: the object restarted during the request (a crash). Run it again under the same row.
  } else {
    const recent = deps.sql.exec<{ n: number }>(`SELECT count(*) AS n FROM ssh_requests WHERE identity = ? AND at > ?`, p.identity, now - RATE_WINDOW_MS).toArray()[0]!.n
    if (recent >= REQUEST_LIMIT) return fail("team_vm.ssh_rate_limited", `at most ${REQUEST_LIMIT} SSH CA requests per caller in ${RATE_WINDOW_MS / 60_000} minutes`, true)
    deps.sql.exec(`INSERT INTO ssh_requests (identity, idem, op, hash, reply, at) VALUES (?, ?, ?, ?, NULL, ?)`, p.identity, frame.idempotency_key, frame.op, hash, now)
  }
  running.add(run)
  try {
    const value =
      frame.op === "team_vm.ssh_cert"
        ? await issue(deps, p, d.value as CertParams, frame.idempotency_key, hash)
        : frame.op === "team_vm.ssh_cert.challenge"
          ? await challenge(deps, p, d.value as ChallengeParams)
          : frame.op === "team_vm.ssh_cert.revoke"
            ? revoke(deps, p, d.value as RevokeParams, hex(await crypto.subtle.digest("SHA-256", enc.encode(`${p.identity}|${frame.idempotency_key}|${now}`))))
            : await rotate(deps, p, (d.value as { compromised?: boolean }).compromised === true)
    // The reply and the end of the prepared certificate commit together: from now on a retry gets this reply.
    deps.sql.exec(`UPDATE ssh_requests SET reply = ? WHERE identity = ? AND idem = ?`, JSON.stringify(value), p.identity, frame.idempotency_key)
    deps.sql.exec(`DELETE FROM ssh_prepared WHERE identity = ? AND idem = ?`, p.identity, frame.idempotency_key)
    return { ...base, ok: true, value }
  } catch (e) {
    // A refusal is not recorded: fixing its cause and retrying with the same key runs the request again.
    deps.sql.exec(`DELETE FROM ssh_requests WHERE identity = ? AND idem = ?`, p.identity, frame.idempotency_key)
    deps.sql.exec(`DELETE FROM ssh_prepared WHERE identity = ? AND idem = ?`, p.identity, frame.idempotency_key)
    if (e instanceof Refusal) return fail(e.code, e.message, e.retryable)
    // Never echo the error: it could name key material. Log only the op and the error class.
    console.error(JSON.stringify({ msg: "ssh ca op failed", op: frame.op, error: e instanceof Error ? e.name : "unknown" }))
    return fail("owner.unreachable", "the SSH CA could not complete the request", true)
  } finally {
    running.delete(run)
  }
}
