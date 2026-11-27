import type { SqlStore } from "@cmux/ownership"
import { DriverError, type TeamVmDriver } from "./team-vm-driver.ts"
import { padding, TAR_END, tarHeader, tarLength, type TarEntry } from "./tar.ts"
import type { TeamVmRetired } from "./domains/team-vm-taint.ts"

/**
 * team_vm.retired.export (cx-lyvg): the team files (/srv/team) of a VM a rebuild retired, as one tar
 * download. A retired VM is fenced (run budget spent, paused; cx-009a), so nothing in it runs and
 * its files cannot change; the provider's file API still reads its disk. Nothing here starts,
 * resumes or changes the VM: only fs list, stat and read calls.
 *
 * Two steps. The op (TeamDO role check and audit, then here) walks the tree once with list and
 * stat, refuses what is over the limits, and stores the manifest under a single-use ticket. The
 * download (`GET /v1/team-vm/export/<team>/<ticket>`, no bearer: a browser download cannot send
 * one) takes the ticket and streams the tar from the stored manifest: one provider read per file,
 * piped chunk by chunk, so the Worker holds one chunk at a time, never the archive. The tar length
 * is known from the manifest, so the response has a Content-Length and a short stream fails
 * visibly instead of saving a cut archive.
 *
 * Why streaming and not R2: the only bucket is the Home attachments bucket (another owner and
 * retention), and an R2 copy would need the same streaming plus a second store with its own
 * deletion. A frozen VM is the archive's source of truth already.
 */
export const EXPORT_ROOT = "/srv/team"
/** The archive's top directory. */
export const ARCHIVE_ROOT = "team"

export const EXPORT_LIMITS = {
  /**
   * File bytes: 2 GiB. A browser download of that size finishes in minutes, ustar sizes stay far
   * under their 8 GiB field, and the stream time limit below holds it at about 1.2 MB/s.
   */
  maxBytes: 2 * 1024 ** 3,
  /** Files, directories and skipped entries. Each costs one provider request in the walk and one in the download; Workers allow 10,000 per request. */
  maxEntries: 5000,
  /** The walk's time limit (the op answers within it). */
  planMs: 60_000,
  /** Parallel list/stat requests during the walk. */
  concurrency: 8,
  /** The download's time limit: a stream still open after 30 minutes is cut (the browser shows a failed download). */
  streamMs: 30 * 60_000,
  /** One read with no new bytes for this long is retried from where it stopped. */
  stallMs: 60_000,
  /** Attempts per file (a broken provider stream resumes with a Range request). */
  readAttempts: 3,
  /** The ticket is valid this long, for one download. */
  ticketMs: 5 * 60_000
} as const

export type ExportLimits = typeof EXPORT_LIMITS

type Fail = { readonly ok: false; readonly code: string; readonly message: string }
export type Plan = { readonly ok: true; readonly entries: ReadonlyArray<TarEntry>; readonly bytes: number; readonly files: number; readonly skipped: ReadonlyArray<string> } | Fail

const fail = (code: string, message: string): Fail => ({ ok: false, code, message })
const SAFE_NAME = (n: string) => n.length > 0 && n !== "." && n !== ".." && !n.includes("/") && !n.includes("\0")

