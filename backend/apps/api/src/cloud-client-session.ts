import type { Principal, SqlStore } from "@cmux/ownership"
import { authenticate } from "./auth.ts"
import { readBody } from "./cloud-acpmux.ts"
import type { ClientSessionGrant, GuardedCloudDriver } from "./cloud-driver.ts"
import type { MachineRow } from "./domains/cloud.ts"
import type { Env } from "./env.ts"
import { ssoGate } from "./policy-gate.ts"
import { ClientIdentityLeft, DriverError } from "./providers/contract.ts"
import { principalForOwner, selectTeam, TEAM_HEADER } from "./team-select.ts"

/**
 * Client sessions on a Cloud machine (freestyle.sh/docs/vms/client-sessions; `cmux cloud
 * client-session`): a short-lived provider token that reaches ONE machine as its work user, so the
 * CLI can run a command or open a shell there without the team's provider key.
 *
 *   POST /v1/cloud/machines/{machine}/client-session   body: {"ttl_seconds"?: 60..900}
 *
 * A plain HTTP route outside the op path (like /v1/cloud/bind and the acpmux routes): each call mints
 * a fresh token, nothing replays, and no op, event, ledger row or log line holds it. Rules:
 * - who: a person's session, or a cli or mac install whose grant covers execute; never an agent, a VM
 *   install or another install kind;
 * - which machine: one of the caller's team (the team's CloudDO answers only its own rows, so another
 *   team's machine is not found) that the caller created; on a shared team only while still a member;
 * - when: the machine is running, and the team has a Cloud plan (the existing gate: no plan, no token);
 * - what: the provider identity is granted only this machine's VM and only LINUX_USER, never root or
 *   every user; the token expires after ttl_seconds (default 10 minutes, at most 15).
 * The audit row holds who, which machine, the user and the expiry, never the token.
 */
export const CLIENT_SESSION_PATH = /^\/v1\/cloud\/machines\/(vm_[a-z0-9]{20})\/client-session$/

/** The image's work user (images/cmux-vm: /home/cmux). */
export const CLIENT_SESSION_LINUX_USER = "cmux"
export const CLIENT_SESSION_TTL_DEFAULT_S = 600
export const CLIENT_SESSION_TTL_MIN_S = 60
export const CLIENT_SESSION_TTL_MAX_S = 900
const BODY_MAX = 256
const CLIENT_INSTALL_KINDS: ReadonlyArray<string> = ["cli", "mac"]

export type ClientSessionRefusal =
  | "forbidden"
  | "not_found"
  | "not_creator"
  | "paused"
  | "not_running"
  | "plan_required"
  | "rate_limited"
  | "unsupported"
  | "provider_failed"
  | "bad_request"

export interface ClientSessionValue {
  readonly machine: string
  readonly vm_id: string
  readonly linux_user: string
  /** Secret: shown once, never logged or stored. */
  readonly token: string
  readonly expires_at: number
  readonly api_base_url: string
  readonly ssh: { readonly host: string; readonly user: string } | null
}

export type ClientSessionReply = { readonly ok: true; readonly value: ClientSessionValue } | { readonly ok: false; readonly refusal: ClientSessionRefusal }

/**
 * One identity per (machine, user), so repeated sessions reuse it instead of making a new provider
 * identity each time. An identity that must go (a VM the machine no longer has, a machine that is
 * gone) moves to the retired table first and leaves it only once the provider confirms the delete,
 * so a failed delete is retried (on the next mint, machine delete or alarm) and never forgotten.
 */
export class ClientIdentityStore {
  constructor(private readonly sql: SqlStore) {
    sql.exec(`CREATE TABLE IF NOT EXISTS cloud_client_identity (machine TEXT NOT NULL, user TEXT NOT NULL, identity TEXT NOT NULL, vm TEXT NOT NULL, at INTEGER NOT NULL, PRIMARY KEY (machine, user))`)
    sql.exec(`CREATE TABLE IF NOT EXISTS cloud_client_identity_retired (identity TEXT PRIMARY KEY, at INTEGER NOT NULL, user TEXT)`)
  }

