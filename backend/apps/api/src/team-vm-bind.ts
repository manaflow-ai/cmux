import type { SqlStore } from "@cmux/ownership"
import { verifyInstallSignature } from "./auth.ts"

/**
 * The team VM bind (plans/cmux-next/vm-image.md 6b): TeamVmDO proves which provider VM answers
 * and gives that VM's own key an install for the team, with no secret in the image.
 *
 * 1. TeamVmDO mints a single-use nonce for (epoch, vm), valid NONCE_TTL_MS.
 * 2. It runs `cmux host team-enroll --team --epoch --nonce` on that exact VM through the provider
 *    exec API (our provider key; the guest never sees it), so the channel authenticates the VM.
 * 3. The VM answers {instance_id, public_jwk, signature}: an ES256 signature by its install key
 *    over `bindMessage`. TeamVmDO consumes the nonce first (spent even on failure), then checks the
 *    nonce's epoch and VM, instance_id === the record's VM, the signature, and the epoch again
 *    after every await. Any mismatch refuses the bind; nothing is registered.
 * 4. The install is a server install of the team's owner (UserDO install.register_server, kind
 *    daemon, bound to the team, grant read + mutate-own), then `team_vm.bind_install`, then a
 *    second exec (`--commit`) tells the VM its user and install ids (not secrets: the VM gets
 *    tokens by signing auth challenges with its own key).
 */

export const ENROLL_BIN = "/opt/cmux/current/bin/cmux"
export const NONCE_TTL_MS = 5 * 60_000
export const EXEC_TIMEOUT_MS = 30_000
/** Failed binds per epoch before the bind waits for the next ensure_awake. */
export const MAX_BIND_ATTEMPTS = 8
const MAX_BIND_BACKOFF_MS = 5 * 60_000
export const bindRetryMs = (attempts: number) => Math.min(MAX_BIND_BACKOFF_MS, 5_000 * 2 ** attempts)

/** What the VM signs. */
export const bindMessage = (team: string, epoch: number, instance: string, nonce: string) => `cmux-team-vm-bind\n${team}\n${epoch}\n${instance}\n${nonce}`

const ID = /^[A-Za-z0-9_-]{1,128}$/
const ORIGIN = /^https:\/\/[a-z0-9.-]{1,200}(:[0-9]{1,5})?$/
const ENVS = new Set(["dev", "stg", "prod"])

export interface CommitArgs {
  readonly team: string
  readonly epoch: string
  readonly user: string
  readonly install: string
  readonly api: string
  readonly env: string
}

/** The enroll command. Every value is checked against a shell-safe pattern; nothing is quoted. */
export const enrollCommand = (team: string, epoch: number, nonce: string): string | null =>
  ID.test(team) && ID.test(nonce) && Number.isSafeInteger(epoch) ? `${ENROLL_BIN} host team-enroll --team ${team} --epoch ${epoch} --nonce ${nonce}` : null

export const commitCommand = (a: CommitArgs): string | null =>
  [a.team, a.epoch, a.user, a.install].every((v) => ID.test(v)) && ORIGIN.test(a.api) && ENVS.has(a.env)
    ? `${ENROLL_BIN} host team-enroll --commit --team ${a.team} --epoch ${a.epoch} --user ${a.user} --install ${a.install} --api ${a.api} --env ${a.env}`
    : null

/** The VM's env name for the auth challenge (cmux-host cloud wire `Env`). */
export const vmEnvName = (environment: string | undefined) => (environment === "production" ? "prod" : environment === "staging" ? "stg" : "dev")

/** Parses an enroll or commit command line (the fake guest and tests). */
export const parseEnrollArgs = (command: string): { team: string; epoch: number; nonce: string; commit?: undefined } | { commit: CommitArgs; team: string; epoch: number; nonce: "" } | null => {
  const words = command.trim().split(/\s+/)
  if (words[0] !== ENROLL_BIN || words[1] !== "host" || words[2] !== "team-enroll") return null
  const flags: Record<string, string> = {}
  let commit = false
  for (let i = 3; i < words.length; i++) {
    const w = words[i]!
    if (w === "--commit") commit = true
    else if (w.startsWith("--") && i + 1 < words.length) flags[w.slice(2)] = words[++i]!
    else return null
  }
  const epoch = Number(flags.epoch)
  if (!flags.team || !Number.isSafeInteger(epoch)) return null
  if (commit) {
    const c = { team: flags.team, epoch: flags.epoch!, user: flags.user ?? "", install: flags.install ?? "", api: flags.api ?? "", env: flags.env ?? "" }
    return commitCommand(c) ? { commit: c, team: c.team, epoch, nonce: "" } : null
  }
  return flags.nonce ? { team: flags.team, epoch, nonce: flags.nonce } : null
}

