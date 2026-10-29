import type { SqlStore } from "@cmux/ownership"
import type { Env } from "./env.ts"
import { asState, type ProviderState } from "./domains/team-vm.ts"
import { DriverError } from "./providers/contract.ts"
import { FakeGuest } from "./team-vm-fake-guest.ts"
import { FakeFiles } from "./team-vm-driver-files.ts"
import { directTeamVmProvider } from "./providers/index.ts"

/**
 * The provider behind TeamVmDO (plans/cmux-next/team-vm-plan.md S2). Two calls, both idempotent:
 * `ensureVm` creates the VM under a slug that is unique in the provider account (a retry after an
 * unknown outcome finds the VM by slug instead of creating a second one), and `ensureRunning`
 * starts a paused VM and reports the observed state.
 */
export interface TeamVmDriver {
  /** Test-only prefix override remains available through an owner router. */
  slugPrefix?(): string | null
  /** API transports verify the signed real instance against the allocation's canonical fingerprint. */
  instanceMatches?(id: string, signedInstance: string): Promise<boolean>
  ensureVm(slug: string, team: string, epoch: number): Promise<{ readonly id: string; readonly state: ProviderState }>
  ensureRunning(id: string): Promise<{ readonly state: ProviderState }>
  /** Reads the VM with this EXACT name (slug): its id and team tag, or null when the provider has none. Never lists. */
  lookup(name: string): Promise<{ readonly id: string; readonly team: string | null } | null>
  /** Deletes the VM with this provider id; a VM already gone counts as deleted. Callers pass ledger ids only. */
  deleteVm(id: string): Promise<void>
  /**
   * Retires the VM with this provider id: syncs a running guest's disk (best effort, bounded), spends its lifetime run budget, then pauses it (memory
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

export { DriverError } from "./providers/contract.ts"

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
 * started, even if the provider key is set by mistake. The S2b slice sets this to true together
 * with the gate and its tests (plans/cmux-next/team-vm-plan.md 3a).
 */
export const PRODUCTION_PLAN_GATE_LANDED = false

/** The refusal code when this deployment must not call the provider yet, else null. */
export const providerRefusal = (env: Pick<Env, "ENVIRONMENT">, gateLanded = PRODUCTION_PLAN_GATE_LANDED): string | null =>
  env.ENVIRONMENT === "production" && !gateLanded ? "team_vm.plan_gate_missing" : null

/**
 * The prefix a non-production environment's new team VM names must start with (the naming decision
 * in plans/cmux-next/team-vm-plan.md: `cmuxnp-<env>-<lane>-<rest>`): staging `cmuxnp-stg-`, everything else `cmuxnp-dev-`.
 * The prefix only names NEW VMs. Nothing lists provider VMs or matches them by prefix: a team's VM
 * is reached by the id in its TeamVmDO record, so a VM created under an older prefix keeps working.
 */
export const requiredSlugPrefix = (environment: string | undefined) => (environment === "staging" ? "cmuxnp-stg-" : "cmuxnp-dev-")

/** The configured driver, or null: without a key, a snapshot and a slug prefix (requiredSlugPrefix outside production) nothing is created. */
export const teamVmDriver = (env: Env, sql: SqlStore): TeamVmDriver | null => {
  if (env.ENVIRONMENT === "test" && env.TEAM_VM_DRIVER === "fake") return new FakeDriver(sql)
  const provider = directTeamVmProvider(env)
  if (!provider.keySet(env) || !env.TEAM_VM_SNAPSHOT || !env.TEAM_VM_SLUG_PREFIX) return null
  // Development and staging share the production provider account: their VMs must carry the
  // prefix that marks agent-created resources of that environment, so nothing can mistake them for customer VMs.
  if (env.ENVIRONMENT !== "production" && !env.TEAM_VM_SLUG_PREFIX.startsWith(requiredSlugPrefix(env.ENVIRONMENT))) return null
  return provider.make(env, env.TEAM_VM_SNAPSHOT)
}
