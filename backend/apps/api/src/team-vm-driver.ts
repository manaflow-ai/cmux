import type { SqlStore } from "@cmux/ownership"
import type { Env } from "./env.ts"
import type { ProviderState } from "./domains/team-vm.ts"
import { FakeGuest } from "./team-vm-fake-guest.ts"
import { FakeFiles, FreestyleFiles } from "./team-vm-driver-files.ts"

/**
 * The provider behind TeamVmDO (plans/cmux-next/team-vm-plan.md S2). Two calls, both idempotent:
 * `ensureVm` creates the VM under a slug that is unique in the provider account (a retry after an
 * unknown outcome finds the VM by slug instead of creating a second one), and `ensureRunning`
 * starts a paused VM and reports the observed state.
 */
export interface TeamVmDriver {
  ensureVm(slug: string, team: string, epoch: number): Promise<{ readonly id: string; readonly state: ProviderState }>
  ensureRunning(id: string): Promise<{ readonly state: ProviderState }>
  /** Reads the VM with this EXACT name (slug): its id and team tag, or null when the provider has none. Never lists. */
  lookup(name: string): Promise<{ readonly id: string; readonly team: string | null } | null>
  /** Deletes the VM with this provider id; a VM already gone counts as deleted. Callers pass ledger ids only. */
  deleteVm(id: string): Promise<void>
  /**
   * Retires the VM with this provider id: spends its lifetime run budget, then pauses it (memory
   * and disk kept; a VM already paused counts as paused). The provider resumes a paused VM on any
   * inbound traffic (public IPv6, VPC peers, tunnels, its SSH proxy; measured cx-009a); a spent
   * budget makes it refuse every later start, those wakes and exec included, while the files stay
   * readable and the VM can still be deleted. Nothing in cmux raises the budget again.
   */
  retireVm(id: string): Promise<void>
  /**
   * Runs one command on this exact VM through the provider API (authenticated by our provider key,
   * which the guest never sees) and returns its exit code and output. Used only by the bind
   * (vm-image.md 6b): the channel itself proves which machine answers.
   */
  exec(id: string, command: string, timeoutMs: number): Promise<{ readonly code: number; readonly stdout: string }>
  /** One page of the provider account's VMs (report-only callers; never used to adopt or delete). */
  listPage(limit: number, offset: number): Promise<{ readonly vms: ReadonlyArray<{ readonly id: string; readonly slug: string | null }>; readonly size: number; readonly total: number | null }>
  /**
   * The provider's file API on the VM's disk (team-vm-export.ts). It reads a paused VM without
   * starting it, also one whose run budget is spent (measured cx-009a). Never used on a running VM.
   */
  readonly files: TeamVmFiles
}

export type FsKind = "file" | "directory" | "symlink" | "other"
export interface FsStat {
  readonly kind: FsKind
  readonly size: number
  /** Permission bits. */
  readonly mode: number
  /** Seconds since the epoch, 0 when unknown. */
  readonly mtime: number
  readonly owner: string
  readonly group: string
}

export interface TeamVmFiles {
  /** The entries of directory `path`, or null when the path does not exist (the VM itself missing is `team_vm.vm_missing`). */
  list(id: string, path: string): Promise<ReadonlyArray<{ readonly name: string; readonly kind: FsKind }> | null>
  /** Metadata of `path` without following a symlink's target, or null when the path does not exist. */
  stat(id: string, path: string): Promise<FsStat | null>
  /** The bytes of file `path` from byte `offset` on, as the provider streams them. */
  read(id: string, path: string, offset: number, signal: AbortSignal): Promise<ReadableStream<Uint8Array>>
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
/** A retired VM's lifetime run budget: below the time it has already run, so the provider refuses every start. */
const RETIRED_RUN_BUDGET_SECONDS = 1
const nonEmpty = (v: unknown): v is string => typeof v === "string" && v.length > 0

export class FreestyleDriver implements TeamVmDriver {
  readonly files: FreestyleFiles
  constructor(
    private readonly apiKey: string,
    private readonly baseUrl: string,
    private readonly snapshot: string
  ) {
    this.files = new FreestyleFiles(apiKey, baseUrl)
  }

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

