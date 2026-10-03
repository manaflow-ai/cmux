import type { OwnerFrame, Principal, RejectFrame, ResultFrame } from "@cmux/ownership"
import { SSH_AGENT_FORCE_COMMAND, SSH_TEAMS_EXTENSION, TeamVmSshCaRotate, TeamVmSshCert, TeamVmSshCertRevoke } from "@cmux/protocol"
import { decodeParams } from "./domains/common.ts"
import { linuxUserFor, MAX_CERT_MS } from "./domains/team-ssh.ts"
import type { TeamState } from "./domains/team.ts"
import { open, seal, type SealedSecret } from "./integrations/crypto.ts"
import type { DomainReply } from "./team-domain-external.ts"
import { authorizedKeyLine, certLine, certToSign, ed25519Blob, parseUserKey, toBase64 } from "./team-ssh-wire.ts"

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
/** A request row still without a reply after this long belongs to a crashed request. */
const ABANDONED_MS = 5 * 60_000
/** Clock skew allowance for valid_after. */
const SKEW_MS = 60_000
/** Replay records and the issued log are kept this long after expiry, then dropped. */
const RETAIN_MS = 24 * 60 * 60_000

export interface SshCaDeps {
  /** The current state (it changes after every submitSystem). */
  readonly state: () => TeamState
  readonly team: string
  readonly stream: string
  readonly kek: string | undefined
  readonly sql: SqlStorage
  readonly now: () => number
  readonly submitSystem: (op: string, params: unknown, key: string) => { frames: ReadonlyArray<OwnerFrame> }
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
  sql.exec(`CREATE TABLE IF NOT EXISTS ssh_requests (identity TEXT NOT NULL, idem TEXT NOT NULL, op TEXT NOT NULL, hash TEXT NOT NULL, reply TEXT, at INTEGER NOT NULL, PRIMARY KEY (identity, idem))`)
}

/** Imported signing keys per team and generation (the sealed row is opened once per isolate). */
const signers = new Map<string, Promise<CryptoKey>>()

const hex = (b: ArrayBuffer) => Array.from(new Uint8Array(b), (x) => x.toString(16).padStart(2, "0")).join("")
const role = (s: TeamState, user: string | undefined) => (user ? s.members[user]?.role : undefined)
const isAdmin = (s: TeamState, user: string | undefined) => role(s, user) === "owner" || role(s, user) === "admin"

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

type CertParams = { public_key: string; validity_minutes?: number; class?: "human" | "agent" }

/**
 * Which class this caller may have. A person's session: either. An install: `agent` with
 * mutate-own; `human` only on a Mac or CLI install whose grant covers execute. An agent
 * principal or a team server: `agent` only or nothing (server.md: servers never get SSH access).
 */
const classFor = (s: TeamState, p: Principal, requested: "human" | "agent" | undefined): "human" | "agent" => {
  if (p.kind === "install" && p.install && (s.server_revocations?.[p.install] || Object.values(s.hosts).some((h) => h.kind === "server" && h.enrolled_by === p.install)))
    throw new Refusal("team_vm.ssh_class_refused", "a team server does not get SSH certificates")
  const classes = p.grant_classes ?? []
  const human = !p.agent && (p.kind === "session" || (p.kind === "install" && classes.includes("execute") && (p.install_kind === "mac" || p.install_kind === "cli")))
  const agent = p.kind === "session" || (p.kind === "install" && classes.includes("mutate-own"))
  const cls = requested ?? (p.kind === "session" && !p.agent ? "human" : "agent")
  if (cls === "human" ? !human : !agent) throw new Refusal("team_vm.ssh_class_refused", `this caller may not have a ${cls} certificate`)
  return cls
}

