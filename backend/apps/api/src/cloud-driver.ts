import type { SqlStore } from "@cmux/ownership"
import type { Env } from "./env.ts"
import { DriverError } from "./team-vm-driver.ts"
import type { CloudConfig } from "./domains/cloud-plan.ts"
import { parseAllowedTeams } from "./domains/cloud-plan.ts"
export { providerName } from "./domains/cloud-plan.ts"

/**
 * The provider behind CloudDO (state-placement.md 5.2, 5.3). The Freestyle account is shared with
 * classic cmux Cloud, so every call goes through GuardedCloudDriver: it refuses a name without this
 * environment's prefix before any request, and never adopts or deletes a VM under our name whose
 * tag names another team or machine. Creates and deletes are idempotent by name: a create first
 * looks the name up (a lost create answer is found, never made twice), and a delete of a name that
 * is not there is success.
 */
export interface VmTag {
  readonly team: string
  readonly machine: string
}

/** One raw provider: `find` by name (null = none), `create` under a name, `delete` by provider id (404 = success). */
export interface RawCloudDriver {
  find(name: string): Promise<{ readonly id: string; readonly tag: Record<string, unknown> } | null>
  /** `tag` null: this call made the VM; else the VM already under the name (checked by the guard). */
  create(name: string, tag: VmTag, opts: CreateOptions): Promise<{ readonly id: string; readonly tag: Record<string, unknown> | null }>
  delete(id: string): Promise<void>
  /** Pause (memory kept) or start a VM (Freestyle `POST /v5/vms/{id}/pause` and `/start`). */
  pause(id: string): Promise<void>
  start(id: string): Promise<void>
  /** The VM's provider state (Freestyle VmState: starting, running, pausing, paused, stopped), or null when it is gone. */
  state(id: string): Promise<string | null>
  /** Grow a VM (Freestyle `POST /v5/vms/{id}/resize`: grow only; memory in MiB, storage in MiB). */
  resize(id: string, size: VmResources): Promise<void>
  /** The VM's resources (Freestyle `resources {cpu, memory, storage}`), or null when it is gone. */
  resources(id: string): Promise<VmResources | null>
  /** Writes one small file into the VM (atomic, verified by sha256; Freestyle `PUT /v5/vms/{id}/fs/write`). */
  writeFile(id: string, path: string, content: string, mode: number): Promise<void>
  /** One page (100) of VMs whose metadata has `filter` (`key:value`). Used only to report, never to delete. */
  list(filter: string, offset: number): Promise<{ readonly vms: ReadonlyArray<ListedVm>; readonly total: number }>
}

export interface VmResources {
  readonly cpu: number
  readonly memory: number
  readonly storage: number
}

export interface CreateOptions {
  /** The machine's idle policy in seconds; 0 = never pause. */
  readonly idleSeconds: number
}

export interface ListedVm {
  readonly id: string
  readonly name: string | null
  readonly tag: Record<string, unknown>
}

/**
 * FREESTYLE-NAMES: provider names are cmuxnp-<env>-<lane>-<rest>; CloudDO's lane is `cld` (tvm = team
 * VMs, vmimg = image bakes; no lane owns the bare env prefix). A configured prefix that differs from
 * this environment's disables the provider.
 */
/** The short environment tag in names, the link token's iss and the bind file (dev, stg, prod; test in tests). */
export const cloudEnvTag = (environment: string | undefined): string | null =>
  ({ development: "dev", staging: "stg", production: "prod", test: "test" } as Record<string, string>)[environment ?? ""] ?? null

/**
 * The API origin the VM's bind agent calls, from CLOUD_API_ORIGIN: https only, no path. The image
 * also refuses an origin that is not on its per-environment allowlist (a9's bind-file contract).
 */