  async lookup(name: string) {
    const got = await this.call("GET", `/v5/vms/${encodeURIComponent(name)}`)
    if (got.status === 404) return null
    if (got.status !== 200 || !nonEmpty(got.json.id)) this.fail(got.status, got.json, "read VM by name")
    const tag = (got.json.metadata ?? {}) as Record<string, unknown>
    return { id: got.json.id, team: typeof tag.cmux_team === "string" ? tag.cmux_team : null }
  }

  async deleteVm(id: string) {
    const gone = await this.call("DELETE", `/v5/vms/${encodeURIComponent(id)}`)
    if (gone.status === 404 || (gone.status >= 200 && gone.status < 300)) return
    this.fail(gone.status, gone.json, "delete VM")
  }

  async retireVm(id: string) {
    // First the budget (1 s is always spent: the VM has run at least that long), so no packet that
    // arrives between the pause and a later call can run it again. On a running VM the budget alone
    // pauses it within about a second; the pause below then confirms the state.
    const capped = await this.call("PATCH", `/v5/vms/${encodeURIComponent(id)}`, { maxRunTotalSeconds: RETIRED_RUN_BUDGET_SECONDS })
    if (capped.status === 404) throw new DriverError("team_vm.vm_missing", "retire VM: 404", true)
    if (capped.status < 200 || capped.status >= 300) this.fail(capped.status, capped.json, "retire VM")
    const r = await this.call("POST", `/v5/vms/${encodeURIComponent(id)}/pause`)
    if (r.status >= 200 && r.status < 300) return
    // A VM that is already paused (or stopped) may refuse the call; that is the state asked for.
    const got = await this.call("GET", `/v5/vms/${encodeURIComponent(id)}`)
    if (got.status === 200 && (got.json.state === "paused" || got.json.state === "stopped")) return
    this.fail(r.status, r.json, "pause VM")
  }

  /** POST /v5/vms/{id}/exec-await {command, timeoutMs, linuxUser} answers {statusCode, stdout, stderr} (as the web resource reader uses it). */
  async exec(id: string, command: string, timeoutMs: number) {
    // As root: the bind writes root-only state (/var/lib/cmux); the provider's default exec user is the work user.
    const r = await this.call("POST", `/v5/vms/${encodeURIComponent(id)}/exec-await`, { command, timeoutMs, linuxUser: "root" }, timeoutMs + 5_000)
    if (r.status === 404) throw new DriverError("team_vm.vm_missing", "exec: 404", true)
    if (r.status !== 200) this.fail(r.status, r.json, "exec")
    const code = typeof r.json.statusCode === "number" ? r.json.statusCode : -1
    // Only the last line is read (the proof); a large output is cut to its end.
    return { code, stdout: typeof r.json.stdout === "string" ? r.json.stdout.slice(-16_384) : "" }
  }

