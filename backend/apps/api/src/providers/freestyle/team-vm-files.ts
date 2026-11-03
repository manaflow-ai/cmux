import type { FsKind, FsStat, TeamVmFiles } from "../../team-vm-driver.ts"
import { DriverError } from "../contract.ts"

/** One metadata call (list or stat); a read gets the caller's signal instead. */
const META_TIMEOUT_MS = 20_000

const kindOf = (v: unknown): FsKind => (v === "file" || v === "directory" || v === "symlink" ? v : "other")

/**
 * Freestyle's file API (`GET /v5/vms/{id}/fs/dir|stat|read?path=`, OpenAPI v5). It works on the
 * VM's disk while the VM is paused with its run budget spent (cx-009a: fs/read 200 on a fenced VM).
 * A 404 means "no such VM, or no such path"; a second read of the VM tells the two apart.
 */
export class FreestyleFiles implements TeamVmFiles {
  constructor(
    private readonly apiKey: string,
    private readonly baseUrl: string
  ) {}

  private url(id: string, verb: string, path: string) {
    return `${this.baseUrl.replace(/\/+$/, "")}/v5/vms/${encodeURIComponent(id)}/fs/${verb}?path=${encodeURIComponent(path)}`
  }

  private async get(url: string, signal: AbortSignal, headers: Record<string, string> = {}): Promise<Response> {
    try {
      return await fetch(url, { headers: { authorization: `Bearer ${this.apiKey}`, ...headers }, signal })
    } catch (e) {
      throw new DriverError("team_vm.provider_failed", `fs: no answer ${e instanceof Error && e.name === "TimeoutError" ? "TIMEOUT" : "UNREACHABLE"}`, false)
    }
  }

  /** On a 404: null when the VM exists (the path is missing), else vm_missing. */
  private async missing(id: string): Promise<null> {
    const vm = await this.get(`${this.baseUrl.replace(/\/+$/, "")}/v5/vms/${encodeURIComponent(id)}`, AbortSignal.timeout(META_TIMEOUT_MS))
    await vm.body?.cancel()
    if (vm.status === 404) throw new DriverError("team_vm.vm_missing", "fs: VM 404", true)
    if (vm.status !== 200) throw this.failure(vm.status, "", "fs")
    return null
  }

  /** Only the step, the status and the provider's code reach the caller, never its message. */
  private failure(status: number, code: string, what: string): DriverError {
    const final = status === 400 || status === 401 || status === 403 || status === 422
    return new DriverError(final ? "team_vm.provider_refused" : "team_vm.provider_failed", `${what}: ${status}${code ? ` ${code.slice(0, 40)}` : ""}`, final)
  }

  private async json(res: Response, what: string): Promise<Record<string, unknown>> {
    const body = (await res.json().catch(() => ({}))) as Record<string, unknown>
    if (res.status !== 200) throw this.failure(res.status, typeof body.code === "string" ? body.code : "", what)
    return body
  }

  async list(id: string, path: string) {
    const res = await this.get(this.url(id, "dir", path), AbortSignal.timeout(META_TIMEOUT_MS))
    if (res.status === 404) return (await res.body?.cancel(), this.missing(id))
    const body = await this.json(res, "fs list")
    if (!Array.isArray(body.entries)) throw new DriverError("team_vm.provider_failed", "fs list: answer without entries", false)
    return (body.entries as Array<Record<string, unknown>>).filter((e) => typeof e.name === "string").map((e) => ({ name: e.name as string, kind: kindOf(e.kind) }))
  }

  async stat(id: string, path: string): Promise<FsStat | null> {
    const res = await this.get(this.url(id, "stat", path), AbortSignal.timeout(META_TIMEOUT_MS))
    if (res.status === 404) return (await res.body?.cancel(), this.missing(id))
    const b = await this.json(res, "fs stat")
    const kind: FsKind = b.isSymlink === true ? "symlink" : b.isDirectory === true ? "directory" : b.isFile === true ? "file" : "other"
    const mode = typeof b.permissions === "string" && /^[0-7]{1,6}$/.test(b.permissions) ? parseInt(b.permissions, 8) & 0o7777 : kind === "directory" ? 0o755 : 0o644
    // Epoch seconds as a string while running, "" on a paused VM's disk (measured cx-lyvg).
    const at = typeof b.modified === "string" ? (/^\d{1,12}$/.test(b.modified) ? Number(b.modified) * 1000 : Date.parse(b.modified)) : NaN
    const size = typeof b.size === "number" && Number.isSafeInteger(b.size) && b.size >= 0 ? b.size : 0
    return { kind, size, mode, mtime: Number.isFinite(at) ? Math.floor(at / 1000) : 0, owner: typeof b.owner === "string" ? b.owner : "", group: typeof b.group === "string" ? b.group : "" }
  }

  async read(id: string, path: string, offset: number, signal: AbortSignal) {
    const res = await this.get(this.url(id, "read", path), signal, offset > 0 ? { range: `bytes=${offset}-` } : {})
    const ok = offset > 0 ? res.status === 206 : res.status === 200
    if (!ok || !res.body) {
      const body = (await res.json().catch(() => ({}))) as Record<string, unknown>
      if (res.status === 404) throw new DriverError("team_vm.vm_missing", "fs read: 404", true)
      throw this.failure(res.status, typeof body.code === "string" ? body.code : "", "fs read")
    }
    return res.body
  }
}