export const cloudApiOrigin = (env: { CLOUD_API_ORIGIN?: string }): string | null => {
  const raw = env.CLOUD_API_ORIGIN?.trim()
  if (!raw) return null
  try {
    const u = new URL(raw)
    return u.protocol === "https:" && (u.pathname === "/" || u.pathname === "") && !u.search && !u.hash && !u.username && !u.password ? u.origin : null
  } catch {
    return null
  }
}

export const ENV_PREFIX: Readonly<Record<string, string>> = { development: "cmuxnp-dev-cld-", staging: "cmuxnp-stg-cld-", production: "cmuxnp-prod-cld-", test: "cmuxnp-test-cld-" }
/** The image lane's snapshot prefix per environment (CLOUD-DEV-SNAPSHOT): not the machine prefix. */
export const ENV_IMAGE_PREFIX: Readonly<Record<string, string>> = { development: "cmuxnp-dev-vmimg-", staging: "cmuxnp-stg-vmimg-", production: "cmuxnp-prod-vmimg-", test: "cmuxnp-test-vmimg-" }

const LANE_PREFIX = /^cmuxnp-(dev|stg|prod|test)-cld-$/
/** The exact tail after the prefix: providerName of a machine id (vm_ + 20) with `_` as `-`. */
const NAME_TAIL = /^vm-[a-z0-9]{20}$/
const ours = (tag: Record<string, unknown>, want: VmTag) => tag.cmux_next_team === want.team && tag.cmux_next_machine === want.machine

export class GuardedCloudDriver {
  constructor(
    private readonly raw: RawCloudDriver,
    private readonly prefix: string
  ) {
    if (!LANE_PREFIX.test(prefix)) throw new Error("the Cloud driver needs a cmuxnp-<env>-cld- prefix")
  }

  private guard(name: string): void {
    if (!name.startsWith(this.prefix) || !NAME_TAIL.test(name.slice(this.prefix.length))) {
      throw new DriverError("cloud.provider.refused", "refused: the resource name does not carry this environment's prefix", true)
    }
  }

  /** The VM under `name`, created if missing. */
  async ensure(name: string, tag: VmTag, opts: CreateOptions): Promise<{ id: string }> {
    this.guard(name)
    const found = await this.raw.find(name)
    if (found) {
      if (!ours(found.tag, tag)) throw new DriverError("cloud.provider.name_conflict", "the name belongs to another VM", true)
      return { id: found.id }
    }
    const created = await this.raw.create(name, tag, opts)
    if (created.tag !== null && !ours(created.tag, tag)) throw new DriverError("cloud.provider.name_conflict", "the name belongs to another VM", true)
    return { id: created.id }
  }

  /**
   * 5.8 item 1: writes the bind file into our VM (found by its recorded name, metadata checked).
   * Freestyle has no create-time file option, so this is a second call right after the create; a
   * retry overwrites it with a fresh token.
   */
  async writeBindFile(name: string, tag: VmTag, content: string): Promise<void> {
    this.guard(name)
    const found = await this.raw.find(name)
    if (!found) throw new DriverError("cloud.provider.unavailable", "write bind file: the VM is not there yet", false)
    if (!ours(found.tag, tag)) throw new DriverError("cloud.provider.name_conflict", "the name belongs to another VM", true)
    await this.raw.writeFile(found.id, BIND_FILE_PATH, content, 0o600)
  }

  /** P1-2: the VM a cancelled create may have made, found by its recorded name; never creates. */
  async findOwned(name: string, tag: VmTag): Promise<{ id: string } | null> {
    this.guard(name)
    const found = await this.raw.find(name)
    if (!found) return null
    if (!ours(found.tag, tag)) throw new DriverError("cloud.provider.name_conflict", "the name belongs to another VM", true)
    return { id: found.id }
  }

  /** The VM under one of our recorded names, with its metadata, for the late-VM lookup and the report. Never creates or deletes. */
  async peek(name: string): Promise<{ id: string; tag: Record<string, unknown> } | null> {
    this.guard(name)
    return this.raw.find(name)
  }

