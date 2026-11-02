import { WorkerEntrypoint } from "cloudflare:workers"
import type { Env } from "./env.ts"
import { refused, type PlatformCall, type PlatformReply } from "./cloud-platform.ts"

/**
 * Cloud machines for the platform Worker's derived environment setups (manaflow-ai/cmux-platform,
 * its `Machines` port): boot (from the deployment's image or a team snapshot), exec, snapshot and
 * delete, for the user and team the caller names, through that team's CloudDO (cloud-platform.ts).
 *
 * Auth model. This class is a named entrypoint, never the default export's fetch: no HTTP route
 * reaches it. Only a Worker in this Cloudflare account whose wrangler config binds it
 * (`services: [{ binding, service: "<this worker>", entrypoint: "PlatformMachines" }]`) can call
 * it, and binding it is a deploy to that account. The caller vouches for the user and team (the
 * platform verified the person's cmux access token for its derive); CloudDO still checks, on every
 * call, that the user may use the team's machines now, and runs boot, snapshot and delete as that
 * person's own ops, so the team's plan, quotas and per-team limit decide as for a machine the person
 * creates. Exec, snapshot, resize and delete reach only machines a platform boot made. It answers in every
 * environment where PLATFORM_MACHINES is "on"; the team's plan (cloud-plan.ts teamPlan) decides who
 * may create, so production creates only for a team with a paid plan or grant. With the flag off
 * only ownership-checked find and destroy remain for cleanup; create/fork only recover existing
 * intent IDs and providerInfo reports unavailable.
 */
export class PlatformMachines extends WorkerEntrypoint<Env> {
  boot(caller: PlatformCaller, name: string, snapshot?: string | null): Promise<PlatformReply<{ id: string }>> {
    if (snapshot !== undefined && snapshot !== null && !matches(SNAPSHOT, snapshot)) return invalid("snapshot")
    return this.call(caller, { op: "boot", name, ...(snapshot ? { snapshot } : {}) }) as Promise<PlatformReply<{ id: string }>>
  }

  providerInfo(caller: PlatformCaller): Promise<PlatformReply<PlatformProviderInfo>> {
    return this.call(caller, { op: "providerInfo" }) as Promise<PlatformReply<PlatformProviderInfo>>
  }

  create(caller: PlatformCaller, name: string, shape: PlatformShape, snapshot?: string | null, labels: Record<string, string> = {}): Promise<PlatformReply<PlatformMachine>> {
    if (!validShape(shape)) return invalid("shape")
    if (!validLabels(labels)) return invalid("labels")
    if (snapshot !== undefined && snapshot !== null && !matches(SNAPSHOT, snapshot)) return invalid("snapshot")
    return this.call(caller, { op: "create", name, shape, labels, ...(snapshot ? { snapshot } : {}) }) as Promise<PlatformReply<PlatformMachine>>
  }

  find(caller: PlatformCaller, name: string): Promise<PlatformReply<{ id: string } | null>> {
    return this.call(caller, { op: "find", name }) as Promise<PlatformReply<{ id: string } | null>>
  }

  get(caller: PlatformCaller, machine: string): Promise<PlatformReply<PlatformMachine>> {
    return this.call(caller, { op: "get", machine }) as Promise<PlatformReply<PlatformMachine>>
  }

  shape(caller: PlatformCaller, machine: string): Promise<PlatformReply<PlatformShape>> {
    return this.call(caller, { op: "shape", machine }) as Promise<PlatformReply<PlatformShape>>
  }

  pause(caller: PlatformCaller, machine: string): Promise<PlatformReply<PlatformMachine>> {
    return this.call(caller, { op: "pause", machine }) as Promise<PlatformReply<PlatformMachine>>
  }

  resume(caller: PlatformCaller, machine: string): Promise<PlatformReply<PlatformMachine>> {
    return this.call(caller, { op: "resume", machine }) as Promise<PlatformReply<PlatformMachine>>
  }

  /**
   * Grow the machine in place to `shape` (Freestyle grows only; the disk only while running), as the
   * person's own cloud.machine.resize, so the team's plan limits apply. Already at `shape`: its
   * metadata, with no provider call. A shrink on any axis is cloud.size.grow_only; a change still
   * running on the machine is a retryable mutation.indeterminate. Done: the provider-confirmed shape.
   */
  resize(caller: PlatformCaller, machine: string, shape: PlatformShape): Promise<PlatformReply<PlatformMachine>> {
    if (!validShape(shape)) return invalid("shape")
    return this.call(caller, { op: "resize", machine, shape: { vcpu: shape.vcpu, memGiB: shape.memGiB, diskGiB: shape.diskGiB } }) as Promise<PlatformReply<PlatformMachine>>
  }

  fork(caller: PlatformCaller, machine: string, name: string): Promise<PlatformReply<PlatformMachine>> {
    return this.call(caller, { op: "fork", machine, name }) as Promise<PlatformReply<PlatformMachine>>
  }

  exec(caller: PlatformCaller, machine: string, command: string, stdin: string | null, timeoutMs: number): Promise<PlatformReply<{ exitCode: number; stdout: string; stderr: string }>> {
    if (typeof command !== "string" || command.length === 0 || command.length > MAX_COMMAND) return invalid("command")
    if (stdin !== null && (typeof stdin !== "string" || stdin.length > MAX_STDIN)) return invalid("stdin")
    if (typeof timeoutMs !== "number" || !Number.isFinite(timeoutMs) || timeoutMs <= 0) return invalid("timeoutMs")
    return this.call(caller, { op: "exec", machine, command, stdin, timeoutMs }) as Promise<PlatformReply<{ exitCode: number; stdout: string; stderr: string }>>
  }

