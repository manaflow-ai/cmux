import { environmentBuildPollExec, environmentBuildStartExec, parseBuildPoll } from "./build-script.ts"
import type { CloudSandbox } from "./sandbox.ts"
import { environmentBuildDigest, type EnvironmentSpec } from "./spec.ts"

export type EnvironmentBuildStage = "boot" | "ready" | "setup" | "snapshot" | "warm"

export interface EnvironmentBuildTimings {
  readonly bootMs: number
  readonly readyMs: number
  readonly setupMs: number
  readonly snapshotMs: number
  /** The warm-up boot from the new snapshot (0 when skipped). */
  readonly warmMs: number
  readonly totalMs: number
}

export interface EnvironmentBuildResult {
  readonly snapshotId: string
  readonly digest: string
  readonly builderId: string
  readonly timings: EnvironmentBuildTimings
}

const LOG_TAIL_BYTES = 4096

/** The last 4 KB of a log, cut on a character boundary. */
export const logTail = (text: string): string => {
  const encoded = new TextEncoder().encode(text)
  return encoded.byteLength <= LOG_TAIL_BYTES ? text : new TextDecoder().decode(encoded.subarray(encoded.byteLength - LOG_TAIL_BYTES)).replace(/^�+/, "")
}

export class EnvironmentBuildError extends Error {
  constructor(readonly stage: EnvironmentBuildStage, message: string, readonly logTail = "") {
    super(message)
    this.name = "EnvironmentBuildError"
  }
}

export interface EnvironmentBuildOptions {
  readonly baseImage: string
  /** The builder machine's unique name (the provider's create key). */
  readonly builderName: string
  readonly snapshotName: string
  readonly readyTimeoutMs?: number
  readonly readyIntervalMs?: number
  /** The whole setup (clone plus the user's script); it runs detached, so it may outlast one exec. */
  readonly setupTimeoutMs?: number
  /** How often the detached setup is polled. */
  readonly setupPollMs?: number
  /**
   * Boot one machine from the new snapshot and delete it before answering (default on). Freestyle's
   * first boot from a fresh snapshot fills its cache (17.7 s measured, against 0.6-0.8 s after), so
   * the build pays it instead of the first workspace. The name must be unique like builderName.
   */
  readonly warmName?: string | null
  /** Monotonic ms clock, injected for tests. */
  readonly now?: () => number
  /** Waits `ms`; injected for tests. Used only between readiness probes, bounded by readyTimeoutMs. */
  readonly sleep?: (ms: number) => Promise<void>
}

const message = (e: unknown) => (e instanceof Error ? e.message : String(e))

/** Polls the guest with `true` until it answers, bounded by `timeoutMs`; the provider has no readiness event. */
export const awaitSandboxReady = async (sandbox: CloudSandbox, id: string, o: { timeoutMs: number; intervalMs: number; now: () => number; sleep: (ms: number) => Promise<void> }): Promise<void> => {
  const deadline = o.now() + o.timeoutMs
  for (;;) {
    let last: unknown
    try {
      const r = await sandbox.exec(id, "true", Math.min(10_000, o.timeoutMs))
      if (r.exitCode === 0) return
      last = `exit ${r.exitCode}`
    } catch (e) {
      last = e
    }
    if (o.now() >= deadline) throw new EnvironmentBuildError("ready", `guest did not answer within ${o.timeoutMs} ms: ${message(last)}`)
    await o.sleep(o.intervalMs)
  }
}

/**
 * One build: boot a builder from the base image, run the build script once, snapshot, and delete the
 * builder whatever happened. A snapshot is taken only after the setup exited 0.
 */
export const buildEnvironmentSnapshot = async (sandbox: CloudSandbox, spec: EnvironmentSpec, o: EnvironmentBuildOptions): Promise<EnvironmentBuildResult> => {
  const now = o.now ?? (() => performance.now())
  const sleep = o.sleep ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)))
  const digest = environmentBuildDigest(spec, o.baseImage)
  const started = now()
  let builder: { id: string }
  try {
    builder = await sandbox.boot({ name: o.builderName })
  } catch (e) {
    throw new EnvironmentBuildError("boot", message(e))
  }
  try {
    const booted = now()
    await awaitSandboxReady(sandbox, builder.id, { timeoutMs: o.readyTimeoutMs ?? 120_000, intervalMs: o.readyIntervalMs ?? 250, now, sleep })
    const ready = now()
    const tail = await runDetachedSetup(sandbox, builder.id, spec, digest, { timeoutMs: o.setupTimeoutMs ?? 30 * 60_000, pollMs: o.setupPollMs ?? 2_000, now, sleep })
    const setupDone = now()
    let snap: { id: string }
    try {
      snap = await sandbox.snapshot(builder.id, o.snapshotName)
    } catch (e) {
      throw new EnvironmentBuildError("snapshot", message(e), tail)
    }
    const snapped = now()
    if (o.warmName !== null) await warmSnapshot(sandbox, snap.id, o.warmName ?? `${o.builderName}-warm`)
    const end = now()
    return {
      snapshotId: snap.id,
      digest,
      builderId: builder.id,
      timings: { bootMs: booted - started, readyMs: ready - booted, setupMs: setupDone - ready, snapshotMs: snapped - setupDone, warmMs: end - snapped, totalMs: end - started }
    }
  } finally {
    // Best effort here: CloudDO atomically hands both recorded names to its durable cleanup ledger
    // when the build settles (success or failure), and retries deletion until absence is confirmed.
    await sandbox.destroy(builder.id).catch(() => undefined)
  }
}

/** Starts the build detached, then polls its exit file until it ends or `timeoutMs` passes. Returns the log tail. */
const runDetachedSetup = async (sandbox: CloudSandbox, id: string, spec: EnvironmentSpec, digest: string, o: { timeoutMs: number; pollMs: number; now: () => number; sleep: (ms: number) => Promise<void> }): Promise<string> => {
  const deadline = o.now() + o.timeoutMs
  try {
    const started = await sandbox.exec(id, environmentBuildStartExec(spec, digest), 60_000)
    if (started.exitCode !== 0) throw new Error(`start exited ${started.exitCode}: ${logTail(started.stdout + started.stderr)}`)
  } catch (e) {
    throw e instanceof EnvironmentBuildError ? e : new EnvironmentBuildError("setup", message(e))
  }
  let log = ""
  for (;;) {
    // A missed poll (a cut-off exec) is retried until the deadline; the build keeps running in the guest.
    const r = await sandbox.exec(id, environmentBuildPollExec(), 30_000).catch(() => null)
    if (r && r.exitCode === 0) {
      const poll = parseBuildPoll(r.stdout)
      log = logTail(poll.log)
      if (poll.exitCode === 0) return log
      if (poll.exitCode !== null) throw new EnvironmentBuildError("setup", `setup exited ${poll.exitCode}`, log)
    }
    if (o.now() >= deadline) throw new EnvironmentBuildError("setup", `setup did not finish within ${o.timeoutMs} ms`, log)
    await o.sleep(o.pollMs)
  }
}

/** Boots from the snapshot and attempts deletion; CloudDO's durable cleanup also covers this name. */
const warmSnapshot = async (sandbox: CloudSandbox, snapshotId: string, name: string): Promise<void> => {
  let vm: { id: string }
  try {
    vm = await sandbox.boot({ name, snapshot: snapshotId })
  } catch (e) {
    throw new EnvironmentBuildError("warm", message(e))
  }
  await sandbox.destroy(vm.id).catch(() => undefined)
}