  /**
   * Report only (the orphan report): this team's tagged VMs under this environment's cld prefix and
   * exact name shape. There is deliberately no delete that takes a listed VM.
   */
  async listOurs(team: string, maxPages = 10): Promise<Array<{ name: string; id: string }>> {
    const out: Array<{ name: string; id: string }> = []
    for (let page = 0, offset = 0; page < maxPages; page++) {
      const { vms, total } = await this.raw.list(`cmux_next_team:${team}`, offset)
      for (const v of vms) if (v.name && v.name.startsWith(this.prefix) && NAME_TAIL.test(v.name.slice(this.prefix.length)) && v.tag.cmux_next_team === team) out.push({ name: v.name, id: v.id })
      offset += vms.length
      if (vms.length === 0 || offset >= total) break
    }
    return out
  }

  /** Pauses or starts our VM under `name` (metadata checked); a missing VM fails final. */
  async power(name: string, tag: VmTag, action: "pause" | "start"): Promise<void> {
    this.guard(name)
    const found = await this.raw.find(name)
    if (!found) throw new DriverError("cloud.provider.vm_missing", `${action} VM: no VM under the recorded name`, true)
    if (!ours(found.tag, tag)) throw new DriverError("cloud.provider.name_conflict", "the name belongs to another VM", true)
    // Settle from the VM's real state (review P2): a VM already there (or on its way) is success, before
    // the call (a retry after a lost answer) and after a failed one (Freestyle answers 409 when already there).
    // A pause counts only when paused (a failed "pausing" would free the slot of a running VM); a start may count when starting (the slot is taken either way).
    const reached = (st: string | null) => (action === "pause" ? st === "paused" : st === "running" || st === "starting")
    if (reached(await this.raw.state(found.id))) return
    try {
      await (action === "pause" ? this.raw.pause(found.id) : this.raw.start(found.id))
    } catch (e) {
      if (reached(await this.raw.state(found.id).catch(() => null))) return
      throw e
    }
  }

  /** Grows our VM under `name` to `size`; settles from its real resources before and after the call (a lost answer). */
  async resize(name: string, tag: VmTag, size: VmResources): Promise<void> {
    this.guard(name)
    const found = await this.raw.find(name)
    if (!found) throw new DriverError("cloud.provider.vm_missing", "resize VM: no VM under the recorded name", true)
    if (!ours(found.tag, tag)) throw new DriverError("cloud.provider.name_conflict", "the name belongs to another VM", true)
    const reached = (r: VmResources | null) => !!r && r.cpu >= size.cpu && r.memory >= size.memory && r.storage >= size.storage
    if (reached(await this.raw.resources(found.id))) return
    try {
      await this.raw.resize(found.id, size)
    } catch (e) {
      if (reached(await this.raw.resources(found.id).catch(() => null))) return
      throw e
    }
  }

  /** The real resources of our VM under `name` (the record follows them: Freestyle has no size at create). */
  async resourcesOf(name: string, tag: VmTag): Promise<VmResources | null> {
    this.guard(name)
    const found = await this.raw.find(name)
    if (!found || !ours(found.tag, tag)) return null
    return this.raw.resources(found.id)
  }

  /** Deletes the VM under `name`; no VM there is success. */
  async remove(name: string, tag: VmTag): Promise<void> {
    this.guard(name)
    const found = await this.raw.find(name)
    if (!found) return
    if (!ours(found.tag, tag)) throw new DriverError("cloud.provider.name_conflict", "the name belongs to another VM", true)
    await this.raw.delete(found.id)
  }
}

/** Where the image's bind agent reads {team, machine, bind_token} (decision for the image lane: path and mode 0600). */
export const BIND_FILE_PATH = "/var/lib/cmux/bind.json"

const REQUEST_TIMEOUT_MS = 20_000
const CREATE_TIMEOUT_MS = 120_000
const LIST_PAGE = 100