/** Walks EXPORT_ROOT on `vm` (list and stat only) into a sorted manifest, or the refusal. */
export const planExport = async (driver: TeamVmDriver, vm: string, limits: ExportLimits = EXPORT_LIMITS, now: () => number = Date.now): Promise<Plan> => {
  const deadline = now() + limits.planMs
  const entries: Array<TarEntry> = [{ path: ARCHIVE_ROOT, kind: "dir", size: 0, mode: 0o755, mtime: Math.floor(now() / 1000) }]
  const skipped: Array<string> = []
  let bytes = 0
  let dirs = [""]
  while (dirs.length > 0) {
    const next: Array<string> = []
    for (let i = 0; i < dirs.length; i += limits.concurrency) {
      if (now() > deadline) return fail("team_vm.export_timeout", "listing the team files took too long; try again")
      const lists = await Promise.all(dirs.slice(i, i + limits.concurrency).map(async (rel) => ({ rel, items: await driver.files.list(vm, rel ? `${EXPORT_ROOT}/${rel}` : EXPORT_ROOT) })))
      const files: Array<string> = []
      for (const { rel, items } of lists) {
        if (items === null) {
          if (rel === "") return fail("team_vm.export_no_files", `this VM has no ${EXPORT_ROOT}`)
          continue
        }
        for (const it of items) {
          const path = rel ? `${rel}/${it.name}` : it.name
          if (!SAFE_NAME(it.name) || `${EXPORT_ROOT}/${path}`.length > 4000) skipped.push(path)
          else if (it.kind === "directory") next.push(path)
          else if (it.kind === "file") files.push(path)
          else skipped.push(path)
        }
      }
      if (entries.length + next.length + files.length + skipped.length > limits.maxEntries) return fail("team_vm.export_too_large", `the team files have more than ${limits.maxEntries} entries`)
      for (let j = 0; j < files.length; j += limits.concurrency) {
        if (now() > deadline) return fail("team_vm.export_timeout", "listing the team files took too long; try again")
        const stats = await Promise.all(files.slice(j, j + limits.concurrency).map(async (path) => ({ path, st: await driver.files.stat(vm, `${EXPORT_ROOT}/${path}`) })))
        for (const { path, st } of stats) {
          // A file that vanished between list and stat cannot happen on a fenced VM; skip it anyway.
          if (!st || st.kind !== "file") {
            skipped.push(path)
            continue
          }
          bytes += st.size
          if (bytes > limits.maxBytes) return fail("team_vm.export_too_large", `the team files are larger than ${limits.maxBytes} bytes`)
          // A paused VM's disk answers no modification time (measured cx-lyvg): the export time stands in.
          entries.push({ path: `${ARCHIVE_ROOT}/${path}`, kind: "file", size: st.size, mode: st.mode, mtime: st.mtime || Math.floor(now() / 1000), uname: st.owner, gname: st.group })
        }
      }
    }
    for (const d of next) entries.push({ path: `${ARCHIVE_ROOT}/${d}`, kind: "dir", size: 0, mode: 0o755, mtime: Math.floor(now() / 1000) })
    dirs = next
  }
  entries.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0))
  return { ok: true, entries, bytes, files: entries.filter((e) => e.kind === "file").length, skipped: skipped.sort() }
}

const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("")
const TICKET = /^[0-9a-f]{64}$/
export const isTicket = (t: string) => TICKET.test(t)

/** Single-use download tickets and their manifests, in TeamVmDO's SQLite. Only the ticket's SHA-256 is stored. */
export class ExportTickets {
  constructor(private readonly sql: SqlStore) {
    sql.exec(`CREATE TABLE IF NOT EXISTS team_vm_export (ticket TEXT PRIMARY KEY, vm TEXT NOT NULL, by TEXT NOT NULL, expires_at INTEGER NOT NULL, total INTEGER NOT NULL)`)
    sql.exec(`CREATE TABLE IF NOT EXISTS team_vm_export_entry (ticket TEXT NOT NULL, seq INTEGER NOT NULL, entry TEXT NOT NULL, PRIMARY KEY (ticket, seq))`)
  }

  private sweep(now: number) {
    this.sql.exec(`DELETE FROM team_vm_export_entry WHERE ticket IN (SELECT ticket FROM team_vm_export WHERE expires_at <= ?)`, now)
    this.sql.exec(`DELETE FROM team_vm_export WHERE expires_at <= ?`, now)
  }

  async mint(vm: string, by: string, entries: ReadonlyArray<TarEntry>, expiresAt: number, now: number): Promise<{ ticket: string; total: number }> {
    this.sweep(now)
    const ticket = hex(crypto.getRandomValues(new Uint8Array(32)).buffer as ArrayBuffer)
    const key = hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(ticket)))
    const total = tarLength(entries)
    this.sql.exec(`INSERT INTO team_vm_export (ticket, vm, by, expires_at, total) VALUES (?, ?, ?, ?, ?)`, key, vm, by, expiresAt, total)
    entries.forEach((e, i) => this.sql.exec(`INSERT INTO team_vm_export_entry (ticket, seq, entry) VALUES (?, ?, ?)`, key, i, JSON.stringify(e)))
    return { ticket, total }
  }

  /** Takes (and so ends) a valid ticket: its VM, manifest and archive length, or null. */
  async take(ticket: string, now: number): Promise<{ vm: string; entries: Array<TarEntry>; total: number } | null> {
    if (!isTicket(ticket)) return null
    const key = hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(ticket)))
    const row = this.sql.exec<{ vm: string; expires_at: number; total: number }>(`SELECT vm, expires_at, total FROM team_vm_export WHERE ticket = ?`, key)[0]
    const entries = row ? this.sql.exec<{ entry: string }>(`SELECT entry FROM team_vm_export_entry WHERE ticket = ? ORDER BY seq`, key).map((r) => JSON.parse(r.entry) as TarEntry) : []
    this.sql.exec(`DELETE FROM team_vm_export_entry WHERE ticket = ?`, key)
    this.sql.exec(`DELETE FROM team_vm_export WHERE ticket = ?`, key)
    this.sweep(now)
    return row && row.expires_at > now ? { vm: row.vm, entries, total: row.total } : null
  }
}

