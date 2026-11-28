import type { SqlStore } from "@cmux/ownership"
import { SignJWT } from "jose"
import { issuer, signer } from "./auth.ts"
import type { EdgeTlsRule } from "./cloud-driver-body.ts"
import type { Env } from "./env.ts"

/**
 * The coderouter edge of a Cloud machine (plans/cmux-next/vm-coderouter-edge.md). The image's agents
 * dial https://coderouter.cmux.internal with a public placeholder key (web/services/coderouter/
 * vmGuestEnv.ts). An inline Freestyle TLS rule steers that name to the coderouter host and injects
 * one header with a per-machine token; the guest never holds a credential.
 *
 * The token is an ES256 JWT signed with the API's own key (auth.ts signer) in the shape coderouter's
 * external machine verifier takes (web/services/coderouter/chatmuxVmToken.ts): aud coderouter,
 * sub vm:<machine>, team_id and owner_id = the creator's Stack user id (coderouter's personal scope),
 * role dev, 1 hour. installPrincipal requires aud api, so it never acts on this backend.
 * coderouter gives it only the scope's shared accounts and no account management.
 *
 * Development only: staging and production send no rule (no coderouter trusts their issuer yet).
 * The token and the rule are never logged, stored or returned; only the machine id and outcomes are.
 */

export const CODEROUTER_EDGE_DOMAIN = "coderouter.cmux.internal"
export const CODEROUTER_EDGE_HEADER = "x-chatmux-vm-authorization"
export const CODEROUTER_TOKEN_TTL_S = 3600
/** A running machine's token is replaced this long after its mint, well inside its 1-hour life. */
export const CODEROUTER_REFRESH_MS = 30 * 60_000
const RETRY_MS = 60_000
const NEVER = Number.MAX_SAFE_INTEGER
const HOST = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/
const ON = new Set(["development", "test"])

/** The edge configuration, or null when this deployment sends no rule. */
export const coderouterEdgeConfig = (env: { ENVIRONMENT?: string; CLOUD_CODEROUTER_EDGE_HOST?: string }): { host: string } | null => {
  if (!ON.has(env.ENVIRONMENT ?? "")) return null
  const host = env.CLOUD_CODEROUTER_EDGE_HOST?.trim().toLowerCase()
  return host && HOST.test(host) ? { host } : null
}

export const mintCoderouterMachineToken = async (env: Env, c: { machine: string; owner: string; now: number }): Promise<string> => {
  const { key, kid } = await signer(env)
  const iat = Math.floor(c.now / 1000)
  return new SignJWT({ team_id: c.owner, owner_id: c.owner, role: "dev" })
    .setProtectedHeader({ alg: "ES256", kid, typ: "cmux-machine+jwt" })
    .setIssuer(issuer(env))
    .setAudience("coderouter")
    .setSubject(`vm:${c.machine}`)
    .setJti(crypto.randomUUID())
    .setIssuedAt(iat)
    .setExpirationTime(iat + CODEROUTER_TOKEN_TTL_S)
    .sign(key)
}

/** The rule for a create (`source: {}` = the new VM) or a replace (the driver sets `source.vmId`). */
export const coderouterEdgeRule = (host: string, token: string): EdgeTlsRule => ({
  action: "allow",
  domain: CODEROUTER_EDGE_DOMAIN,
  source: {},
  destination: { host, port: 443 },
  transform: [{ headers: { [CODEROUTER_EDGE_HEADER]: `Bearer ${token}` } }]
})

/**
 * When each machine's token is due for replacement (CloudDO's SQLite; times only, never a token).
 * A paused machine is due never; a start makes it due at once.
 */
export class CoderouterEdgeSchedule {
  private ready = false
  constructor(private readonly sql: SqlStore) {}
  private table() {
    if (!this.ready) this.sql.exec(`CREATE TABLE IF NOT EXISTS cloud_coderouter_edge (machine TEXT PRIMARY KEY, minted_at INTEGER NOT NULL, due_at INTEGER NOT NULL)`)
    this.ready = true
  }
  minted(machine: string, now: number) {
    this.table()
    this.sql.exec(`INSERT INTO cloud_coderouter_edge (machine, minted_at, due_at) VALUES (?, ?, ?) ON CONFLICT(machine) DO UPDATE SET minted_at = excluded.minted_at, due_at = excluded.due_at`, machine, now, now + CODEROUTER_REFRESH_MS)
  }
  retry(machine: string, now: number) {
    this.table()
    this.sql.exec(`UPDATE cloud_coderouter_edge SET due_at = ? WHERE machine = ?`, now + RETRY_MS, machine)
  }
  park(machine: string) {
    this.table()
    this.sql.exec(`UPDATE cloud_coderouter_edge SET due_at = ? WHERE machine = ?`, NEVER, machine)
  }
  forget(machine: string) {
    this.table()
    this.sql.exec(`DELETE FROM cloud_coderouter_edge WHERE machine = ?`, machine)
  }
  has(machine: string): boolean {
    this.table()
    return this.sql.exec(`SELECT 1 FROM cloud_coderouter_edge WHERE machine = ?`, machine).length > 0
  }
  due(now: number): Array<string> {
    this.table()
    return this.sql.exec<{ machine: string }>(`SELECT machine FROM cloud_coderouter_edge WHERE due_at <= ? ORDER BY due_at LIMIT 20`, now).map((r) => r.machine)
  }
  dueAt(): number | null {
    this.table()
    const t = this.sql.exec<{ t: number | null }>(`SELECT min(due_at) AS t FROM cloud_coderouter_edge WHERE due_at < ?`, NEVER)[0]?.t
    return t === null || t === undefined ? null : Number(t)
  }
}