/**
 * The create body (Freestyle SDK 0.2.10 CreateVmOptions, web/services/vms/drivers/freestyle.ts):
 * - idleTimeoutSeconds: the machine's idle policy; our 0 (never pause) is Freestyle's -1.
 * - autoDeleteSeconds -1: a user machine is persistent, never deleted for not running (on a plan
 *   that caps it, -1 gets the cap). automaticRestart stays at its default, true.
 * - firewall: a VM gets nothing implicitly; this allows egress to every publicly routable address.
 *   `public: true` selects by address, so it does not cover private or VPC addresses. The machine
 *   joins no VPC at create (no `vpcs`), so no VPC rule is needed now; the VPC attach work (lane 12)
 *   adds a `{ vpcId }` rule with the attach.
 * - size: create takes no resources (the snapshot decides; resize is a separate, grow-only call),
 *   so the plan checks cpu, memory and disk but the size is not sent yet.
 */
export const createBody = (name: string, snapshot: string, tag: VmTag, opts: CreateOptions) => ({
  slug: name,
  snapshotId: snapshot,
  idleTimeoutSeconds: opts.idleSeconds === 0 ? -1 : opts.idleSeconds,
  autoDeleteSeconds: -1,
  metadata: { cmux_next_team: tag.team, cmux_next_machine: tag.machine },
  firewall: { rules: [{ action: "allow", source: {}, destination: { public: true } }] }
})

/** Freestyle REST (the same v5 calls TeamVmDO's driver measured). Errors carry only the step, status and provider code. */
export class FreestyleCloudDriver implements RawCloudDriver {
  constructor(
    private readonly apiKey: string,
    private readonly baseUrl: string,
    private readonly snapshot: string,
    private readonly fetchFn: typeof fetch = fetch
  ) {}

  private async call(method: string, path: string, body?: unknown, timeoutMs = REQUEST_TIMEOUT_MS): Promise<{ status: number; json: Record<string, unknown> }> {
    try {
      const res = await this.fetchFn(`${this.baseUrl.replace(/\/+$/, "")}${path}`, {
        method,
        headers: { authorization: `Bearer ${this.apiKey}`, ...(body === undefined ? {} : { "content-type": "application/json" }) },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
        signal: AbortSignal.timeout(timeoutMs)
      })
      return { status: res.status, json: (await res.json().catch(() => ({}))) as Record<string, unknown> }
    } catch (e) {
      // Network failure or timeout: the outcome is unknown; the retry finds the VM by name.
      return { status: 0, json: { code: e instanceof Error && e.name === "TimeoutError" ? "TIMEOUT" : "UNREACHABLE" } }
    }
  }

  private fail(status: number, json: Record<string, unknown>, what: string): never {
    const final = status === 400 || status === 401 || status === 403 || status === 422
    const code = typeof json.code === "string" ? json.code.slice(0, 40) : ""
    throw new DriverError(final ? "cloud.provider.refused" : "cloud.provider.unavailable", `${what}: ${status || "no answer"}${code ? ` ${code}` : ""}`, final)
  }

  private vm(json: Record<string, unknown>) {
    if (typeof json.id !== "string" || json.id.length === 0) throw new DriverError("cloud.provider.refused", "answer without a VM id", true)
    return { id: json.id, tag: (json.metadata ?? {}) as Record<string, unknown> }
  }

  async find(name: string) {
    const got = await this.call("GET", `/v5/vms/${encodeURIComponent(name)}`)
    if (got.status === 404) return null
    if (got.status !== 200) this.fail(got.status, got.json, "read VM")
    return this.vm(got.json)
  }

  async create(name: string, tag: VmTag, opts: CreateOptions) {
    const created = await this.call("POST", "/v5/vms", createBody(name, this.snapshot, tag, opts), CREATE_TIMEOUT_MS)
    if (created.status >= 200 && created.status < 300) return { id: this.vm(created.json).id, tag: null }
    // A duplicate name (409) or an unknown outcome: the VM under the name, if any, is the answer.
    const found = await this.find(name)
    if (found) return found
    this.fail(created.status, created.json, "create VM")
  }

