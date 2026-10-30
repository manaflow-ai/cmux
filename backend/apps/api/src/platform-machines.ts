import { WorkerEntrypoint } from "cloudflare:workers"
import type { Env } from "./env.ts"
import { refused, type PlatformCall, type PlatformReply } from "./cloud-platform.ts"
import type { MachineExecReply } from "./automation-machine.ts"
import { asWorkUser } from "./cloud-env-sandbox.ts"

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
 * creates. Exec, snapshot and delete reach only machines a platform boot made. ownerExec is the one
 * exception: any machine of the caller's team, for a person who may use them now (CloudDO.ownerExec). It answers only where
 * PLATFORM_MACHINES is "on" (development today): elsewhere every call is refused before any lookup.
 */
export class PlatformMachines extends WorkerEntrypoint<Env> {
  boot(caller: PlatformCaller, name: string, snapshot?: string | null): Promise<PlatformReply<{ id: string }>> {
    if (snapshot !== undefined && snapshot !== null && !matches(SNAPSHOT, snapshot)) return invalid("snapshot")
    return this.call(caller, { op: "boot", name, ...(snapshot ? { snapshot } : {}) }) as Promise<PlatformReply<{ id: string }>>
  }

  find(caller: PlatformCaller, name: string): Promise<PlatformReply<{ id: string } | null>> {
    return this.call(caller, { op: "find", name }) as Promise<PlatformReply<{ id: string } | null>>
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

  /**
   * One command on the caller's OWN machine (not a setup builder): cmux-platform's /v1/vm/{id}/exec and
   * /v1/vm/{id}/fs routes, which mirror classic /api/vm for Worker machines. `as` "work" runs it as the
   * image's work user (classic exec), "root" as root (classic's file API writes as root). CloudDO allows
   * a person who may use the team's machines now, as classic /api/vm does (CloudDO.ownerExec); stdin is raw bytes.
   */
  async ownerExec(caller: PlatformCaller, machine: string, command: string, stdin: Uint8Array | null, timeoutMs: number, as: "work" | "root"): Promise<PlatformReply<{ exitCode: number; stdout: string; stderr: string }>> {
    if (typeof command !== "string" || command.length === 0 || command.length > MAX_COMMAND) return invalid("command")
    if (stdin !== null && (!(stdin instanceof Uint8Array) || stdin.byteLength > MAX_OWNER_STDIN)) return invalid("stdin")
    if (typeof timeoutMs !== "number" || !Number.isFinite(timeoutMs) || timeoutMs <= 0 || timeoutMs > MAX_OWNER_EXEC_MS) return invalid("timeoutMs")
    if (as !== "work" && as !== "root") return invalid("as")
    const checked = this.checked(caller)
    if ("ok" in checked) return checked
    if (!matches(MACHINE, machine)) return refused("validation.invalid", "invalid machine", false)
    const stub = this.env.CLOUD_DO.get(this.env.CLOUD_DO.idFromName(checked.team)) as unknown as { ownerExec(e: string, u: string, m: string, c: string, s: Uint8Array | null, t: number): Promise<MachineExecReply> }
    let r: MachineExecReply
    try {
      r = await stub.ownerExec(checked.team, checked.user, machine, as === "work" ? asWorkUser(command) : command, stdin, timeoutMs)
    } catch {
      return refused("owner.unreachable", "the team's machines could not be reached; retry", true)
    }
    if (r.ok) return { ok: true, value: { exitCode: r.exitCode, stdout: r.stdout, stderr: r.stderr } }
    switch (r.refusal) {
      case "not_found":
        return refused("cloud.machine.not_found", "no such machine in this team", false)
      case "forbidden":
        return refused("auth.forbidden", "this user may not use the team's machines", false)
      case "not_running":
        return refused("cloud.machine.not_running", "the machine is not running", true)
      default:
        return refused("cloud.provider.unavailable", "the machine did not answer", true)
    }
  }

  /** The caller, or the refusal every call answers first (the deployment's switch, then the caller's shape). */
  private checked(caller: PlatformCaller): PlatformCaller | PlatformReply<never> {
    if (this.env.PLATFORM_MACHINES !== "on") return refused("platform.machines_off", "platform machines are not enabled on this deployment", false)
    const team = caller?.team, user = caller?.user
    if (typeof team !== "string" || !TEAM.test(team) || typeof user !== "string" || !USER.test(user)) return refused("validation.invalid", "invalid caller", false)
    return { team, user }
  }

  private async call(caller: PlatformCaller, call: PlatformCall): Promise<PlatformReply> {
    const checked = this.checked(caller)
    if ("ok" in checked) return checked
    const { team, user } = checked
    if ("name" in call && !matches(NAME, call.name)) return refused("validation.invalid", "invalid name", false)
    if ("machine" in call && !matches(MACHINE, call.machine)) return refused("validation.invalid", "invalid machine", false)
    const stub = this.env.CLOUD_DO.get(this.env.CLOUD_DO.idFromName(team)) as unknown as { platformMachine(e: string, u: string, c: PlatformCall): Promise<PlatformReply> }
    try {
      return await stub.platformMachine(team, user, call)
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

const TEAM = /^team_[A-Za-z0-9]{1,64}$/
const USER = /^user_[A-Za-z0-9]{1,64}$/
/** The caller's name for a builder or snapshot (one per environment and attempt): it keys the op, so a retry reaches the same one. */
const NAME = /^[A-Za-z0-9_-]{1,96}$/
const MACHINE = /^vm_[a-z0-9]{20}$/
const SNAPSHOT = /^snap_[a-z0-9]{20}$/
const MAX_COMMAND = 64 * 1024
const MAX_STDIN = 64 * 1024
/** A file write's content (cmux-platform's /v1/vm/{id}/fs/write caps it at 8 MiB decoded). */
const MAX_OWNER_STDIN = 8 * 1024 * 1024
/** Classic /api/vm exec's cap. */
const MAX_OWNER_EXEC_MS = 15 * 60_000
/** Only a string matches: an RPC caller can pass any structured value. */
const matches = (re: RegExp, v: unknown): v is string => typeof v === "string" && re.test(v)
const invalid = (what: string) => Promise.resolve(refused("validation.invalid", `invalid ${what}`, false))