type EdgeRow = { readonly creator: string; readonly status: string; readonly provider_name: string }
type EdgeDriver = { replaceEdgeRule(name: string, tag: { team: string; machine: string }, rule: EdgeTlsRule): Promise<boolean> }
const log = (outcome: string, machine: string, extra: Record<string, unknown> = {}) => console.log(JSON.stringify({ msg: "cloud coderouter edge", outcome, machine, ...extra }))

/** CloudDO's use of the edge: the rule a create carries, and the token refresh of running machines. */
export class CoderouterEdge {
  readonly schedule: CoderouterEdgeSchedule
  /** Test only (fakeControl `edge_host`): replaces CLOUD_CODEROUTER_EDGE_HOST; null = unset. */
  testHost: string | null | undefined
  constructor(
    sql: SqlStore,
    private readonly env: Env
  ) {
    this.schedule = new CoderouterEdgeSchedule(sql)
  }

  config(): { host: string } | null {
    return coderouterEdgeConfig({ ENVIRONMENT: this.env.ENVIRONMENT, CLOUD_CODEROUTER_EDGE_HOST: this.testHost === undefined ? this.env.CLOUD_CODEROUTER_EDGE_HOST : (this.testHost ?? undefined) })
  }

  /** The creator's Stack user id from their UserDO (user.ensure records it), or null. */
  private async owner(creator: string): Promise<string | null> {
    try {
      return await this.env.USER_DO.get(this.env.USER_DO.idFromName(creator)).stackUserOf(creator)
    } catch {
      return null
    }
  }

  /** The rule a create sends, or null (edge off, or no Stack user on record: the machine is made without a model route). */
  async ruleForCreate(machine: string, creator: string | undefined, now: number): Promise<EdgeTlsRule | null> {
    const cfg = this.config()
    if (!cfg) return null
    const owner = creator ? await this.owner(creator) : null
    if (!owner) {
      log("skipped_no_owner", machine)
      return null
    }
    return coderouterEdgeRule(cfg.host, await mintCoderouterMachineToken(this.env, { machine, owner, now }))
  }

  /** The create that carried the rule reached the provider. */
  created(machine: string, now: number) {
    this.schedule.minted(machine, now)
    log("created", machine, { expires_at: now + CODEROUTER_TOKEN_TTL_S * 1000 })
  }

  /** A start of a machine that has a rule: replace its token now. */
  async started(driver: EdgeDriver, team: string, machine: string, row: EdgeRow | undefined, now: number) {
    if (this.schedule.has(machine)) await this.refresh(driver, team, machine, row, now)
  }

  /** Replaces the token of a running machine; parks a paused one and forgets a gone one. Never throws. */
  async refresh(driver: EdgeDriver, team: string, machine: string, row: EdgeRow | undefined, now: number) {
    const cfg = this.config()
    if (!cfg || !row || row.status === "deleting" || row.status === "failed") return this.schedule.forget(machine)
    if (row.status !== "running" && row.status !== "starting") return this.schedule.park(machine)
    const owner = await this.owner(row.creator)
    if (!owner) {
      this.schedule.retry(machine, now)
      return log("refresh_no_owner", machine)
    }
    try {
      const rule = coderouterEdgeRule(cfg.host, await mintCoderouterMachineToken(this.env, { machine, owner, now }))
      if (await driver.replaceEdgeRule(row.provider_name, { team, machine }, rule)) {
        this.schedule.minted(machine, now)
        log("refreshed", machine, { expires_at: now + CODEROUTER_TOKEN_TTL_S * 1000 })
      } else {
        this.schedule.forget(machine)
        log("no_rule", machine)
      }
    } catch (e) {
      this.schedule.retry(machine, now)
      // DriverError messages carry only the step, status and provider code (cloud-driver.ts fail), never the rule.
      log("refresh_failed", machine, { error: e instanceof Error ? e.message.slice(0, 160) : "unknown" })
    }
  }
}