  async writeFile(id: string, path: string, content: string, mode: number) {
    const bytes = new TextEncoder().encode(content)
    const digest = [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))].map((b) => b.toString(16).padStart(2, "0")).join("")
    const q = new URLSearchParams({ path, mode: String(mode), sha256: digest })
    let status = 0
    try {
      const res = await this.fetchFn(`${this.baseUrl.replace(/\/+$/, "")}/v5/vms/${encodeURIComponent(id)}/fs/write?${q}`, {
        method: "PUT",
        headers: { authorization: `Bearer ${this.apiKey}`, "content-type": "application/octet-stream" },
        body: bytes,
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS)
      })
      status = res.status
      await res.body?.cancel()
    } catch {
      status = 0
    }
    // Never echo the body (it holds the bind token): only the step and status.
    if (status < 200 || status >= 300) this.fail(status, {}, "write bind file")
  }

  async list(filter: string, offset: number) {
    const q = new URLSearchParams({ metadata: filter, limit: String(LIST_PAGE), offset: String(offset) })
    const got = await this.call("GET", `/v5/vms?${q}`)
    if (got.status !== 200) this.fail(got.status, got.json, "list VMs")
    const vms = (Array.isArray(got.json.vms) ? got.json.vms : []) as Array<Record<string, unknown>>
    return {
      vms: vms.filter((v) => typeof v.id === "string").map((v) => ({ id: v.id as string, name: typeof v.slug === "string" ? v.slug : null, tag: (v.metadata ?? {}) as Record<string, unknown> })),
      total: typeof got.json.totalCount === "number" ? got.json.totalCount : vms.length
    }
  }

  async delete(id: string) {
    const r = await this.call("DELETE", `/v5/vms/${encodeURIComponent(id)}`)
    if (r.status === 404 || (r.status >= 200 && r.status < 300)) return
    this.fail(r.status, r.json, "delete VM")
  }

  async pause(id: string) {
    const r = await this.call("POST", `/v5/vms/${encodeURIComponent(id)}/pause`)
    if (r.status >= 200 && r.status < 300) return
    this.fail(r.status, r.json, "pause VM")
  }

  async start(id: string) {
    const r = await this.call("POST", `/v5/vms/${encodeURIComponent(id)}/start`)
    if (r.status >= 200 && r.status < 300) return
    this.fail(r.status, r.json, "start VM")
  }

  async state(id: string) {
    const r = await this.call("GET", `/v5/vms/${encodeURIComponent(id)}`)
    if (r.status === 404) return null
    if (r.status !== 200) this.fail(r.status, r.json, "read VM state")
    return typeof r.json.state === "string" ? r.json.state : null
  }

  async resize(id: string, size: VmResources) {
    const r = await this.call("POST", `/v5/vms/${encodeURIComponent(id)}/resize`, { cpu: size.cpu, memory: size.memory, storage: size.storage })
    if (r.status >= 200 && r.status < 300) return
    this.fail(r.status, r.json, "resize VM")
  }

  async resources(id: string) {
    const r = await this.call("GET", `/v5/vms/${encodeURIComponent(id)}`)
    if (r.status === 404) return null
    if (r.status !== 200) this.fail(r.status, r.json, "read VM resources")
    const res = (r.json.resources ?? {}) as Record<string, unknown>
    return typeof res.cpu === "number" && typeof res.memory === "number" && typeof res.storage === "number" ? { cpu: res.cpu, memory: res.memory, storage: res.storage } : null
  }
}

/**
 * Test provider (ENVIRONMENT=test, CLOUD_DRIVER=fake): VMs in the object's own SQLite.
 * `fail_next` makes the next calls fail as retryable (a cut-off call).
 */