  get(machine: string, user: string): { identity: string; vmId: string } | null {
    const r = this.sql.exec<{ identity: string; vm: string }>(`SELECT identity, vm FROM cloud_client_identity WHERE machine = ? AND user = ?`, machine, user)[0]
    return r ? { identity: r.identity, vmId: r.vm } : null
  }

  /** Records the current identity; a different one it replaces is retired in the same transaction. */
  put(machine: string, user: string, identity: string, vmId: string, at: number): void {
    this.sql.transaction(() => {
      const before = this.get(machine, user)
      if (before && before.identity !== identity) this.retire(before.identity, at, user)
      this.sql.exec(`INSERT OR REPLACE INTO cloud_client_identity (machine, user, identity, vm, at) VALUES (?, ?, ?, ?, ?)`, machine, user, identity, vmId, at)
    })
  }

  /** Queues `identity` for its delete; `user` (whose it was) lets a departure find it again. */
  retire(identity: string, at: number, user: string | null): void {
    this.sql.exec(`INSERT OR IGNORE INTO cloud_client_identity_retired (identity, at, user) VALUES (?, ?, ?)`, identity, at, user)
  }

  /** Retires the identities of every machine `gone` says is gone (deleted, deleting or failed). */
  retireGone(gone: (machine: string) => boolean, at: number): void {
    const rows = this.sql.exec<{ machine: string; user: string; identity: string }>(`SELECT machine, user, identity FROM cloud_client_identity`)
    for (const r of rows.filter((x) => gone(x.machine))) {
      this.sql.transaction(() => {
        this.retire(r.identity, at, r.user)
        this.sql.exec(`DELETE FROM cloud_client_identity WHERE machine = ? AND user = ?`, r.machine, r.user)
      })
    }
  }

  /** At most `limit` retired identities, oldest first. */
  retired(limit: number): Array<string> {
    return this.sql.exec<{ identity: string }>(`SELECT identity FROM cloud_client_identity_retired ORDER BY at LIMIT ?`, limit).map((r) => r.identity)
  }

  /** Retires every identity `user` holds (they left the team) and returns those and every retired one of theirs still waiting. */
  forgetUser(user: string, at: number): Array<string> {
    return this.sql.transaction(() => {
      const ids = this.sql.exec<{ identity: string }>(`SELECT identity FROM cloud_client_identity WHERE user = ?`, user).map((r) => r.identity)
      for (const id of ids) this.retire(id, at, user)
      this.sql.exec(`DELETE FROM cloud_client_identity WHERE user = ?`, user)
      return this.sql.exec<{ identity: string }>(`SELECT identity FROM cloud_client_identity_retired WHERE user = ?`, user).map((r) => r.identity)
    })
  }

  /** Retires the current identity of (machine, user) and forgets it. */
  forget(machine: string, user: string, at: number): void {
    this.sql.transaction(() => {
      const current = this.get(machine, user)
      if (current) this.retire(current.identity, at, user)
      this.sql.exec(`DELETE FROM cloud_client_identity WHERE machine = ? AND user = ?`, machine, user)
    })
  }

  dropped(identity: string): void {
    this.sql.exec(`DELETE FROM cloud_client_identity_retired WHERE identity = ?`, identity)
  }

  /** Whether any identity is waiting for its delete. */
  pending(): boolean {
    return this.sql.exec<{ n: number }>(`SELECT count(*) AS n FROM cloud_client_identity_retired`)[0]!.n > 0
  }
}

/**
 * Retires the identities of gone machines, then deletes up to `limit` retired identities at the
 * provider; only a confirmed delete (or 404) removes one. True when some are still waiting.
 */
export const sweepClientIdentities = async (store: ClientIdentityStore, machine: (id: string) => MachineRow | undefined, driver: GuardedCloudDriver, now: number, limit = 10, first: ReadonlyArray<string> = []): Promise<boolean> => {
  store.retireGone((id) => {
    const st = machine(id)?.status
    return st === undefined || st === "deleting" || st === "failed"
  }, now)
  // `first` (a departed member's identities) all go now, outside the limit.
  for (const identity of [...new Set([...first, ...store.retired(limit)])]) if (await driver.dropClientIdentity(identity).then(() => true, () => false)) store.dropped(identity)
  return store.pending()
}

