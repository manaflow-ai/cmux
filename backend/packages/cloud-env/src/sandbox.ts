/**
 * The one interface environments use to drive a sandbox provider. Freestyle (direct or through the
 * cmux VM API) implements it in apps/api (cloud-env-sandbox.ts) over RawCloudDriver; a Firecracker
 * or other provider implements the same five calls. Nothing in this package names a provider.
 */
export interface CloudSandbox {
  /** A short provider label for records and logs ("freestyle", "vm-api", "fake"). */
  readonly provider: string
  /** Boots a new machine from the deployment's base image, or from `snapshot` (a provider snapshot id). */
  boot(options: SandboxBootOptions): Promise<{ readonly id: string }>
  /** Runs `command` with bash as the machine's work user; resolves with the exit code and output. */
  exec(id: string, command: string, timeoutMs: number): Promise<SandboxExecResult>
  /** Snapshots a running machine (memory and disk); resolves with the provider snapshot id. */
  snapshot(id: string, name: string): Promise<{ readonly id: string }>
  /** Deletes a machine; a machine already gone is success. */
  destroy(id: string): Promise<void>
}

export interface SandboxBootOptions {
  /** A unique name for this machine (providers that dedupe creates by name use it as the key). */
  readonly name: string
  /** Boot this provider snapshot instead of the base image. */
  readonly snapshot?: string
}

export interface SandboxExecResult {
  readonly exitCode: number
  readonly stdout: string
  readonly stderr: string
}
