import type { SqlStore } from "@cmux/ownership"
import type { Env } from "./env.ts"
import { DriverError } from "./team-vm-driver.ts"
import type { CloudConfig } from "./domains/cloud-plan.ts"
import { parseAllowedTeams } from "./domains/cloud-plan.ts"
export { providerName } from "./domains/cloud-plan.ts"
import { FakeCloudDriver } from "./cloud-driver-fake.ts"
import type { CloudProvider, CloudProviderCapabilities, CreateOptions, EdgeTlsRule, GuestExecResult, VmResources, VmTag } from "./providers/contract.ts"
import { directCloudProvider } from "./providers/index.ts"
import { vmApiSettings } from "./cloud-vm-api-config.ts"
import { VmApiSnapshotOutcome } from "./cloud-vm-api-snapshot.ts"
export type { CloudProvider, CloudProviderCapabilities, CreateOptions, EdgeTlsRule, GuestExecResult, ListedVm, VmResources, VmTag } from "./providers/contract.ts"
/** The contract's earlier name (callers and tests still import it). */
export type RawCloudDriver = CloudProvider

/**
 * Provider names (the naming decision in plans/cmux-next/team-vm-plan.md): cmuxnp-<env>-<lane>-<rest>; CloudDO's lane is `cld` (tvm = team
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
/** Snapshot slugs: `<prefix>snap-<20>` (the cld lane). */
const SNAP_TAIL = /^snap-[a-z0-9]{20}$/
const ours = (tag: Record<string, unknown>, want: VmTag) => tag.cmux_next_team === want.team && tag.cmux_next_machine === want.machine

/**
 * The provider behind CloudDO (state-placement.md 5.2, 5.3), through the contract in providers/contract.ts.
 * The provider account may be shared with classic cmux Cloud, so every call goes through GuardedCloudDriver:
 * it refuses a name without this environment's prefix before any request, and never adopts or deletes a VM
 * under our name whose tag names another team or machine. Creates and deletes are idempotent by name: a
 * create first looks the name up (a lost create answer is found, never made twice), and a delete of a name
 * that is not there is success.
 */
export class GuardedCloudDriver {
  constructor(
    private readonly raw: CloudProvider,
    private readonly prefix: string
  ) {
    if (!LANE_PREFIX.test(prefix)) throw new Error("the Cloud driver needs a cmuxnp-<env>-cld- prefix")
  }

  /** What the provider behind this driver can do. */
  get capabilities(): CloudProviderCapabilities {
    return this.raw.capabilities
  }

  private guard(name: string): void {
    if (!name.startsWith(this.prefix) || !NAME_TAIL.test(name.slice(this.prefix.length))) {
      throw new DriverError("cloud.provider.refused", "refused: the resource name does not carry this environment's prefix", true)
    }
  }

  private guardSnapshot(slug: string): void {
    if (!slug.startsWith(this.prefix) || !SNAP_TAIL.test(slug.slice(this.prefix.length))) {
      throw new DriverError("cloud.provider.refused", "refused: the snapshot name does not carry this environment's prefix", true)
    }
  }