export class FakeCloudDriver implements RawCloudDriver {
  constructor(private readonly sql: SqlStore) {
    sql.exec(`CREATE TABLE IF NOT EXISTS cloud_fake_vm (name TEXT PRIMARY KEY, id TEXT NOT NULL UNIQUE, tag TEXT NOT NULL, idle INTEGER, state TEXT NOT NULL DEFAULT 'running', cpu INTEGER NOT NULL DEFAULT 2, memory INTEGER NOT NULL DEFAULT 4096, storage INTEGER NOT NULL DEFAULT 16384)`)
    sql.exec(`CREATE TABLE IF NOT EXISTS cloud_fake_ctl (id INTEGER PRIMARY KEY CHECK (id = 1), fail_next INTEGER NOT NULL DEFAULT 0, creates INTEGER NOT NULL DEFAULT 0, deletes INTEGER NOT NULL DEFAULT 0, fail_list INTEGER NOT NULL DEFAULT 0, pauses INTEGER NOT NULL DEFAULT 0, starts INTEGER NOT NULL DEFAULT 0, power_then_fail INTEGER NOT NULL DEFAULT 0, resizes INTEGER NOT NULL DEFAULT 0, resize_refuse INTEGER NOT NULL DEFAULT 0, resize_partial INTEGER NOT NULL DEFAULT 0, image_cpu INTEGER NOT NULL DEFAULT 2, image_memory INTEGER NOT NULL DEFAULT 4096, image_storage INTEGER NOT NULL DEFAULT 16384)`)
    sql.exec(`INSERT OR IGNORE INTO cloud_fake_ctl (id) VALUES (1)`)
    sql.exec(`CREATE TABLE IF NOT EXISTS cloud_fake_file (vm TEXT NOT NULL, path TEXT NOT NULL, content TEXT NOT NULL, mode INTEGER NOT NULL, PRIMARY KEY (vm, path))`)
  }

  private maybeFail() {
    const n = this.sql.exec<{ fail_next: number }>(`SELECT fail_next FROM cloud_fake_ctl WHERE id = 1`)[0]!.fail_next
    if (n > 0) {
      this.sql.exec(`UPDATE cloud_fake_ctl SET fail_next = fail_next - 1 WHERE id = 1`)
      throw new DriverError("cloud.provider.unavailable", "fake provider: no answer", false)
    }
  }

  async find(name: string) {
    this.maybeFail()
    const row = this.sql.exec<{ id: string; tag: string }>(`SELECT id, tag FROM cloud_fake_vm WHERE name = ?`, name)[0]
    return row ? { id: row.id, tag: JSON.parse(row.tag) as Record<string, unknown> } : null
  }

  async create(name: string, tag: VmTag, opts: CreateOptions) {
    this.maybeFail()
    const body = createBody(name, "fake", tag, opts)
    // The image decides the size (Freestyle has no size at create); image_size in fakeControl sets it.
    const img = this.sql.exec<{ image_cpu: number; image_memory: number; image_storage: number }>(`SELECT image_cpu, image_memory, image_storage FROM cloud_fake_ctl WHERE id = 1`)[0]!
    this.sql.exec(`INSERT INTO cloud_fake_vm (name, id, tag, idle, cpu, memory, storage) VALUES (?, ?, ?, ?, ?, ?, ?)`, name, `fs-${name}`, JSON.stringify(body.metadata), body.idleTimeoutSeconds, img.image_cpu, img.image_memory, img.image_storage)
    this.sql.exec(`UPDATE cloud_fake_ctl SET creates = creates + 1 WHERE id = 1`)
    return { id: `fs-${name}`, tag: null }
  }

  async writeFile(id: string, path: string, content: string, mode: number) {
    this.maybeFail()
    this.sql.exec(`INSERT INTO cloud_fake_file (vm, path, content, mode) VALUES (?, ?, ?, ?) ON CONFLICT (vm, path) DO UPDATE SET content = excluded.content, mode = excluded.mode`, id, path, content, mode)
  }