/** What CloudDO gives the mint (tests replace any part). */
export interface ClientSessionHost {
  readonly team: string
  machine(id: string): MachineRow | undefined
  /**
   * Personal team: true. Shared team: the user is a member with team.resources now (fresh; a failed
   * read is false) and no departure notice arrived since `since` (a leave and rejoin during a mint
   * still refuses it).
   */
  member(user: string, since: number): Promise<boolean>
  /** The team has a Cloud plan (refreshed entitlements, or the stub allowlist). */
  plan(principal: Principal): Promise<boolean>
  /** False when the caller is over the mint limit. */
  limit(user: string): Promise<boolean>
  driver(row: MachineRow): Promise<GuardedCloudDriver | null>
  readonly identities: ClientIdentityStore
  audit(entry: Record<string, unknown>): void
  now(): number
  /** Some retired identity is still waiting for its delete: arm the alarm to retry it. */
  retryLater(): void
  /** Mints in flight per (machine, user): one at a time, so two calls never make two identities. */
  readonly inflight: Map<string, Promise<unknown>>
}

const refuse = (refusal: ClientSessionRefusal): ClientSessionReply => ({ ok: false, refusal })

/** The caller may mint at all: a person, or a cli or mac install with execute; never an agent or a machine. */
export const clientSessionCaller = (p: Principal): boolean => {
  if (!p.user || !p.team || p.agent !== undefined) return false
  if (p.kind === "session") return p.install === undefined
  return p.kind === "install" && CLIENT_INSTALL_KINDS.includes(p.install_kind ?? "") && Boolean(p.grant_classes?.includes("execute"))
}

/** The ttl a request asks for: absent is the default; anything else must be an integer in range. */
export const clientSessionTtl = (body: unknown): number | null => {
  if (body === null || body === undefined) return CLIENT_SESSION_TTL_DEFAULT_S
  if (typeof body !== "object" || Array.isArray(body)) return null
  const keys = Object.keys(body)
  if (keys.some((k) => k !== "ttl_seconds")) return null
  const ttl = (body as { ttl_seconds?: unknown }).ttl_seconds
  if (ttl === undefined) return CLIENT_SESSION_TTL_DEFAULT_S
  return typeof ttl === "number" && Number.isInteger(ttl) && ttl >= CLIENT_SESSION_TTL_MIN_S && ttl <= CLIENT_SESSION_TTL_MAX_S ? ttl : null
}