export interface BindProof {
  readonly instance_id: string
  readonly public_jwk: { readonly kty: "EC"; readonly crv: "P-256"; readonly x: string; readonly y: string }
  readonly signature: string
}

/** The last non-empty stdout line as a proof, or null. */
export const parseProof = (stdout: string): BindProof | null => {
  const line = stdout.trim().split("\n").pop() ?? ""
  if (line.length > 4096) return null
  let v: unknown
  try {
    v = JSON.parse(line)
  } catch {
    return null
  }
  const p = v as { instance_id?: unknown; public_jwk?: { kty?: unknown; crv?: unknown; x?: unknown; y?: unknown }; signature?: unknown }
  const b64u = (x: unknown): x is string => typeof x === "string" && /^[A-Za-z0-9_-]{1,200}$/.test(x)
  if (typeof p?.instance_id !== "string" || !ID.test(p.instance_id) || !b64u(p.signature)) return null
  const j = p.public_jwk
  if (!j || j.kty !== "EC" || j.crv !== "P-256" || !b64u(j.x) || !b64u(j.y)) return null
  return { instance_id: p.instance_id, public_jwk: { kty: "EC", crv: "P-256", x: j.x, y: j.y }, signature: p.signature }
}

const b64uRandom = (n: number) => btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(n)))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")

/** Bind bookkeeping in TeamVmDO's SQLite: nonces, attempts per epoch, and the installs each epoch bound. */
export class TeamVmBinds {
  constructor(private readonly sql: SqlStore) {
    sql.exec(`CREATE TABLE IF NOT EXISTS team_vm_bind_nonce (nonce TEXT PRIMARY KEY, epoch INTEGER NOT NULL, vm TEXT NOT NULL, expires_at INTEGER NOT NULL)`)
    sql.exec(`CREATE TABLE IF NOT EXISTS team_vm_bind_attempt (epoch INTEGER PRIMARY KEY, attempts INTEGER NOT NULL, retry_at INTEGER NOT NULL, last_error TEXT)`)
    sql.exec(`CREATE TABLE IF NOT EXISTS team_vm_bind_install (epoch INTEGER PRIMARY KEY, install TEXT NOT NULL, owner TEXT NOT NULL, committed INTEGER NOT NULL DEFAULT 0, revoked INTEGER NOT NULL DEFAULT 0)`)
  }

  /** A new single-use nonce for (epoch, vm); expired nonces are dropped. */
  mint(epoch: number, vm: string, now: number): string {
    this.sql.exec(`DELETE FROM team_vm_bind_nonce WHERE expires_at < ?`, now)
    const nonce = b64uRandom(32)
    this.sql.exec(`INSERT INTO team_vm_bind_nonce (nonce, epoch, vm, expires_at) VALUES (?, ?, ?, ?)`, nonce, epoch, vm, now + NONCE_TTL_MS)
    return nonce
  }

  /** Spends the nonce (always) and says whether it was live and minted for exactly (epoch, vm). */
  consume(nonce: string, epoch: number, vm: string, now: number): boolean {
    const row = this.sql.exec<{ epoch: number; vm: string; expires_at: number }>(`SELECT epoch, vm, expires_at FROM team_vm_bind_nonce WHERE nonce = ?`, nonce)[0]
    this.sql.exec(`DELETE FROM team_vm_bind_nonce WHERE nonce = ?`, nonce)
    return Boolean(row) && row!.epoch === epoch && row!.vm === vm && row!.expires_at >= now
  }