  /** Report-only path: never fails on purpose, so a background sweep cannot eat a test's fail_next. */
  async list(filter: string, offset: number) {
    if (this.sql.exec<{ fail_list: number }>(`SELECT fail_list FROM cloud_fake_ctl WHERE id = 1`)[0]!.fail_list) throw new DriverError("cloud.provider.unavailable", "fake provider: list failed", false)
    const [key, value] = [filter.slice(0, filter.indexOf(":")), filter.slice(filter.indexOf(":") + 1)]
    const all = this.sql.exec<{ name: string; id: string; tag: string }>(`SELECT name, id, tag FROM cloud_fake_vm ORDER BY name`)
    const vms = all.map((r) => ({ id: r.id, name: r.name, tag: JSON.parse(r.tag) as Record<string, unknown> })).filter((v) => v.tag[key] === value)
    return { vms: vms.slice(offset, offset + LIST_PAGE), total: vms.length }
  }

  async delete(id: string) {
    this.maybeFail()
    const gone = this.sql.exec<{ name: string }>(`DELETE FROM cloud_fake_vm WHERE id = ? RETURNING name`, id)
    if (gone.length) this.sql.exec(`UPDATE cloud_fake_ctl SET deletes = deletes + 1 WHERE id = 1`)
  }

  async pause(id: string) {
    this.power(id, "paused", "pauses")
  }

  async start(id: string) {
    this.power(id, "running", "starts")
  }

  /** Like Freestyle: 409 when the VM is already in that state; `power_then_fail` changes the VM, then answers 409 (a lost answer, then a retry). */
  private power(id: string, target: string, counter: "pauses" | "starts") {
    this.maybeFail()
    const vm = this.sql.exec<{ state: string }>(`SELECT state FROM cloud_fake_vm WHERE id = ?`, id)[0]
    if (!vm) throw new DriverError("cloud.provider.vm_missing", "fake provider: 404", true)
    if (vm.state === target) throw new DriverError("cloud.provider.conflict", "fake provider: 409 already in that state", true)
    this.sql.exec(`UPDATE cloud_fake_vm SET state = ? WHERE id = ?`, target, id)
    this.sql.exec(`UPDATE cloud_fake_ctl SET ${counter} = ${counter} + 1 WHERE id = 1`)
    const lost = Number(this.sql.exec<{ n: number }>(`SELECT power_then_fail AS n FROM cloud_fake_ctl WHERE id = 1`)[0]!.n)
    if (lost > 0) {
      this.sql.exec(`UPDATE cloud_fake_ctl SET power_then_fail = power_then_fail - 1 WHERE id = 1`)
      throw new DriverError("cloud.provider.conflict", "fake provider: 409 already in that state (after a lost answer)", true)
    }
  }

  async state(id: string) {
    return this.sql.exec<{ state: string }>(`SELECT state FROM cloud_fake_vm WHERE id = ?`, id)[0]?.state ?? null
  }

  /** Like Freestyle: grow only (400), the disk only on a running VM (409); `resize_refuse` refuses the next call (400, final). */
  async resize(id: string, size: VmResources) {
    this.maybeFail()
    const vm = this.sql.exec<{ state: string; cpu: number; memory: number; storage: number }>(`SELECT state, cpu, memory, storage FROM cloud_fake_vm WHERE id = ?`, id)[0]
    if (!vm) throw new DriverError("cloud.provider.vm_missing", "fake provider: 404", true)
    const refuse = Number(this.sql.exec<{ n: number }>(`SELECT resize_refuse AS n FROM cloud_fake_ctl WHERE id = 1`)[0]!.n)
    if (refuse > 0) {
      this.sql.exec(`UPDATE cloud_fake_ctl SET resize_refuse = resize_refuse - 1 WHERE id = 1`)
      throw new DriverError("cloud.provider.refused", "fake provider: 400 resize refused", true)
    }
    if (size.cpu < vm.cpu || size.memory < vm.memory || size.storage < vm.storage) throw new DriverError("cloud.provider.refused", "fake provider: 400 grow only", true)
    const partial = Number(this.sql.exec<{ n: number }>(`SELECT resize_partial AS n FROM cloud_fake_ctl WHERE id = 1`)[0]!.n)
    if (partial > 0) {
      this.sql.exec(`UPDATE cloud_fake_ctl SET resize_partial = resize_partial - 1 WHERE id = 1`)
      this.sql.exec(`UPDATE cloud_fake_vm SET cpu = ? WHERE id = ?`, size.cpu, id)
      throw new DriverError("cloud.provider.refused", "fake provider: 400 after growing vCPU only", true)
    }
    if (size.storage > vm.storage && vm.state !== "running") throw new DriverError("cloud.provider.conflict", "fake provider: 409 disk grows only on a running VM", true)
    this.sql.exec(`UPDATE cloud_fake_vm SET cpu = ?, memory = ?, storage = ? WHERE id = ?`, size.cpu, size.memory, size.storage, id)
    this.sql.exec(`UPDATE cloud_fake_ctl SET resizes = resizes + 1 WHERE id = 1`)
  }

