import type { SqlStore } from "@cmux/ownership"
import type { Env } from "./env.ts"
import type { ProviderState } from "./domains/team-vm.ts"

/**
 * The provider behind TeamVmDO (plans/cmux-next/team-vm-plan.md S2). Two calls, both idempotent:
 * `ensureVm` creates the VM under a slug that is unique in the provider account (a retry after an
 * unknown outcome finds the VM by slug instead of creating a second one), and `ensureRunning`
 * starts a paused VM and reports the observed state.
 */
export interface TeamVmDriver {
  ensureVm(slug: string, team: string, epoch: number): Promise<{ readonly id: string; readonly state: ProviderState }>
  ensureRunning(id: string): Promise<{ readonly state: ProviderState }>
}

export class DriverError extends Error {
  constructor(
    readonly code: string,
    message: string,
    /** True when retrying cannot help (configuration, authorization, a deleted VM). */
    readonly final: boolean
  ) {
    super(message)
  }
}

const PROVIDER_STATES: ReadonlySet<string> = new Set(["starting", "running", "pausing", "paused", "stopped"])
const asState = (s: unknown): ProviderState => (typeof s === "string" && PROVIDER_STATES.has(s) ? (s as ProviderState) : "starting")

/** Idle pause: the provider pauses the VM after this long without activity (spec: about 10 minutes). */
const IDLE_TIMEOUT_SECONDS = 600
/** One provider request; a wake is normally well under a second, the first one after a long pause a few seconds. */
const REQUEST_TIMEOUT_MS = 20_000
/** A create can take much longer than a wake (the web driver allows minutes); a lost answer is recovered by slug. */
const CREATE_TIMEOUT_MS = 120_000
const nonEmpty = (v: unknown): v is string => typeof v === "string" && v.length > 0

export class FreestyleDriver implements TeamVmDriver {
  constructor(
    private readonly apiKey: string,
    private readonly baseUrl: string,
    private readonly snapshot: string
  ) {}

  private async call(method: string, path: string, body?: unknown, timeoutMs = REQUEST_TIMEOUT_MS): Promise<{ status: number; json: Record<string, unknown> }> {
    let res: Response
    try {
      res = await fetch(`${this.baseUrl.replace(/\/+$/, "")}${path}`, {
        method,
        headers: { authorization: `Bearer ${this.apiKey}`, ...(body === undefined ? {} : { "content-type": "application/json" }) },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
        signal: AbortSignal.timeout(timeoutMs)
      })
    } catch (e) {
      // Network failure or timeout: the outcome is unknown (a create may still have happened).
      return { status: 0, json: { code: e instanceof Error && e.name === "TimeoutError" ? "TIMEOUT" : "UNREACHABLE" } }
    }
    const json = (await res.json().catch(() => ({}))) as Record<string, unknown>
    return { status: res.status, json }
  }

  /** Members can read the error: only the step, the HTTP status and the provider's error code, never its message. */
  private fail(status: number, json: Record<string, unknown>, what: string): never {
    const final = status === 400 || status === 401 || status === 403 || status === 422
    const code = typeof json.code === "string" ? json.code.slice(0, 40) : ""
    throw new DriverError(final ? "team_vm.provider_refused" : "team_vm.provider_failed", `${what}: ${status || "no answer"}${code ? ` ${code}` : ""}`, final)
  }

  /**
   * Creates the VM under `slug` (unique in the provider account; a duplicate create answers 409,
   * measured 2026-10-03) and tags it with the team and epoch. On any answer but success (including
   * a timeout, where the create may have happened) it reads the slug: a VM there with this team's
   * tag is the one an earlier attempt made, so a retry never makes a second VM.
   */
  async ensureVm(slug: string, team: string, epoch: number) {
    const created = await this.call(
      "POST",
      "/v5/vms",
      {
        slug,
        snapshotId: this.snapshot,
        idleTimeoutSeconds: IDLE_TIMEOUT_SECONDS,
        metadata: { cmux_team: team, cmux_epoch: String(epoch) },
        firewall: { rules: [{ action: "allow", source: {}, destination: { public: true } }] }
      },
      CREATE_TIMEOUT_MS
    )
    if (created.status >= 200 && created.status < 300) {
      if (!nonEmpty(created.json.id)) throw new DriverError("team_vm.provider_refused", "create VM: answer without an id", true)
      return { id: created.json.id, state: asState(created.json.state) }
    }
    const got = await this.call("GET", `/v5/vms/${encodeURIComponent(slug)}`)
    if (got.status === 200 && nonEmpty(got.json.id)) {
      const tag = (got.json.metadata ?? {}) as Record<string, unknown>
      if (tag.cmux_team === team) return { id: got.json.id, state: asState(got.json.state) }
      throw new DriverError("team_vm.slug_conflict", "create VM: the slug belongs to another VM", true)
    }
    this.fail(created.status, created.json, "create VM")
  }

