import type { Env } from "../../env.ts"
import { asState } from "../../domains/team-vm.ts"
import type { TeamVmDriver } from "../../team-vm-driver.ts"
import { DriverError } from "../contract.ts"
import type { TeamVmProviderWiring } from "../index.ts"
import { FreestyleFiles } from "./team-vm-files.ts"

/** The team VM provider on Freestyle (plans/cmux-next/team-vm-plan.md S2): REST v5 with the team VM lane's key. */
/** Idle pause: the provider pauses the VM after this long without activity (spec: about 10 minutes). */
const IDLE_TIMEOUT_SECONDS = 600
/** One provider request; a wake is normally well under a second, the first one after a long pause a few seconds. */
const REQUEST_TIMEOUT_MS = 20_000
/** A create can take much longer than a wake (the web driver allows minutes); a lost answer is recovered by slug. */
const CREATE_TIMEOUT_MS = 120_000
/** The guest `sync` before a retire: long enough to flush a busy disk, short enough that the fence follows promptly. */
const RETIRE_SYNC_MS = 15_000
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
    // The file API reads a paused VM's disk image, not the guest page cache (measured cx-lyvg: a
    // file written seconds before the pause read back as 0 bytes). So a running VM syncs first,
    // as root, bounded; a failure never holds the fence back. A paused VM is never woken for it.
    const seen = await this.call("GET", `/v5/vms/${encodeURIComponent(id)}`)
    if (seen.status === 404) throw new DriverError("team_vm.vm_missing", "retire VM: 404", true)
    if (seen.status === 200 && seen.json.state === "running") {
      const synced = await this.call("POST", `/v5/vms/${encodeURIComponent(id)}/exec-await`, { command: "sync", timeoutMs: RETIRE_SYNC_MS, linuxUser: "root" }, RETIRE_SYNC_MS + 5_000)
      if (synced.status !== 200 || synced.json.statusCode !== 0) console.warn(JSON.stringify({ msg: "team vm retire sync failed", vm: id, status: synced.status }))
    }
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

/** The Freestyle wiring for team VMs (providers/index.ts): FREESTYLE_API_KEY and FREESTYLE_API_URL, the team VM lane's own key. */
export const freestyleTeamVm: TeamVmProviderWiring = {
  id: "freestyle",
  keySet: (env: Env) => Boolean(env.FREESTYLE_API_KEY),
  make: (env: Env, snapshot: string) => new FreestyleDriver(env.FREESTYLE_API_KEY!, env.FREESTYLE_API_URL || "https://api.freestyle.sh", snapshot)
}