const issue = async (deps: SshCaDeps, p: Principal, params: CertParams) => {
  const user = p.user!
  const key = await parseUserKey(params.public_key)
  if (!key) throw new Refusal("team_vm.ssh_key_invalid", "public_key must be one ssh-ed25519 or ecdsa-sha2-nistp256 authorized_keys line")
  const cls = classFor(deps.state(), p, params.class)
  const since = deps.now() - RATE_WINDOW_MS
  const byIdentity = deps.sql.exec<{ n: number }>(`SELECT count(*) AS n FROM ssh_certs WHERE identity = ? AND issued_at > ?`, p.identity, since).toArray()[0]!.n
  const byUser = deps.sql.exec<{ n: number }>(`SELECT count(*) AS n FROM ssh_certs WHERE user = ? AND issued_at > ?`, user, since).toArray()[0]!.n
  if (byIdentity >= RATE_LIMIT || byUser >= USER_RATE_LIMIT)
    throw new Refusal("team_vm.ssh_rate_limited", `at most ${RATE_LIMIT} certificates per caller and ${USER_RATE_LIMIT} per person in ${RATE_WINDOW_MS / 60_000} minutes`, true)
  committed(deps.submitSystem("team_vm.ssh_account_allocated", { user }, `ssh-account:${user}`))
  await ensureCa(deps, user, null)
  // A rotation during the signing await makes this certificate one of the old CA; sign again with the new one.
  for (let attempt = 0; attempt < 3; attempt++) {
    const ca = deps.state().ssh_ca!
    const account = deps.state().vm_accounts?.[user]
    if (!account || !deps.state().members[user]) throw new Refusal("auth.forbidden", "not a member of this team")
    const signingKey = await signer(deps, ca.generation)
    const now = deps.now()
    const serial = deps.sql.exec<{ serial: number }>(`UPDATE ssh_serial SET next = next + 1 WHERE id = 1 RETURNING next - 1 AS serial`).toArray()[0]!.serial
    const nonce = crypto.getRandomValues(new Uint8Array(32))
    const keyId = `${p.agent ?? user}/${p.grant ?? "session"}/${p.install ?? "session"}/${hex(nonce.slice(0, 6).buffer)}`
    const validAfter = now - SKEW_MS
    const validBefore = now + Math.min(params.validity_minutes ?? 30, MAX_CERT_MS / 60_000) * 60_000
    // Logged before the signing await, so the rate limit and a concurrent revoke by user or install see it.
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
      validBefore
    )
    const principals = [linuxUserFor(account, cls)]
    const toSign = certToSign(key, {
      nonce,
      serial,
      keyId,
      principals,
      validAfter: Math.floor(validAfter / 1000),
      validBefore: Math.floor(validBefore / 1000),
      criticalOptions: cls === "agent" ? { "force-command": SSH_AGENT_FORCE_COMMAND } : {},
      extensions: { ...(cls === "human" ? { "permit-pty": null, "permit-port-forwarding": null } : {}), [SSH_TEAMS_EXTENSION]: deps.team },
      caBlob: Uint8Array.from(atob(ca.public_key.split(" ")[1]!), (c) => c.charCodeAt(0))
    })
    let signature: Uint8Array
    try {
      signature = new Uint8Array(await crypto.subtle.sign("Ed25519", signingKey, toSign))
    } catch (e) {
      deps.sql.exec(`DELETE FROM ssh_certs WHERE serial = ?`, serial)
      throw e
    }
    if (deps.state().ssh_ca?.generation !== ca.generation) {
      deps.sql.exec(`DELETE FROM ssh_certs WHERE serial = ?`, serial)
      continue
    }
    return {
      certificate: certLine(key, toSign, signature, keyId),
      serial,
      key_id: keyId,
      principals,
      class: cls,
      valid_after: validAfter,
      valid_before: validBefore,
      ca_generation: ca.generation,
      ca_public_key: ca.public_key
    }
  }
  throw new Refusal("revision.conflict", "the SSH CA rotated during signing; try again", true)
}

type RevokeParams = { serial?: number; user?: string; install?: string; reason?: string }

