/** A provider call's failure: only the step, the status and a provider code, never a body or a key. */
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

/**
 * The provider contract behind CloudDO (state-placement.md 5.2, 5.3): every machine provider (each
 * folder under providers/, wired in providers/index.ts; the VM API transport; the test fake)
 * implements CloudProvider, and nothing outside providers/ names a provider. GuardedCloudDriver (cloud-driver.ts)
 * wraps one: it owns names, tags and idempotency, so a provider only answers raw calls by name or id.
 * Errors are DriverError (below).
 */
export interface VmTag {
  readonly team: string
  readonly machine: string
}

export interface VmResources {
  readonly cpu: number
  /** MiB. */
  readonly memory: number
  /** MiB. */
  readonly storage: number
}

/**
 * One TLS edge rule (the coderouter edge, cloud-coderouter-edge.ts): the provider's egress steers
 * `domain` to `destination` and injects `transform` headers. Inline at create, `source: {}` means the
 * VM being created; a later replace names it by `vmId`. Header values are secrets: never log a rule.
 */
export interface EdgeTlsRule {
  readonly action: "allow"
  readonly domain: string
  readonly source: { readonly vmId?: string }
  readonly destination: { readonly host: string; readonly port: number }
  readonly transform: ReadonlyArray<{ readonly headers: Readonly<Record<string, string>> }>
}

export interface CreateOptions {
  /** The machine's idle policy in seconds; 0 = never pause. */
  readonly idleSeconds: number
  /** Boot from this snapshot slug (a restore: one of ours, guarded) instead of the deployment's image. */
  readonly snapshot?: string
  /** Inline TLS rules (the coderouter edge, cloud-coderouter-edge.ts); absent or empty sends none. */
  readonly edgeRules?: ReadonlyArray<EdgeTlsRule>
}

export interface ListedVm {
  readonly id: string
  readonly name: string | null
  readonly tag: Record<string, unknown>
}

/** One root command's answer (cx-kvmz). */
export interface GuestExecResult {
  readonly exitCode: number
  readonly stdout: string
  readonly stderr: string
}

/**
 * What a provider can do, so callers check a flag instead of a provider name (the web control
 * plane's VmCapabilities, web/services/vms/drivers/types.ts, is the same idea).
 */
export interface CloudProviderCapabilities {
  /** Create takes a size. False: the image decides it and the record reads the real size back. */
  readonly sizing: boolean
  /** A grow-only resize of vCPU, memory and disk. GuardedCloudDriver refuses a resize without it, before any call. */
  readonly resize: boolean
  /** Snapshots of a running or paused VM, and creates that boot from one. */
  readonly snapshot: boolean
  /** One root command with stdin, answered inline (execStdin). */
  readonly guestExec: boolean
  /** Inline TLS edge rules at create and their in-place replace. */
  readonly edgeTls: boolean
}

/** The metadata every provider stores on a Cloud VM: GuardedCloudDriver adopts a VM only when it matches. */
export const vmTagMetadata = (tag: VmTag) => ({ cmux_next_team: tag.team, cmux_next_machine: tag.machine })

/** One raw provider: `find` by name (null = none), `create` under a name, `delete` by provider id (404 = success). */
export interface CloudProvider {
  readonly capabilities: CloudProviderCapabilities
  /** `state`: the VM's provider state when the same answer carries it (one read instead of two). */
  find(name: string): Promise<{ readonly id: string; readonly tag: Record<string, unknown>; readonly state?: string | null } | null>
  /** `tag` null: this call made the VM; else the VM already under the name (checked by the guard). */
  create(name: string, tag: VmTag, opts: CreateOptions): Promise<{ readonly id: string; readonly tag: Record<string, unknown> | null }>
  delete(id: string): Promise<void>
  /** Pause (memory kept) or start a VM. */
  pause(id: string): Promise<void>
  start(id: string): Promise<void>
  /** The VM's provider state (starting, running, pausing, paused, stopped), or null when it is gone. */
  state(id: string): Promise<string | null>
  /** A snapshot by its slug, or null. */
  findSnapshot(slug: string): Promise<{ readonly id: string; readonly sourceVmId: string | null } | null>
  /** VM API only: resume the exact capture key before requiring its source. False never admits new capture work. */
  resumeSnapshot?(slug: string, tag: VmTag, allowSend: boolean): Promise<{ readonly id: string } | null>
  /** VM API only: fence the key before verifying deletion, including pending captures. */
  cancelSnapshot?(slug: string, tag: VmTag, allowEmptyFence: boolean): Promise<void>
  /** Snapshot a running or paused VM under `slug`. */
  createSnapshot(vmId: string, slug: string, tag?: VmTag): Promise<{ readonly id: string }>
  /** Delete a snapshot (404 is success). */
  deleteSnapshot(id: string): Promise<void>
  /** Grow a VM (grow only; memory and storage in MiB). Only when `capabilities.resize`. */
  resize(id: string, size: VmResources): Promise<void>
  /** The VM's resources, or null when it is gone. */
  resources(id: string): Promise<VmResources | null>
  /** Writes one small file into the VM (atomic, verified). */
  writeFile(id: string, path: string, content: string, mode: number): Promise<void>
  /** One page (100) of VMs whose metadata has `filter` (`key:value`). Used only to report, never to delete. */
  list(filter: string, offset: number): Promise<{ readonly vms: ReadonlyArray<ListedVm>; readonly total: number }>
  /** Replaces the VM's rule for `rule.domain` in place; false when it has none. */
  replaceTlsRule(vmId: string, rule: EdgeTlsRule): Promise<boolean>
  /** One command as root, `stdin` (if any) as its stdin, answered inline (cx-kvmz). */
  execStdin(id: string, command: string, stdin: Uint8Array | null, timeoutMs: number): Promise<GuestExecResult>
}
