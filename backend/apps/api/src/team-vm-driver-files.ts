import type { SqlStore } from "@cmux/ownership"
import { DriverError, type FsKind, type FsStat, type TeamVmFiles } from "./team-vm-driver.ts"

const kindOf = (v: unknown): FsKind => (v === "file" || v === "directory" || v === "symlink" ? v : "other")

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