  async resources(id: string) {
    const vm = this.sql.exec<{ cpu: number; memory: number; storage: number }>(`SELECT cpu, memory, storage FROM cloud_fake_vm WHERE id = ?`, id)[0]
    return vm ? { cpu: Number(vm.cpu), memory: Number(vm.memory), storage: Number(vm.storage) } : null
  }
}

/** The deployment's Cloud config: plan (stub outside production), name prefix (only with a usable provider) and image. */
export const cloudConfig = (env: Env): CloudConfig => {
  const want = ENV_PREFIX[env.ENVIRONMENT]
  const prefixOk = Boolean(want) && env.CLOUD_NAME_PREFIX === want
  const keyOk = fake(env) || Boolean(env.CLOUD_FREESTYLE_API_KEY)
  const snapshot = imageOf(env)
  const imagePrefix = ENV_IMAGE_PREFIX[env.ENVIRONMENT]
  // CLOUD-DEV-SNAPSHOT: only this environment's image lane snapshot (cmuxnp-<env>-vmimg-); no fallback.
  const imageProblem = !snapshot ? "missing" : imagePrefix && snapshot.startsWith(imagePrefix) ? undefined : "foreign"
  return {
    environment: env.ENVIRONMENT,
    allowedTeams: parseAllowedTeams(env.CLOUD_ALLOWED_TEAMS),
    prefix: prefixOk && keyOk ? env.CLOUD_NAME_PREFIX! : null,
    image: prefixOk && keyOk && !imageProblem ? snapshot! : null,
    ...(imageProblem ? { imageProblem } : {})
  }
}

const fake = (env: Env) => env.ENVIRONMENT === "test" && env.CLOUD_DRIVER === "fake"
/** The configured snapshot; the test fake boots a named test image lane snapshot unless a test sets one. */
const imageOf = (env: Env): string | undefined => env.CLOUD_FREESTYLE_SNAPSHOT || (fake(env) ? `${ENV_IMAGE_PREFIX.test}fake` : undefined)

/** A usable provider: this environment's exact prefix, a key (or the test fake) and this environment's snapshot. */
const cloudRawDriverReady = (env: Env): boolean => cloudConfig(env).image !== null

/** Whether this deployment has a usable provider (key or test fake, this environment's prefix, its image). */
export const cloudProviderReady = (env: Env): boolean => cloudRawDriverReady(env)

/** The guarded driver, or null when this deployment has no usable provider. */
export const cloudDriver = (env: Env, sql: SqlStore): GuardedCloudDriver | null => {
  if (!cloudRawDriverReady(env)) return null
  const raw = fake(env) ? new FakeCloudDriver(sql) : new FreestyleCloudDriver(env.CLOUD_FREESTYLE_API_KEY!, env.CLOUD_FREESTYLE_API_URL || "https://api.freestyle.sh", imageOf(env)!)
  return new GuardedCloudDriver(raw, env.CLOUD_NAME_PREFIX!)
}