/** Why a retired row may not be read now, or null: only a paused row with the fence confirmed (the VM can never run again). */
export const exportRefusal = (row: TeamVmRetired | undefined): Fail | null => {
  if (!row) return fail("selector.not_found", "no retired team VM with this id")
  if (row.state !== "paused" || row.fenced !== true) return fail("team_vm.retired_not_fenced", "the retired VM is not fenced yet (paused with its run budget spent); try again in a few minutes")
  return null
}

/** Reads one file into the writer from `offset`, resuming a broken provider stream with a Range request. */
const copyFile = async (driver: TeamVmDriver, vm: string, e: TarEntry, w: WritableStreamDefaultWriter<Uint8Array>, deadline: number, limits: ExportLimits) => {
  const source = `${EXPORT_ROOT}/${e.path.slice(ARCHIVE_ROOT.length + 1)}`
  let sent = 0
  for (let attempt = 1; sent < e.size; attempt++) {
    const ctl = new AbortController()
    try {
      const body = await driver.files.read(vm, source, sent, AbortSignal.any([ctl.signal, AbortSignal.timeout(Math.max(1, deadline - Date.now()))]))
      const reader = body.getReader()
      for (;;) {
        let stall: ReturnType<typeof setTimeout> | undefined
        const chunk = await Promise.race([reader.read(), new Promise<never>((_, reject) => (stall = setTimeout(() => reject(new Error("read stalled")), limits.stallMs)))]).finally(() => clearTimeout(stall))
        if (chunk.done) break
        if (sent + chunk.value.byteLength > e.size) throw new DriverError("team_vm.export_changed", `fs read: ${e.path} is longer than its stat`, true)
        await w.write(chunk.value)
        sent += chunk.value.byteLength
      }
      if (sent < e.size) throw new DriverError("team_vm.export_changed", `fs read: ${e.path} is shorter than its stat`, true)
    } catch (err) {
      ctl.abort()
      const final = err instanceof DriverError && err.final
      if (final || attempt >= limits.readAttempts || Date.now() > deadline) throw err
    }
  }
}

/** The download: the tar of `entries` streamed from `vm`, bounded by the stream time limit. */
export const exportResponse = (driver: TeamVmDriver, vm: string, entries: ReadonlyArray<TarEntry>, total: number, limits: ExportLimits = EXPORT_LIMITS): Response => {
  const { readable, writable } = new FixedLengthStream(total)
  const w = writable.getWriter()
  const deadline = Date.now() + limits.streamMs
  const run = async () => {
    for (const e of entries) {
      await w.write(tarHeader(e))
      if (e.kind !== "file") continue
      if (e.size > 0) await copyFile(driver, vm, e, w, deadline, limits)
      const pad = padding(e.size)
      if (pad > 0) await w.write(new Uint8Array(pad))
    }
    await w.write(TAR_END)
    await w.close()
  }
  run().catch(async (err: unknown) => {
    // A cut stream: the length check makes the browser report a failed download, never a short archive saved as complete.
    console.warn(JSON.stringify({ msg: "team vm export stream failed", vm, error: err instanceof DriverError ? `${err.code} ${err.message}` : String(err).slice(0, 200) }))
    await w.abort(err).catch(() => undefined)
  })
  const name = `cmux-team-files-${vm.replace(/[^A-Za-z0-9._-]/g, "_").slice(0, 80)}.tar`
  return new Response(readable, {
    headers: { "content-type": "application/x-tar", "content-disposition": `attachment; filename="${name}"`, "cache-control": "private, no-store", "x-content-type-options": "nosniff", "referrer-policy": "no-referrer" }
  })
}