  /** May a bind for `epoch` run now (no attempt yet, or its backoff passed, under the attempt cap)? */
  due(epoch: number, now: number): boolean {
    const row = this.sql.exec<{ attempts: number; retry_at: number }>(`SELECT attempts, retry_at FROM team_vm_bind_attempt WHERE epoch = ?`, epoch)[0]
    return !row || (row.attempts < MAX_BIND_ATTEMPTS && row.retry_at <= now)
  }

  /** The next bind retry, for the alarm (null: none due). */
  nextRetry(epoch: number): number | null {
    const row = this.sql.exec<{ attempts: number; retry_at: number }>(`SELECT attempts, retry_at FROM team_vm_bind_attempt WHERE epoch = ?`, epoch)[0]
    return row && row.attempts < MAX_BIND_ATTEMPTS ? row.retry_at : null
  }

  failed(epoch: number, code: string, now: number): void {
    const attempts = (this.sql.exec<{ attempts: number }>(`SELECT attempts FROM team_vm_bind_attempt WHERE epoch = ?`, epoch)[0]?.attempts ?? 0) + 1
    this.sql.exec(`INSERT OR REPLACE INTO team_vm_bind_attempt (epoch, attempts, retry_at, last_error) VALUES (?, ?, ?, ?)`, epoch, attempts, now + bindRetryMs(attempts), code)
  }

  lastError(epoch: number): string | null {
    return this.sql.exec<{ last_error: string | null }>(`SELECT last_error FROM team_vm_bind_attempt WHERE epoch = ?`, epoch)[0]?.last_error ?? null
  }

  /** A new ensure_awake gives an exhausted epoch a fresh set of attempts. */
  reset(epoch: number): void {
    this.sql.exec(`DELETE FROM team_vm_bind_attempt WHERE epoch = ? AND attempts >= ?`, epoch, MAX_BIND_ATTEMPTS)
  }

  recordInstall(epoch: number, install: string, owner: string): void {
    this.sql.exec(`INSERT OR IGNORE INTO team_vm_bind_install (epoch, install, owner) VALUES (?, ?, ?)`, epoch, install, owner)
    this.sql.exec(`DELETE FROM team_vm_bind_attempt WHERE epoch = ?`, epoch)
  }

  installFor(epoch: number): { install: string; owner: string; committed: boolean } | null {
    const r = this.sql.exec<{ install: string; owner: string; committed: number }>(`SELECT install, owner, committed FROM team_vm_bind_install WHERE epoch = ?`, epoch)[0]
    return r ? { install: r.install, owner: r.owner, committed: r.committed === 1 } : null
  }

  clearAttempts(epoch: number): void {
    this.sql.exec(`DELETE FROM team_vm_bind_attempt WHERE epoch = ?`, epoch)
  }

  markCommitted(epoch: number): void {
    this.sql.exec(`UPDATE team_vm_bind_install SET committed = 1 WHERE epoch = ?`, epoch)
  }

  /** Installs of epochs before `epoch` that are not revoked yet (a restored or replaced VM's old key). */
  staleInstalls(epoch: number): Array<{ epoch: number; install: string; owner: string }> {
    return this.sql.exec<{ epoch: number; install: string; owner: string }>(`SELECT epoch, install, owner FROM team_vm_bind_install WHERE epoch < ? AND revoked = 0`, epoch)
  }

  markRevoked(epoch: number): void {
    this.sql.exec(`UPDATE team_vm_bind_install SET revoked = 1 WHERE epoch = ?`, epoch)
  }
}

/** Checks a proof against the nonce's (epoch, vm) and the record's VM. Consumes the nonce. */
export const checkProof = async (
  binds: TeamVmBinds,
  proof: BindProof,
  want: { team: string; epoch: number; vm: string; nonce: string },
  now: number
): Promise<{ ok: true } | { ok: false; code: string }> => {
  if (!binds.consume(want.nonce, want.epoch, want.vm, now)) return { ok: false, code: "team_vm.bind_nonce" }
  if (proof.instance_id !== want.vm) return { ok: false, code: "team_vm.bind_instance" }
  const ok = await verifyInstallSignature(proof.public_jwk, bindMessage(want.team, want.epoch, proof.instance_id, want.nonce), proof.signature)
  return ok ? { ok: true } : { ok: false, code: "team_vm.bind_signature" }
}