const revoke = (deps: SshCaDeps, p: Principal, params: RevokeParams, key: string) => {
  const admin = isAdmin(deps.state(), p.user)
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

const rotate = async (deps: SshCaDeps, p: Principal, compromised: boolean) => {
  if (p.kind !== "session" || p.agent || !isAdmin(deps.state(), p.user)) throw new Refusal("auth.forbidden", "only team owners and admins rotate the SSH CA, in a person's session")
  await ensureCa(deps, p.user!, { compromised })
  const ca = deps.state().ssh_ca!
  return { generation: ca.generation, ca_public_key: ca.public_key, previous_trusted_until: ca.previous?.trusted_until ?? null }
}

/**
 * team_vm.ssh_cert, team_vm.ssh_cert.revoke and team_vm.ssh_ca.rotate. Each request is recorded
 * by (caller identity, idempotency key) before it runs, so a replay returns the first reply and a
 * concurrent duplicate is refused instead of signing twice.
 */
export const sshExternal = async (deps: SshCaDeps, p: Principal, frame: { op: string; params: unknown; idempotency_key: string }): Promise<DomainReply> => {
  const base = { op: frame.op, transaction: "", idempotency_key: frame.idempotency_key, stream: deps.stream, sequence: 0, replayed: false }
  const fail = (code: string, message: string, retryable = false): DomainReply => ({ ...base, ok: false, error: { code, message, retryable } })
  if (!p.user || !deps.state().members[p.user] || p.team !== deps.team) return fail("auth.forbidden", "not a member of this team")
  const def = frame.op === "team_vm.ssh_cert" ? TeamVmSshCert : frame.op === "team_vm.ssh_cert.revoke" ? TeamVmSshCertRevoke : frame.op === "team_vm.ssh_ca.rotate" ? TeamVmSshCaRotate : null
  if (!def) return fail("validation.invalid", `unknown op ${frame.op}`)
  if (p.kind === "install" && !p.grant_classes?.includes(def.risk) && frame.op !== "team_vm.ssh_cert") return fail("auth.forbidden", `grant does not cover ${def.risk}`)
  const d = decodeParams<Record<string, unknown>>(def, frame.params)
  if (!d.ok) return fail(d.code, d.message)
  ensureSshTables(deps.sql)
  const now = deps.now()
  const hash = hex(await crypto.subtle.digest("SHA-256", enc.encode(JSON.stringify([frame.op, d.value]))))
  deps.sql.exec(`DELETE FROM ssh_requests WHERE at < ?`, now - RETAIN_MS)
  deps.sql.exec(`DELETE FROM ssh_certs WHERE valid_before < ?`, now - RETAIN_MS)
  const prior = deps.sql.exec<{ op: string; hash: string; reply: string | null; at: number }>(`SELECT op, hash, reply, at FROM ssh_requests WHERE identity = ? AND idem = ?`, p.identity, frame.idempotency_key).toArray()[0]
  if (prior) {
    if (prior.op !== frame.op || prior.hash !== hash) return fail("idempotency.conflict", "this idempotency key was used for another request")
    if (prior.reply !== null) return { ...base, ok: true, value: JSON.parse(prior.reply), replayed: true }
    if (prior.at > now - ABANDONED_MS) return fail("revision.conflict", "the same request is still running", true)
    // A crashed request left the row without a reply: run it again.
    deps.sql.exec(`DELETE FROM ssh_requests WHERE identity = ? AND idem = ?`, p.identity, frame.idempotency_key)
  }
  const recent = deps.sql.exec<{ n: number }>(`SELECT count(*) AS n FROM ssh_requests WHERE identity = ? AND at > ?`, p.identity, now - RATE_WINDOW_MS).toArray()[0]!.n
  if (recent >= REQUEST_LIMIT) return fail("team_vm.ssh_rate_limited", `at most ${REQUEST_LIMIT} SSH CA requests per caller in ${RATE_WINDOW_MS / 60_000} minutes`, true)
  deps.sql.exec(`INSERT INTO ssh_requests (identity, idem, op, hash, reply, at) VALUES (?, ?, ?, ?, NULL, ?)`, p.identity, frame.idempotency_key, frame.op, hash, now)
  try {
    const value =
      frame.op === "team_vm.ssh_cert"
        ? await issue(deps, p, d.value as CertParams)
        : frame.op === "team_vm.ssh_cert.revoke"
          ? revoke(deps, p, d.value as RevokeParams, hex(await crypto.subtle.digest("SHA-256", enc.encode(`${p.identity}|${frame.idempotency_key}|${now}`))))
          : await rotate(deps, p, (d.value as { compromised?: boolean }).compromised === true)
    deps.sql.exec(`UPDATE ssh_requests SET reply = ? WHERE identity = ? AND idem = ?`, JSON.stringify(value), p.identity, frame.idempotency_key)
    return { ...base, ok: true, value }
  } catch (e) {
    // A refusal is not recorded: fixing its cause and retrying with the same key runs the request again.
    deps.sql.exec(`DELETE FROM ssh_requests WHERE identity = ? AND idem = ?`, p.identity, frame.idempotency_key)
    if (e instanceof Refusal) return fail(e.code, e.message, e.retryable)
    // Never echo the error: it could name key material. Log only the op and the error class.
    console.error(JSON.stringify({ msg: "ssh ca op failed", op: frame.op, error: e instanceof Error ? e.name : "unknown" }))
    return fail("owner.unreachable", "the SSH CA could not complete the request", true)
  }
}