  /** The VM under `name`, created if missing. */
  async ensure(name: string, tag: VmTag, opts: CreateOptions): Promise<{ id: string }> {
    this.guard(name)
    if (opts.snapshot !== undefined) this.guardSnapshot(opts.snapshot)
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
   * The contract has no create-time file option, so this is a second call right after the create; a
   * retry overwrites it with a fresh token.
   */
  async writeBindFile(name: string, tag: VmTag, content: string): Promise<void> {
    this.guard(name)
    const found = await this.raw.find(name)
    if (!found) throw new DriverError("cloud.provider.unavailable", "write bind file: the VM is not there yet", false)
    if (!ours(found.tag, tag)) throw new DriverError("cloud.provider.name_conflict", "the name belongs to another VM", true)
    await this.raw.writeFile(found.id, BIND_FILE_PATH, content, 0o600)
  }

  /** Replaces our VM's edge rule for `rule.domain` (a token refresh); false when the VM or its rule is not there. */
  async replaceEdgeRule(name: string, tag: VmTag, rule: EdgeTlsRule): Promise<boolean> {
    this.guard(name)
    const found = await this.raw.find(name)
    if (!found) return false
    if (!ours(found.tag, tag)) throw new DriverError("cloud.provider.name_conflict", "the name belongs to another VM", true)
    return this.raw.replaceTlsRule(found.id, { ...rule, source: { vmId: found.id } })
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
    // the call (a retry after a lost answer) and after a failed one (a provider may answer 409 when already there).
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
    if (!this.raw.capabilities.resize) throw new DriverError("cloud.provider.unsupported", "resize VM: this provider cannot resize", true)
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

  /** The real resources of our VM under `name` (the record follows them: a provider without `sizing` takes no size at create). */
  async resourcesOf(name: string, tag: VmTag): Promise<VmResources | null> {
    this.guard(name)
    const found = await this.raw.find(name)
    if (!found || !ours(found.tag, tag)) return null
    return this.raw.resources(found.id)
  }

  /** The real provider state of our VM under `name`; `gone` when no VM is there (a cheap read for connect_info and link_token). */
  async stateOf(name: string, tag: VmTag): Promise<{ state: string | null; gone: boolean }> {
    this.guard(name)
    const found = await this.raw.find(name)
    if (!found) return { state: null, gone: true }
    if (!ours(found.tag, tag)) throw new DriverError("cloud.provider.name_conflict", "the name belongs to another VM", true)
    // One GET: the find answer carries the state (review P2-3); a second read only when it does not.
    return { state: found.state !== undefined ? found.state : await this.raw.state(found.id), gone: false }
  }

  async recoverSnapshot(vmName: string, tag: VmTag, slug: string): Promise<{ id: string } | null> {
    this.guard(vmName)
    this.guardSnapshot(slug)
    return this.raw.resumeSnapshot?.(slug, tag, false) ?? null
  }

  /** Snapshots our VM under `vmName` as `slug`; a snapshot already under the slug must come from that VM (a retry). */
  async snapshot(vmName: string, tag: VmTag, slug: string): Promise<{ id: string }> {
    this.guard(vmName)
    this.guardSnapshot(slug)
    const resumed = await this.raw.resumeSnapshot?.(slug, tag, true)
    if (resumed) return resumed
    try {
      const vm = await this.raw.find(vmName)
      if (!vm) throw new DriverError("cloud.provider.vm_missing", "snapshot: no VM under the recorded name", true)
      if (!ours(vm.tag, tag)) throw new DriverError("cloud.provider.name_conflict", "the name belongs to another VM", true)
      const existing = await this.raw.findSnapshot(slug)
      if (existing) {
        if (existing.sourceVmId !== vm.id) throw new DriverError("cloud.provider.name_conflict", "the snapshot name belongs to another snapshot", true)
        return { id: existing.id }
      }
      return await this.raw.createSnapshot(vm.id, slug, tag)
    } catch (e) {
      // The VM API verified no capture under the key (null, not undefined): a final error before
      // its send is settled, so Cloud may release the saved slot instead of retaining it.
      if (resumed === null && e instanceof DriverError && e.final && !(e instanceof VmApiSnapshotOutcome)) throw new VmApiSnapshotOutcome("absent", e.message, e.code)
      throw e
    }
  }

  /** Deletes the snapshot under our recorded `slug`; none there is success. */
  async removeSnapshot(slug: string, tag?: VmTag, allowEmptyFence = false): Promise<void> {
    this.guardSnapshot(slug)
    if (this.raw.cancelSnapshot && tag) return this.raw.cancelSnapshot(slug, tag, allowEmptyFence)
    const found = await this.raw.findSnapshot(slug)
    if (found) await this.raw.deleteSnapshot(found.id)
  }

  /** cx-kvmz: one root command on our VM under `name` (metadata checked), stdin = a person key or a person_holds frame. */
  async execStdin(name: string, tag: VmTag, command: string, stdin: Uint8Array | null, timeoutMs: number): Promise<GuestExecResult> {
    this.guard(name)
    const found = await this.raw.find(name)
    if (!found) throw new DriverError("cloud.provider.vm_missing", "guest exec: no VM under the recorded name", true)
    if (!ours(found.tag, tag)) throw new DriverError("cloud.provider.name_conflict", "the name belongs to another VM", true)
    return this.raw.execStdin(found.id, command, stdin, timeoutMs)
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

export const LIST_PAGE = 100

/** The deployment's Cloud config: plan (stub outside production), name prefix (only with a usable provider) and image. */
const directCloudConfig = (env: Env): CloudConfig => {
  const want = ENV_PREFIX[env.ENVIRONMENT]
  const prefixOk = Boolean(want) && env.CLOUD_NAME_PREFIX === want
  const keyOk = fake(env) || directCloudProvider(env).keySet(env)
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

export const cloudConfig = (env: Env): CloudConfig => {
  if (env.CLOUD_VM_TRANSPORT === undefined || env.CLOUD_VM_TRANSPORT === "direct") return { ...directCloudConfig(env), transport: "direct" }
  const api = env.CLOUD_VM_TRANSPORT === "vm-api" ? vmApiSettings(env) : null
  const prefix = ENV_PREFIX[env.ENVIRONMENT]
  return {
    environment: env.ENVIRONMENT, allowedTeams: parseAllowedTeams(env.CLOUD_ALLOWED_TEAMS), transport: "vm-api",
    prefix: api && prefix && env.CLOUD_NAME_PREFIX === prefix ? prefix : null,
    image: api?.image.id ?? null
  }
}

const fake = (env: Env) => env.ENVIRONMENT === "test" && env.CLOUD_DRIVER === "fake"
/** The configured snapshot; the test fake boots a named test image lane snapshot unless a test sets one. */
const imageOf = (env: Env): string | undefined => directCloudProvider(env).image(env) || (fake(env) ? `${ENV_IMAGE_PREFIX.test}fake` : undefined)

/** A usable provider: this environment's exact prefix, a key (or the test fake) and this environment's snapshot. */
const cloudRawDriverReady = (env: Env): boolean => directCloudConfig(env).image !== null

/** Whether this deployment has a usable provider (key or test fake, this environment's prefix, its image). */
export const cloudProviderReady = (env: Env): boolean => cloudRawDriverReady(env) || Boolean(vmApiSettings(env) && ENV_PREFIX[env.ENVIRONMENT] === env.CLOUD_NAME_PREFIX)

/** The guarded driver, or null when this deployment has no usable provider. */
export const cloudDriver = (env: Env, sql: SqlStore): GuardedCloudDriver | null => {
  if (!cloudRawDriverReady(env)) return null
  const raw = fake(env) ? new FakeCloudDriver(sql) : directCloudProvider(env).make(env, imageOf(env)!)
  return new GuardedCloudDriver(raw, env.CLOUD_NAME_PREFIX!)
}