/** CloudDO's half: checks the caller and the machine, then mints through the guarded driver. */
export const mintClientSessionOn = async (host: ClientSessionHost, p: Principal, machine: string, ttlSeconds: number): Promise<ClientSessionReply> => {
  if (!clientSessionCaller(p) || p.team !== host.team) return refuse("forbidden")
  if (ttlSeconds < CLIENT_SESSION_TTL_MIN_S || ttlSeconds > CLIENT_SESSION_TTL_MAX_S || !Number.isInteger(ttlSeconds)) return refuse("bad_request")
  const user = p.user!
  const row = host.machine(machine)
  if (!row || row.status === "deleting" || row.status === "failed") return refuse("not_found")
  // "The caller's own machines": the one who created it, also on a shared team (a teammate's machine runs as its creator).
  if (row.creator !== user) return refuse("not_creator")
  const since = Date.now()
  if (!(await host.member(user, since).catch(() => false))) return refuse("forbidden")
  if (!(await host.plan(p).catch(() => false))) return refuse("plan_required")
  if (row.status === "paused" || row.status === "pausing" || row.status === "starting") return refuse("paused")
  if (row.status !== "running") return refuse("not_running")
  if (!(await host.limit(user).catch(() => false))) return refuse("rate_limited")
  const key = `${machine}:${user}`
  const before = host.inflight.get(key)
  const run = (async (): Promise<ClientSessionReply> => {
    await before?.catch(() => undefined)
    const driver = await host.driver(row).catch(() => null)
    if (!driver) return refuse("provider_failed")
    if (!driver.capabilities.clientSession) return refuse("unsupported")
    const expiresAt = host.now() + ttlSeconds * 1000
    let minted: { grant: ClientSessionGrant; stale: string | null }
    try {
      minted = await driver.clientSession(row.provider_name, { team: host.team, machine }, CLIENT_SESSION_LINUX_USER, expiresAt, host.identities.get(machine, user))
    } catch (e) {
      if (e instanceof ClientIdentityLeft) {
        if (host.identities.get(machine, user)?.identity === e.identity) host.identities.forget(machine, user, host.now())
        else host.identities.retire(e.identity, host.now(), user)
        // Deleted now, not at the next alarm: a failed delete stays retired and is retried.
        if (await sweepClientIdentities(host.identities, host.machine, driver, host.now()).catch(() => true)) host.retryLater()
      }
      // Only a code: a DriverError's message names the step and status, never a body or a token.
      const code = e instanceof DriverError ? e.code : "cloud.provider.unavailable"
      host.audit({ op: "client_session", machine, by: p.identity, user, install: p.install ?? null, outcome: code, at: host.now() })
      return refuse(code === "cloud.provider.unsupported" ? "unsupported" : code === "cloud.provider.vm_missing" ? "not_running" : "provider_failed")
    }
    const { grant, stale } = minted
    host.identities.put(machine, user, grant.identity, grant.vmId, host.now())
    if (stale) host.identities.retire(stale, host.now(), user)
    if (await sweepClientIdentities(host.identities, host.machine, driver, host.now()).catch(() => true)) host.retryLater()
    // The membership check is the last wait before the answer: a member who left while the provider
    // calls or the sweep ran gets nothing, and the new identity is retired and deleted.
    if (!(await host.member(user, since).catch(() => false))) {
      // Every identity of theirs goes now, ahead of the queue and outside its limit (as on a team-left notice).
      const theirs = host.identities.forgetUser(user, host.now())
      host.audit({ op: "client_session", machine, by: p.identity, user, install: p.install ?? null, outcome: "auth.forbidden", at: host.now() })
      if (await sweepClientIdentities(host.identities, host.machine, driver, host.now(), 10, theirs).catch(() => true)) host.retryLater()
      return refuse("forbidden")
    }
    // A token that would expire within seconds of the answer is no session.
    if (grant.expiresAt - host.now() < CLIENT_SESSION_TTL_MIN_S * 500) {
      host.audit({ op: "client_session", machine, by: p.identity, user, install: p.install ?? null, outcome: "cloud.provider.unavailable", at: host.now() })
      return refuse("provider_failed")
    }
    host.audit({ op: "client_session", machine, by: p.identity, user, install: p.install ?? null, linux_user: grant.linuxUser, expires_at: grant.expiresAt, outcome: "minted", at: host.now() })
    return {
      ok: true,
      value: { machine, vm_id: grant.vmId, linux_user: grant.linuxUser, token: grant.token, expires_at: grant.expiresAt, api_base_url: grant.apiBaseUrl, ssh: grant.ssh }
    }
  })()
  const settled = run.finally(() => {
    if (host.inflight.get(key) === settled) host.inflight.delete(key)
  })
  host.inflight.set(key, settled)
  return settled
}

// ---- The Worker route

const NO_STORE = { "cache-control": "no-store" }
const answer = (status: number, code: string, message: string) => Response.json({ ok: false, error: { code, message } }, { status, headers: NO_STORE })

