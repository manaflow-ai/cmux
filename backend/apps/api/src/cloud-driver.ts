import type { SqlStore } from "@cmux/ownership"
import type { Env } from "./env.ts"
import { DriverError } from "./team-vm-driver.ts"
import type { CloudConfig } from "./domains/cloud-plan.ts"
import { planFor } from "./domains/cloud-plan.ts"
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
  create(name: string, tag: VmTag): Promise<{ readonly id: string; readonly tag: Record<string, unknown> | null }>
  delete(id: string): Promise<void>
}

/** Expected prefix per environment; a configured prefix that differs disables the provider. */
export const ENV_PREFIX: Readonly<Record<string, string>> = { development: "cmuxnp-dev-", staging: "cmuxnp-stg-", production: "cmuxnp-prod-", test: "cmuxnp-test-" }

const NAME_TAIL = /^[a-z0-9][a-z0-9-]{0,50}$/
const ours = (tag: Record<string, unknown>, want: VmTag) => tag.cmux_next_team === want.team && tag.cmux_next_machine === want.machine

export class GuardedCloudDriver {
  constructor(
    private readonly raw: RawCloudDriver,
    private readonly prefix: string
  ) {}

  private guard(name: string): void {
    if (!name.startsWith(this.prefix) || !NAME_TAIL.test(name.slice(this.prefix.length))) {
      throw new DriverError("cloud.provider.refused", "refused: the resource name does not carry this environment's prefix", true)
    }
  }