  /** GET /v5/vms?limit&offset answers { vms: VmData[], totalCount } (freestyle SDK 0.2.16, ListVmsOptions / ListVmsResult). */
  async listPage(limit: number, offset: number) {
    const got = await this.call("GET", `/v5/vms?limit=${limit}&offset=${offset}`)
    if (got.status !== 200 || !Array.isArray(got.json.vms)) this.fail(got.status, got.json, "list VMs")
    const raw = got.json.vms as Array<Record<string, unknown>>
    const vms = raw.filter((v) => nonEmpty(v.id)).map((v) => ({ id: v.id as string, slug: typeof v.slug === "string" ? v.slug : null }))
    // `size` is the raw page length (paging stops on a short page); a missing totalCount is unknown.
    return { vms, size: raw.length, total: typeof got.json.totalCount === "number" ? got.json.totalCount : null }
  }
}

/**
 * Test driver (ENVIRONMENT=test only): VMs live in the DO's own SQLite, so tests see exactly what
 * the object did. `fake_ctl.fail_next` makes the next calls fail (retryable) to test backoff; `lose_next_create`
 * makes the next create happen but answer with a retryable failure (a lost answer); deleting a `fake_vm` row stands for a VM deleted outside cmux.
 */
export class FakeDriver implements TeamVmDriver {
  private readonly guest: FakeGuest
  readonly files: FakeFiles
  constructor(private readonly sql: SqlStore) {
    this.guest = new FakeGuest(sql)
    this.files = new FakeFiles(sql)
    sql.exec(`CREATE TABLE IF NOT EXISTS fake_vm (slug TEXT PRIMARY KEY, id TEXT NOT NULL UNIQUE, state TEXT NOT NULL, team TEXT)`)
    sql.exec(`CREATE TABLE IF NOT EXISTS fake_ctl (id INTEGER PRIMARY KEY CHECK (id = 1), fail_next INTEGER NOT NULL DEFAULT 0, creates INTEGER NOT NULL DEFAULT 0, starts INTEGER NOT NULL DEFAULT 0, slug_prefix TEXT, lose_next_create INTEGER NOT NULL DEFAULT 0)`)
    sql.exec(`INSERT OR IGNORE INTO fake_ctl (id) VALUES (1)`)
  }

  private maybeFail() {
    const n = this.sql.exec<{ fail_next: number }>(`SELECT fail_next FROM fake_ctl WHERE id = 1`)[0]!.fail_next
    if (n > 0) {
      this.sql.exec(`UPDATE fake_ctl SET fail_next = fail_next - 1 WHERE id = 1`)
      throw new DriverError("team_vm.provider_failed", "fake provider failure", false)
    }
  }

  /** Test only: the slug prefix a test set to stand for a configuration change (null = the env's). */
  slugPrefix(): string | null {
    return this.sql.exec<{ slug_prefix: string | null }>(`SELECT slug_prefix FROM fake_ctl WHERE id = 1`)[0]?.slug_prefix ?? null
  }