const REFUSAL: Readonly<Record<ClientSessionRefusal, [number, string, string]>> = {
  forbidden: [403, "auth.forbidden", "client sessions need a person's session or a cmux CLI or Mac install"],
  not_found: [404, "cloud.machine.not_found", "no such machine in this team"],
  not_creator: [403, "auth.forbidden", "a client session is only for a machine you created"],
  paused: [409, "cloud.machine.paused", "the machine is paused; start it first"],
  not_running: [409, "cloud.machine.not_running", "the machine is not running"],
  plan_required: [403, "cloud.plan.required", "this team has no Cloud plan"],
  rate_limited: [429, "cloud.rate_limited", "too many client sessions; retry in a minute"],
  unsupported: [501, "cloud.provider.unsupported", "this machine's provider has no client sessions"],
  provider_failed: [502, "cloud.provider.unavailable", "the machine's provider did not answer; retry"],
  bad_request: [400, "validation.invalid", "invalid client session request"]
}

type Stub = { mintClientSession(entity: string, p: Principal, machine: string, ttlSeconds: number): Promise<ClientSessionReply> }

/** The caller's principal for the team's CloudDO (as the acpmux routes find it, installs allowed), or the refusal. */
const callerFor = async (request: Request, env: Env): Promise<Principal | Response> => {
  const auth = request.headers.get("authorization") ?? ""
  const token = await authenticate(env, auth.startsWith("Bearer ") ? auth.slice(7) : undefined)
  if (!token?.user || !token.team) return answer(401, "auth.unauthenticated", "a session or install token is required")
  const selected = await selectTeam(env, { ...token, user: token.user, team: token.team }, request.headers.get(TEAM_HEADER))
  if (!selected.ok) return answer(selected.code === "owner.unreachable" ? 503 : 403, selected.code, selected.message)
  const gate = await ssoGate(env, selected.principal).catch(() => null)
  if (!gate) return answer(503, "owner.unreachable", "the sign-in policy could not be checked; retry")
  if (gate.refusal) return answer(403, gate.refusal.code, gate.refusal.message)
  const { stack_session: _session, email_domain: _domain, ...authed } = gate.principal
  const granted = await principalForOwner(env, "cloud:CloudDO", authed).catch(() => null)
  if (granted === null) return answer(503, "owner.unreachable", "team membership could not be checked; retry")
  if (!granted || "refused" in granted) return answer(403, "auth.forbidden", "no access to this team's machines")
  if (!clientSessionCaller(granted)) return answer(...REFUSAL.forbidden)
  return granted
}

export const handleCloudClientSession = async (request: Request, env: Env, machine: string): Promise<Response> => {
  if (request.method !== "POST") return Response.json({ ok: false, error: { code: "validation.invalid", message: "POST only" } }, { status: 405, headers: { allow: "POST", ...NO_STORE } })
  if (new URL(request.url).search !== "") return answer(400, "validation.invalid", "client session requests carry no query")
  const declared = Number(request.headers.get("content-length") ?? "0")
  if (!(declared >= 0 && declared <= BODY_MAX)) return answer(400, "validation.invalid", "the request body is too large")
  const principal = await callerFor(request, env)
  if (principal instanceof Response) return principal
  // Read at most BODY_MAX bytes, also for a chunked body with no content-length.
  const bytes = await readBody(request, BODY_MAX).catch(() => null)
  if (bytes === null) return answer(400, "validation.invalid", "the request body is too large")
  const raw = new TextDecoder().decode(bytes)
  let body: unknown = null
  if (raw.trim() !== "") {
    try {
      body = JSON.parse(raw)
    } catch {
      return answer(...REFUSAL.bad_request)
    }
  }
  const ttl = clientSessionTtl(body)
  if (ttl === null) return answer(400, "validation.invalid", `ttl_seconds must be an integer from ${CLIENT_SESSION_TTL_MIN_S} to ${CLIENT_SESSION_TTL_MAX_S}`)
  const stub = env.CLOUD_DO.get(env.CLOUD_DO.idFromName(principal.team!)) as unknown as Stub
  let r: ClientSessionReply
  try {
    r = await stub.mintClientSession(principal.team!, principal, machine, ttl)
  } catch {
    return answer(503, "owner.unreachable", "the Cloud service could not be reached; retry")
  }
  if (r.ok) return Response.json({ ok: true, value: r.value }, { headers: NO_STORE })
  return answer(...(REFUSAL[r.refusal] ?? REFUSAL.provider_failed))
}
