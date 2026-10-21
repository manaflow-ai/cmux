import { DriverError, type TeamVmFiles, type FsKind, type FsStat } from "./team-vm-driver.ts"
import { teamApiFailure, type TeamVmApiRequest } from "./team-vm-api-request.ts"

const kind = (v: unknown): v is FsKind => v === "file" || v === "directory" || v === "symlink" || v === "other"

/** Saved-disk reads use only the file API: no start or guest exec, including on retired VMs. */
export class TeamVmApiFiles implements TeamVmFiles {
  constructor(private readonly api: TeamVmApiRequest) {}
  private async absent(id: string): Promise<null> {
    if (await this.api.presence(id) === "missing") throw new DriverError("team_vm.vm_missing", "the owned VM is physically missing", true)
    return null
  }
  async list(id: string, path: string) {
    const r = await this.api.request(() => this.api.client.GET("/v1/vms/{vmId}/files/entries", { params: { path: { vmId: id }, query: { path } } }))
    if (r.response.status === 404) return this.absent(id)
    const data = this.api.value(r)
    if (!Array.isArray(data.entries) || data.entries.some((e) => typeof e.name !== "string" || !kind(e.kind))) throw teamApiFailure("invalid file list")
    return data.entries
  }
  async stat(id: string, path: string): Promise<FsStat | null> {
    const r = await this.api.request(() => this.api.client.GET("/v1/vms/{vmId}/files/stat", { params: { path: { vmId: id }, query: { path } } }))
    if (r.response.status === 404) return this.absent(id)
    const v = this.api.value(r)
    if (!kind(v.kind) || !Number.isSafeInteger(v.size) || v.size < 0 || !Number.isInteger(v.mode) || v.mode < 0 || v.mode > 0o7777 ||
      (v.mtime !== null && (!Number.isSafeInteger(v.mtime) || v.mtime < 0)) || typeof v.owner !== "string" || typeof v.group !== "string") throw teamApiFailure("invalid file metadata")
    return { ...v, mtime: v.mtime ?? 0 }
  }
  async read(id: string, path: string, offset: number, signal: AbortSignal): Promise<ReadableStream<Uint8Array>> {
    if (!Number.isSafeInteger(offset) || offset < 0) throw teamApiFailure("invalid file offset", true)
    const r = await this.api.request(() => this.api.client.GET("/v1/vms/{vmId}/files/content", { parseAs: "stream", signal,
      params: { path: { vmId: id }, query: { path }, header: offset ? { range: `bytes=${offset}-` } : {} } }))
    if (r.response.status === 404) await this.api.missing(id)
    const body = this.api.value(r, offset ? 206 : 200)
    if (!body) throw teamApiFailure("empty file stream")
    if (offset && !r.response.headers.get("content-range")?.startsWith(`bytes ${offset}-`)) { await body.cancel(); throw teamApiFailure("unconfirmed file range") }
    return body
  }
}