  async ensureVm(slug: string, team: string, _epoch: number) {
    this.maybeFail()
    const row = this.sql.exec<{ id: string; state: string }>(`SELECT id, state FROM fake_vm WHERE slug = ?`, slug)[0]
    if (row) return { id: row.id, state: asState(row.state) }
    const id = `fakevm-${slug}`
    this.sql.exec(`INSERT INTO fake_vm (slug, id, state, team) VALUES (?, ?, 'running', ?)`, slug, id, team)
    this.sql.exec(`UPDATE fake_ctl SET creates = creates + 1 WHERE id = 1`)
    if (this.sql.exec<{ n: number }>(`SELECT lose_next_create AS n FROM fake_ctl WHERE id = 1`)[0]!.n > 0) {
      this.sql.exec(`UPDATE fake_ctl SET lose_next_create = lose_next_create - 1 WHERE id = 1`)
      throw new DriverError("team_vm.provider_failed", "create VM: no answer TIMEOUT", false)
    }
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

  async lookup(name: string) {
    this.maybeFail()
    const row = this.sql.exec<{ id: string; team: string | null }>(`SELECT id, team FROM fake_vm WHERE slug = ?`, name)[0]
    return row ? { id: row.id, team: row.team } : null
  }

  async deleteVm(id: string) {
    this.maybeFail()
    this.sql.exec(`DELETE FROM fake_vm WHERE id = ?`, id)
  }

  async retireVm(id: string) {
    this.maybeFail()
    this.sql.exec(`CREATE TABLE IF NOT EXISTS fake_pause_ctl (id INTEGER PRIMARY KEY CHECK (id = 1), fail INTEGER NOT NULL)`)
    if ((this.sql.exec<{ fail: number }>(`SELECT fail FROM fake_pause_ctl WHERE id = 1`)[0]?.fail ?? 0) > 0) {
      this.sql.exec(`UPDATE fake_pause_ctl SET fail = fail - 1 WHERE id = 1`)
      throw new DriverError("team_vm.provider_failed", "fake pause failure", false)
    }
    if (!this.sql.exec<{ id: string }>(`SELECT id FROM fake_vm WHERE id = ?`, id)[0]) throw new DriverError("team_vm.vm_missing", "retire VM: 404", true)
    this.sql.exec(`CREATE TABLE IF NOT EXISTS fake_fence (id TEXT PRIMARY KEY)`)
    this.sql.exec(`INSERT OR IGNORE INTO fake_fence (id) VALUES (?)`, id)
    this.sql.exec(`UPDATE fake_vm SET state = 'paused' WHERE id = ?`, id)
  }

  /**
   * Test only: one inbound connection to `id` as the provider handles it (measured cx-009a):
   * traffic resumes a paused VM unless its run budget is spent (`fake_fence`).
   */
  inbound(id: string): void {
    this.sql.exec(`CREATE TABLE IF NOT EXISTS fake_fence (id TEXT PRIMARY KEY)`)
    if (this.sql.exec<{ id: string }>(`SELECT id FROM fake_fence WHERE id = ?`, id)[0]) return
    this.sql.exec(`UPDATE fake_vm SET state = 'running' WHERE id = ? AND state = 'paused'`, id)
  }

  async exec(id: string, command: string, _timeoutMs: number) {
    if (!this.sql.exec<{ id: string }>(`SELECT id FROM fake_vm WHERE id = ?`, id)[0]) throw new DriverError("team_vm.vm_missing", "exec: 404", true)
    return this.guest.run(id, command)
  }

  async listPage(limit: number, offset: number) {
    this.maybeFail()
    const vms = this.sql.exec<{ id: string; slug: string }>(`SELECT id, slug FROM fake_vm ORDER BY slug LIMIT ? OFFSET ?`, limit, offset)
    const total = this.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM fake_vm`)[0]!.n
    return { vms, size: vms.length, total }
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

/**
 * The prefix a non-production environment's new team VM names must start with (decision
 * FREESTYLE-NAMES: `cmuxnp-<env>-<lane>-<rest>`): staging `cmuxnp-stg-`, everything else `cmuxnp-dev-`.
 * The prefix only names NEW VMs. Nothing lists provider VMs or matches them by prefix: a team's VM
 * is reached by the id in its TeamVmDO record, so a VM created under an older prefix keeps working.
 */
export const requiredSlugPrefix = (environment: string | undefined) => (environment === "staging" ? "cmuxnp-stg-" : "cmuxnp-dev-")

/** The configured driver, or null: without a key, a snapshot and a slug prefix (requiredSlugPrefix outside production) nothing is created. */
export const teamVmDriver = (env: Env, sql: SqlStore): TeamVmDriver | null => {
  if (env.ENVIRONMENT === "test" && env.TEAM_VM_DRIVER === "fake") return new FakeDriver(sql)
  if (!env.FREESTYLE_API_KEY || !env.TEAM_VM_SNAPSHOT || !env.TEAM_VM_SLUG_PREFIX) return null
  // Development and staging share the production provider account: their VMs must carry the
  // prefix that marks agent-created resources of that environment, so nothing can mistake them for customer VMs.
  if (env.ENVIRONMENT !== "production" && !env.TEAM_VM_SLUG_PREFIX.startsWith(requiredSlugPrefix(env.ENVIRONMENT))) return null
  return new FreestyleDriver(env.FREESTYLE_API_KEY, env.FREESTYLE_API_URL || "https://api.freestyle.sh", env.TEAM_VM_SNAPSHOT)
}