  /** The VM under `name`, created if missing. */
  async ensure(name: string, tag: VmTag): Promise<{ id: string }> {
    this.guard(name)
    const found = await this.raw.find(name)
    if (found) {
      if (!ours(found.tag, tag)) throw new DriverError("cloud.provider.name_conflict", "the name belongs to another VM", true)
      return { id: found.id }
    }
    const created = await this.raw.create(name, tag)
    if (created.tag !== null && !ours(created.tag, tag)) throw new DriverError("cloud.provider.name_conflict", "the name belongs to another VM", true)
    return { id: created.id }
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

const REQUEST_TIMEOUT_MS = 20_000
const CREATE_TIMEOUT_MS = 120_000
const IDLE_TIMEOUT_SECONDS = 1800

/** Freestyle REST (the same v5 calls TeamVmDO's driver measured). Errors carry only the step, status and provider code. */
export class FreestyleCloudDriver implements RawCloudDriver {
  constructor(
    private readonly apiKey: string,
    private readonly baseUrl: string,
    private readonly snapshot: string
  ) {}

  private async call(method: string, path: string, body?: unknown, timeoutMs = REQUEST_TIMEOUT_MS): Promise<{ status: number; json: Record<string, unknown> }> {
    try {
      const res = await fetch(`${this.baseUrl.replace(/\/+$/, "")}${path}`, {
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

  async create(name: string, tag: VmTag) {
    const created = await this.call(
      "POST",
      "/v5/vms",
      {
        slug: name,
        snapshotId: this.snapshot,
        idleTimeoutSeconds: IDLE_TIMEOUT_SECONDS,
        metadata: { cmux_next_team: tag.team, cmux_next_machine: tag.machine },
        firewall: { rules: [{ action: "allow", source: {}, destination: { public: true } }] }
      },
      CREATE_TIMEOUT_MS
    )
    if (created.status >= 200 && created.status < 300) return { id: this.vm(created.json).id, tag: null }
    // A duplicate name (409) or an unknown outcome: the VM under the name, if any, is the answer.
    const found = await this.find(name)
    if (found) return found
    this.fail(created.status, created.json, "create VM")
  }

  async delete(id: string) {
    const r = await this.call("DELETE", `/v5/vms/${encodeURIComponent(id)}`)
    if (r.status === 404 || (r.status >= 200 && r.status < 300)) return
    this.fail(r.status, r.json, "delete VM")
  }
}

/**
 * Test provider (ENVIRONMENT=test, CLOUD_DRIVER=fake): VMs in the object's own SQLite.
 * `fail_next` makes the next calls fail as retryable (a cut-off call).
 */
export class FakeCloudDriver implements RawCloudDriver {
  constructor(private readonly sql: SqlStore) {
    sql.exec(`CREATE TABLE IF NOT EXISTS cloud_fake_vm (name TEXT PRIMARY KEY, id TEXT NOT NULL UNIQUE, tag TEXT NOT NULL)`)
    sql.exec(`CREATE TABLE IF NOT EXISTS cloud_fake_ctl (id INTEGER PRIMARY KEY CHECK (id = 1), fail_next INTEGER NOT NULL DEFAULT 0, creates INTEGER NOT NULL DEFAULT 0, deletes INTEGER NOT NULL DEFAULT 0)`)
    sql.exec(`INSERT OR IGNORE INTO cloud_fake_ctl (id) VALUES (1)`)
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

  async create(name: string, tag: VmTag) {
    this.maybeFail()
    const t = { cmux_next_team: tag.team, cmux_next_machine: tag.machine }
    this.sql.exec(`INSERT INTO cloud_fake_vm (name, id, tag) VALUES (?, ?, ?)`, name, `fs-${name}`, JSON.stringify(t))
    this.sql.exec(`UPDATE cloud_fake_ctl SET creates = creates + 1 WHERE id = 1`)
    return { id: `fs-${name}`, tag: null }
  }

  async delete(id: string) {
    this.maybeFail()
    const gone = this.sql.exec<{ name: string }>(`DELETE FROM cloud_fake_vm WHERE id = ? RETURNING name`, id)
    if (gone.length) this.sql.exec(`UPDATE cloud_fake_ctl SET deletes = deletes + 1 WHERE id = 1`)
  }
}

/** The deployment's Cloud config: plan (stub outside production), name prefix (only with a usable provider) and image. */
export const cloudConfig = (env: Env): CloudConfig => {
  const want = ENV_PREFIX[env.ENVIRONMENT]
  const prefixOk = Boolean(want) && env.CLOUD_NAME_PREFIX === want
  const keyOk = fake(env) || Boolean(env.CLOUD_FREESTYLE_API_KEY)
  const snapshot = imageOf(env)
  // CLOUD-DEV-SNAPSHOT: only this environment's image lane snapshot (its name carries the prefix); no fallback.
  const imageProblem = !snapshot ? "missing" : prefixOk && snapshot.startsWith(env.CLOUD_NAME_PREFIX!) ? undefined : "foreign"
  return {
    plan: planFor(env.ENVIRONMENT),
    prefix: prefixOk && keyOk ? env.CLOUD_NAME_PREFIX! : null,
    image: prefixOk && keyOk && !imageProblem ? snapshot! : null,
    ...(imageProblem ? { imageProblem } : {})
  }
}

const fake = (env: Env) => env.ENVIRONMENT === "test" && env.CLOUD_DRIVER === "fake"
/** The configured snapshot; the test fake boots a named image under the test prefix unless a test sets one. */
const imageOf = (env: Env): string | undefined => env.CLOUD_FREESTYLE_SNAPSHOT || (fake(env) && env.CLOUD_NAME_PREFIX ? `${env.CLOUD_NAME_PREFIX}vmimg-fake` : undefined)

/** A usable provider: this environment's exact prefix, a key (or the test fake) and this environment's snapshot. */
const cloudRawDriverReady = (env: Env): boolean => cloudConfig(env).image !== null

/** The guarded driver, or null when this deployment has no usable provider. */
export const cloudDriver = (env: Env, sql: SqlStore): GuardedCloudDriver | null => {
  if (!cloudRawDriverReady(env)) return null
  const raw = fake(env) ? new FakeCloudDriver(sql) : new FreestyleCloudDriver(env.CLOUD_FREESTYLE_API_KEY!, env.CLOUD_FREESTYLE_API_URL || "https://api.freestyle.sh", imageOf(env)!)
  return new GuardedCloudDriver(raw, env.CLOUD_NAME_PREFIX!)
}
