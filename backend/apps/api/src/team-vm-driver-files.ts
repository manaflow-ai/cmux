import type { SqlStore } from "@cmux/ownership"
import { DriverError, type FsKind, type FsStat, type TeamVmFiles } from "./team-vm-driver.ts"

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

/**
 * Test files for FakeDriver: one row per path in the DO's SQLite (`fake_fs`). `cut_once` ends the
 * next read of that file with an error after that many bytes (a provider stream that broke), and
 * `stat_size` makes stat report another size than the stored bytes (a huge file without the bytes).
 */
export class FakeFiles implements TeamVmFiles {
  constructor(private readonly sql: SqlStore) {
    sql.exec(`CREATE TABLE IF NOT EXISTS fake_fs (vm TEXT NOT NULL, path TEXT NOT NULL, kind TEXT NOT NULL, data BLOB, mode INTEGER NOT NULL, stat_size INTEGER, cut_once INTEGER, PRIMARY KEY (vm, path))`)
    sql.exec(`CREATE TABLE IF NOT EXISTS fake_fs_reads (n INTEGER NOT NULL)`)
  }

  /** Test only: writes a file or symlink (and its parent directories) into `vm`. */
  put(vm: string, path: string, data: Uint8Array | string, opts: { kind?: "file" | "symlink"; mode?: number; stat_size?: number; cut_once?: number } = {}) {
    const parts = path.split("/").filter(Boolean)
    for (let i = 1; i < parts.length; i++) this.sql.exec(`INSERT OR IGNORE INTO fake_fs (vm, path, kind, data, mode) VALUES (?, ?, 'directory', NULL, 493)`, vm, `/${parts.slice(0, i).join("/")}`)
    const bytes = typeof data === "string" ? new TextEncoder().encode(data) : data
    this.sql.exec(`INSERT OR REPLACE INTO fake_fs (vm, path, kind, data, mode, stat_size, cut_once) VALUES (?, ?, ?, ?, ?, ?, ?)`, vm, `/${parts.join("/")}`, opts.kind ?? "file", bytes, opts.mode ?? 0o644, opts.stat_size ?? null, opts.cut_once ?? null)
  }

  /** Test only: an empty directory. */
  mkdir(vm: string, path: string) {
    this.put(vm, `${path}/.x`, "")
    this.sql.exec(`DELETE FROM fake_fs WHERE vm = ? AND path = ?`, vm, `${path}/.x`)
  }

  /** Test only: how many reads ran (each is one provider request). */
  reads(): number {
    return this.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM fake_fs_reads`)[0]!.n
  }

  private vmExists(vm: string) {
    if (!this.sql.exec(`SELECT 1 FROM fake_vm WHERE id = ?`, vm)[0]) throw new DriverError("team_vm.vm_missing", "fs: VM 404", true)
  }

  async list(vm: string, path: string) {
    this.vmExists(vm)
    if (!this.sql.exec(`SELECT 1 FROM fake_fs WHERE vm = ? AND path = ? AND kind = 'directory'`, vm, path)[0]) return null
    // substr, not LIKE: the DO's SQLite refuses long LIKE patterns.
    const prefix = `${path}/`
    const rows = this.sql.exec<{ path: string; kind: string }>(`SELECT path, kind FROM fake_fs WHERE vm = ? AND substr(path, 1, ?) = ?`, vm, prefix.length, prefix)
    return rows.filter((r) => !r.path.slice(path.length + 1).includes("/")).map((r) => ({ name: r.path.slice(path.length + 1), kind: kindOf(r.kind) }))
  }

  async stat(vm: string, path: string): Promise<FsStat | null> {
    this.vmExists(vm)
    const r = this.sql.exec<{ kind: string; data: ArrayBuffer | null; mode: number; stat_size: number | null }>(`SELECT kind, data, mode, stat_size FROM fake_fs WHERE vm = ? AND path = ?`, vm, path)[0]
    if (!r) return null
    return { kind: kindOf(r.kind), size: r.stat_size ?? (r.data ? r.data.byteLength : 0), mode: r.mode, mtime: 1_800_000_000, owner: "cmux", group: "cmux" }
  }

  async read(vm: string, path: string, offset: number, _signal: AbortSignal) {
    this.vmExists(vm)
    this.sql.exec(`INSERT INTO fake_fs_reads (n) VALUES (1)`)
    const r = this.sql.exec<{ data: ArrayBuffer | null; cut_once: number | null }>(`SELECT data, cut_once FROM fake_fs WHERE vm = ? AND path = ? AND kind = 'file'`, vm, path)[0]
    if (!r) throw new DriverError("team_vm.vm_missing", "fs read: 404", true)
    const bytes = new Uint8Array(r.data ?? new ArrayBuffer(0)).slice(offset)
    const cut = r.cut_once
    if (cut !== null) this.sql.exec(`UPDATE fake_fs SET cut_once = NULL WHERE vm = ? AND path = ?`, vm, path)
    return new ReadableStream<Uint8Array>({
      start(ctl) {
        if (cut === null) {
          // Two chunks, so a reader sees a stream rather than one buffer.
          const mid = Math.floor(bytes.length / 2)
          if (mid > 0) ctl.enqueue(bytes.slice(0, mid))
          if (bytes.length > mid) ctl.enqueue(bytes.slice(mid))
          ctl.close()
        } else {
          if (cut > 0) ctl.enqueue(bytes.slice(0, cut))
          ctl.error(new Error("fake stream cut"))
        }
      }
    })
  }
}