  async ensureRunning(id: string) {
    const got = await this.call("GET", `/v5/vms/${encodeURIComponent(id)}`)
    // The VM is gone (deleted outside cmux): the reducer replaces it with a new one under the next epoch.
    if (got.status === 404) throw new DriverError("team_vm.vm_missing", "read VM: 404", true)
    if (got.status !== 200) this.fail(got.status, got.json, "read VM")
    const state = asState(got.json.state)
    if (state === "running" || state === "starting") return { state }
    const started = await this.call("POST", `/v5/vms/${encodeURIComponent(id)}/start`)
    if (started.status < 200 || started.status >= 300) this.fail(started.status, started.json, "start VM")
    return { state: started.json.state === undefined ? ("running" as const) : asState(started.json.state) }
  }
}

/**
 * Test driver (ENVIRONMENT=test only): VMs live in the DO's own SQLite, so tests see exactly what
 * the object did. `fake_ctl.fail_next` makes the next calls fail (retryable) to test backoff; deleting a `fake_vm` row stands for a VM deleted outside cmux.
 */
export class FakeDriver implements TeamVmDriver {
  constructor(private readonly sql: SqlStore) {
    sql.exec(`CREATE TABLE IF NOT EXISTS fake_vm (slug TEXT PRIMARY KEY, id TEXT NOT NULL UNIQUE, state TEXT NOT NULL)`)
    sql.exec(`CREATE TABLE IF NOT EXISTS fake_ctl (id INTEGER PRIMARY KEY CHECK (id = 1), fail_next INTEGER NOT NULL DEFAULT 0, creates INTEGER NOT NULL DEFAULT 0, starts INTEGER NOT NULL DEFAULT 0)`)
    sql.exec(`INSERT OR IGNORE INTO fake_ctl (id) VALUES (1)`)
  }

  private maybeFail() {
    const n = this.sql.exec<{ fail_next: number }>(`SELECT fail_next FROM fake_ctl WHERE id = 1`)[0]!.fail_next
    if (n > 0) {
      this.sql.exec(`UPDATE fake_ctl SET fail_next = fail_next - 1 WHERE id = 1`)
      throw new DriverError("team_vm.provider_failed", "fake provider failure", false)
    }
  }

  async ensureVm(slug: string, _team: string, _epoch: number) {
    this.maybeFail()
    const row = this.sql.exec<{ id: string; state: string }>(`SELECT id, state FROM fake_vm WHERE slug = ?`, slug)[0]
    if (row) return { id: row.id, state: asState(row.state) }
    const id = `fakevm-${slug}`
    this.sql.exec(`INSERT INTO fake_vm (slug, id, state) VALUES (?, ?, 'running')`, slug, id)
    this.sql.exec(`UPDATE fake_ctl SET creates = creates + 1 WHERE id = 1`)
    return { id, state: "running" as const }
  }

  async ensureRunning(id: string) {
    this.maybeFail()
    const row = this.sql.exec<{ state: string }>(`SELECT state FROM fake_vm WHERE id = ?`, id)[0]
    if (!row) throw new DriverError("team_vm.vm_missing", "read VM: 404", true)
    if (row.state !== "running") {
      this.sql.exec(`UPDATE fake_vm SET state = 'running' WHERE id = ?`, id)
      this.sql.exec(`UPDATE fake_ctl SET starts = starts + 1 WHERE id = 1`)
    }
    return { state: "running" as const }
  }
}

/**
 * Production guard until the plan gate (S2b) lands: in production no team VM is created or
 * started, even if FREESTYLE_API_KEY is set by mistake. The S2b slice sets this to true together
 * with the gate and its tests (plans/cmux-next/team-vm-plan.md 3a).
 */
export const PRODUCTION_PLAN_GATE_LANDED = false

/** The refusal code when this deployment must not call the provider yet, else null. */
export const providerRefusal = (env: Pick<Env, "ENVIRONMENT">, gateLanded = PRODUCTION_PLAN_GATE_LANDED): string | null =>
  env.ENVIRONMENT === "production" && !gateLanded ? "team_vm.plan_gate_missing" : null

/** The configured driver, or null: without a key, a snapshot and a slug prefix (cmuxnp-dev- outside production) nothing is created. */
export const teamVmDriver = (env: Env, sql: SqlStore): TeamVmDriver | null => {
  if (env.ENVIRONMENT === "test" && env.TEAM_VM_DRIVER === "fake") return new FakeDriver(sql)
  if (!env.FREESTYLE_API_KEY || !env.TEAM_VM_SNAPSHOT || !env.TEAM_VM_SLUG_PREFIX) return null
  // Development and staging share the production provider account: their VMs must carry the
  // prefix that marks agent-created resources, so nothing can mistake them for customer VMs.
  if (env.ENVIRONMENT !== "production" && !env.TEAM_VM_SLUG_PREFIX.startsWith("cmuxnp-dev-")) return null
  return new FreestyleDriver(env.FREESTYLE_API_KEY, env.FREESTYLE_API_URL || "https://api.freestyle.sh", env.TEAM_VM_SNAPSHOT)
}