  snapshot(caller: PlatformCaller, machine: string, name: string): Promise<PlatformReply<{ id: string }>> {
    return this.call(caller, { op: "snapshot", machine, name }) as Promise<PlatformReply<{ id: string }>>
  }

  destroy(caller: PlatformCaller, machine: string): Promise<PlatformReply<{ deleted: true }>> {
    return this.call(caller, { op: "destroy", machine }) as Promise<PlatformReply<{ deleted: true }>>
  }

  deleteSnapshot(caller: PlatformCaller, snapshot: string): Promise<PlatformReply<{ deleted: true }>> {
    if (!matches(SNAPSHOT, snapshot)) return invalid("snapshot")
    return this.call(caller, { op: "deleteSnapshot", snapshot }) as Promise<PlatformReply<{ deleted: true }>>
  }

  private async call(caller: PlatformCaller, call: PlatformCall): Promise<PlatformReply> {
    const cleanup = call.op === "find" || call.op === "destroy" || call.op === "create" || call.op === "fork" || call.op === "providerInfo"
    if (this.env.PLATFORM_MACHINES !== "on" && !cleanup) return refused("platform.machines_off", "platform machines are not enabled on this deployment", false)
    const team = caller?.team, user = caller?.user
    if (typeof team !== "string" || !TEAM.test(team) || typeof user !== "string" || !USER.test(user)) return refused("validation.invalid", "invalid caller", false)
    if ("name" in call && !matches(NAME, call.name)) return refused("validation.invalid", "invalid name", false)
    if ("machine" in call && !matches(MACHINE, call.machine)) return refused("validation.invalid", "invalid machine", false)
    if ("snapshot" in call && !matches(SNAPSHOT, call.snapshot)) return refused("validation.invalid", "invalid snapshot", false)
    const stub = this.env.CLOUD_DO.get(this.env.CLOUD_DO.idFromName(team)) as unknown as { platformMachine(e: string, u: string, c: PlatformCall, recoveryOnly?: boolean): Promise<PlatformReply> }
    try {
      return await stub.platformMachine(team, user, call, this.env.PLATFORM_MACHINES !== "on")
    } catch {
      return refused("owner.unreachable", "the team's machines could not be reached; retry", true)
    }
  }
}

/** Who the call is for: the person whose derive started the setup, and their team. */
export interface PlatformCaller {
  readonly team: string
  readonly user: string
}

export interface PlatformShape {
  readonly vcpu: number
  readonly memGiB: number
  readonly diskGiB: number
}

export interface PlatformMachine {
  readonly id: string
  readonly state: "starting" | "running" | "paused" | "stopped" | "failed" | "gone"
  readonly region: "global"
  readonly shape: PlatformShape
  /** While starting: requested reservation, not confirmation of a completed resize. */
  readonly targetShape?: PlatformShape
}

export interface PlatformProviderInfo {
  readonly protocolVersion: 1
  readonly provider: "freestyle"
  readonly region: "global"
  readonly available: boolean
  readonly shapeSelection: "grow-to-fit"
  readonly minimumShape: PlatformShape | null
  readonly memoryPause: true
  readonly fork: true
}

const TEAM = /^team_[A-Za-z0-9]{1,64}$/
const USER = /^user_[A-Za-z0-9]{1,64}$/
/** The caller's name for a builder or snapshot (one per environment and attempt): it keys the op, so a retry reaches the same one. */
const NAME = /^[A-Za-z0-9_-]{1,96}$/
const MACHINE = /^vm_[a-z0-9]{20}$/
const SNAPSHOT = /^snap_[a-z0-9]{20}$/
const MAX_COMMAND = 64 * 1024
const MAX_STDIN = 64 * 1024
/** Only a string matches: an RPC caller can pass any structured value. */
const matches = (re: RegExp, v: unknown): v is string => typeof v === "string" && re.test(v)
const validShape = (shape: PlatformShape): boolean =>
  shape !== null && typeof shape === "object" &&
  Number.isSafeInteger(shape.vcpu) && shape.vcpu > 0 && shape.vcpu <= Number.MAX_SAFE_INTEGER &&
  Number.isSafeInteger(shape.memGiB) && shape.memGiB > 0 && shape.memGiB <= Number.MAX_SAFE_INTEGER / 1024 &&
  Number.isSafeInteger(shape.diskGiB) && shape.diskGiB > 0 && shape.diskGiB <= Number.MAX_SAFE_INTEGER / 1024
/** Intent metadata stays in CloudDO; it is not forwarded as provider VM tags. */
const validLabels = (labels: Record<string, string>): boolean => {
  if (labels === null || typeof labels !== "object" || Array.isArray(labels)) return false
  const entries = Object.entries(labels)
  return entries.length <= 32 && entries.every(([k, v]) => k.length > 0 && k.length <= 128 && typeof v === "string" && v.length <= 1024) && JSON.stringify(labels).length <= 16 * 1024
}
const invalid = (what: string) => Promise.resolve(refused("validation.invalid", `invalid ${what}`, false))
