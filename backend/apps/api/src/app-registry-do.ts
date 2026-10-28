import { DurableObject } from "cloudflare:workers"
import { compareSemver, displayText, encodeBase64, type CheckedSubmission, type Refusal } from "./app-registry-bundle.ts"
import type { Env } from "./env.ts"

/**
 * AppRegistryDO (custom-panes-DESIGN.md 6.1): one SQLite object, `idFromName("global")`, the
 * only copy of the app registry: publishers, submissions with their files, and the audit. Every
 * stateful rule of 6.3 runs here inside one synchronous transaction, so two submits cannot both
 * claim a publisher or both be pending. An approved submission is never written again.
 *
 * File bytes are stored in parts of at most PART bytes (a SQLite row holds at most 2 MB).
 */
const PART = 512 * 1024
const PAGE = 50

export type SubmissionStatus = "pending" | "approved" | "rejected"
export type Submission = {
  readonly id: string
  readonly app: string
  readonly version: string
  readonly status: SubmissionStatus
  readonly sha256: string
  readonly size: number
  readonly manifest: Record<string, unknown>
  readonly notes: string | null
  readonly submitter: string
  readonly submitted_at: number
  readonly decided_by: string | null
  readonly decided_at: number | null
  readonly reason: string | null
}
export type Listing = { app: string; name: string; description: string; publisher: string; version: string; sha256: string; size: number; approved_at: number; manifest: Record<string, unknown> }
export type Result<T> = { ok: true; value: T } | { ok: false; refusal: Refusal }

type Row = Record<string, SqlStorageValue>
const no = (status: number, code: string, message: string): { ok: false; refusal: Refusal } => ({ ok: false, refusal: { status, code, message } })

const toSubmission = (r: Row): Submission => ({
  id: String(r.id),
  app: String(r.app),
  version: String(r.version),
  status: String(r.status) as SubmissionStatus,
  sha256: String(r.sha256),
  size: Number(r.size),
  manifest: JSON.parse(String(r.manifest)) as Record<string, unknown>,
  notes: r.notes === null ? null : String(r.notes),
  submitter: String(r.submitter),
  submitted_at: Number(r.submitted_at),
  decided_by: r.decided_by === null ? null : String(r.decided_by),
  decided_at: r.decided_at === null ? null : Number(r.decided_at),
  reason: r.reason === null ? null : String(r.reason)
})

const randomId = () => `sub_${[...crypto.getRandomValues(new Uint8Array(10))].map((b) => b.toString(16).padStart(2, "0")).join("")}`

export class AppRegistryDO extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    const sql = ctx.storage.sql
    sql.exec(`CREATE TABLE IF NOT EXISTS publishers (publisher TEXT PRIMARY KEY, user TEXT NOT NULL, created_at INTEGER NOT NULL)`)
    sql.exec(
      `CREATE TABLE IF NOT EXISTS submissions (id TEXT PRIMARY KEY, app TEXT NOT NULL, version TEXT NOT NULL, status TEXT NOT NULL, sha256 TEXT NOT NULL, size INTEGER NOT NULL, manifest TEXT NOT NULL, notes TEXT, submitter TEXT NOT NULL, submitted_at INTEGER NOT NULL, decided_by TEXT, decided_at INTEGER, reason TEXT)`
    )
    sql.exec(`CREATE UNIQUE INDEX IF NOT EXISTS submissions_one_pending ON submissions (app) WHERE status = 'pending'`)
    sql.exec(`CREATE UNIQUE INDEX IF NOT EXISTS submissions_approved_version ON submissions (app, version) WHERE status = 'approved'`)
    sql.exec(`CREATE INDEX IF NOT EXISTS submissions_submitter ON submissions (submitter, submitted_at)`)
    sql.exec(`CREATE TABLE IF NOT EXISTS files (submission TEXT NOT NULL, path TEXT NOT NULL, part INTEGER NOT NULL, bytes BLOB NOT NULL, PRIMARY KEY (submission, path, part))`)
    sql.exec(`CREATE TABLE IF NOT EXISTS audit (at INTEGER NOT NULL, actor TEXT NOT NULL, action TEXT NOT NULL, submission TEXT, detail TEXT)`)
  }

  private audit(actor: string, action: string, submission: string | null, detail: Record<string, unknown>): void {
    this.ctx.storage.sql.exec(`INSERT INTO audit (at, actor, action, submission, detail) VALUES (?, ?, ?, ?, ?)`, Date.now(), actor, action, submission, JSON.stringify(detail))
  }

  private submission(id: string): Submission | undefined {
    const r = this.ctx.storage.sql.exec<Row>(`SELECT * FROM submissions WHERE id = ?`, id).toArray()[0]
    return r ? toSubmission(r) : undefined
  }

  private fileList(id: string): Array<{ path: string; size: number }> {
    return this.ctx.storage.sql
      .exec<{ path: string; size: number }>(`SELECT path, SUM(length(bytes)) AS size FROM files WHERE submission = ? GROUP BY path ORDER BY path`, id)
      .toArray()
      .map((r) => ({ path: String(r.path), size: Number(r.size) }))
  }

  private fileBytes(id: string, path: string): Uint8Array | undefined {
    const parts = this.ctx.storage.sql.exec<{ bytes: ArrayBuffer }>(`SELECT bytes FROM files WHERE submission = ? AND path = ? ORDER BY part`, id, path).toArray()
    if (parts.length === 0) return undefined
    const chunks = parts.map((p) => new Uint8Array(p.bytes))
    const out = new Uint8Array(chunks.reduce((n, c) => n + c.length, 0))
    let at = 0
    for (const c of chunks) {
      out.set(c, at)
      at += c.length
    }
    return out
  }

  async me(user: string): Promise<{ publishers: Array<string> }> {
    return { publishers: this.ctx.storage.sql.exec<{ publisher: string }>(`SELECT publisher FROM publishers WHERE user = ? ORDER BY publisher`, user).toArray().map((r) => String(r.publisher)) }
  }

  /** The stateful submit rules: publisher owner, one pending per app, version above every pending or approved one. */
  async submit(user: string, s: CheckedSubmission): Promise<Result<Submission>> {
    const sql = this.ctx.storage.sql
    const now = Date.now()
    const id = randomId()
    return this.ctx.storage.transactionSync((): Result<Submission> => {
      const owner = sql.exec<{ user: string }>(`SELECT user FROM publishers WHERE publisher = ?`, s.publisher).toArray()[0]
      if (owner && owner.user !== user) return no(403, "registry.publisher_taken", `the publisher "${s.publisher}" belongs to another person`)
      const live = sql.exec<{ version: string; status: string }>(`SELECT version, status FROM submissions WHERE app = ? AND status IN ('pending', 'approved')`, s.app).toArray()
      if (live.some((r) => r.status === "pending")) return no(409, "registry.pending_exists", `${s.app} already has a submission waiting for review`)
      const top = live.map((r) => String(r.version)).sort(compareSemver).at(-1)
      if (top !== undefined && compareSemver(s.version, top) <= 0) return no(409, "registry.version_order", `version ${s.version} must be greater than ${top}`)
      if (!owner) {
        sql.exec(`INSERT INTO publishers (publisher, user, created_at) VALUES (?, ?, ?)`, s.publisher, user, now)
        this.audit(user, "publisher.claim", null, { publisher: s.publisher })
      }
      sql.exec(
        `INSERT INTO submissions (id, app, version, status, sha256, size, manifest, notes, submitter, submitted_at) VALUES (?, ?, ?, 'pending', ?, ?, ?, ?, ?, ?)`,
        id,
        s.app,
        s.version,
        s.sha256,
        s.size,
        JSON.stringify(s.manifest),
        s.notes,
        user,
        now
      )
      for (const f of s.files) {
        const parts = Math.max(1, Math.ceil(f.bytes.length / PART))
        for (let p = 0; p < parts; p++) sql.exec(`INSERT INTO files (submission, path, part, bytes) VALUES (?, ?, ?, ?)`, id, f.path, p, f.bytes.slice(p * PART, (p + 1) * PART).buffer)
      }
      this.audit(user, "submit", id, { app: s.app, version: s.version, sha256: s.sha256, size: s.size, files: s.files.length })
      return { ok: true, value: this.submission(id)! }
    })
  }

  async mine(user: string): Promise<Array<Submission>> {
    return this.ctx.storage.sql.exec<Row>(`SELECT * FROM submissions WHERE submitter = ? ORDER BY submitted_at DESC`, user).toArray().map(toSubmission)
  }

  /** Not `queue`: that name is the queue consumer handler of a Durable Object, not an RPC method. */
  async reviewQueue(): Promise<Array<Submission & { files: Array<{ path: string; size: number }> }>> {
    return this.ctx.storage.sql
      .exec<Row>(`SELECT * FROM submissions WHERE status = 'pending' ORDER BY submitted_at`)
      .toArray()
      .map((r) => {
        const s = toSubmission(r)
        return { ...s, files: this.fileList(s.id) }
      })
  }

  async file(id: string, path: string): Promise<{ path: string; base64: string } | null> {
    if (!this.submission(id)) return null
    const bytes = this.fileBytes(id, path)
    return bytes ? { path, base64: encodeBase64(bytes) } : null
  }

  /** Decides a pending submission; never the reviewer's own. Audited. */
  async decide(reviewer: string, id: string, decision: "approve" | "reject", reason: string | null): Promise<Result<Submission>> {
    const sql = this.ctx.storage.sql
    return this.ctx.storage.transactionSync((): Result<Submission> => {
      const s = this.submission(id)
      if (!s) return no(404, "registry.not_found", "no such submission")
      if (s.status !== "pending") return no(409, "registry.decided", `this submission is already ${s.status}`)
      if (s.submitter === reviewer) return no(403, "registry.own_submission", "a reviewer never decides their own submission")
      const status = decision === "approve" ? "approved" : "rejected"
      sql.exec(`UPDATE submissions SET status = ?, decided_by = ?, decided_at = ?, reason = ? WHERE id = ? AND status = 'pending'`, status, reviewer, Date.now(), reason, id)
      this.audit(reviewer, decision, id, { app: s.app, version: s.version, sha256: s.sha256, ...(reason ? { reason } : {}) })
      return { ok: true, value: this.submission(id)! }
    })
  }

  private approved(app?: string): Array<Submission> {
    const sql = this.ctx.storage.sql
    const rows = app ? sql.exec<Row>(`SELECT * FROM submissions WHERE status = 'approved' AND app = ?`, app) : sql.exec<Row>(`SELECT * FROM submissions WHERE status = 'approved'`)
    return rows.toArray().map(toSubmission)
  }

  /** Approved apps with their latest approved version, ordered by app id; `cursor` is the last app id of the previous page. */
  async listings(query: string, cursor: string): Promise<{ listings: Array<Listing>; cursor?: string }> {
    const latest = new Map<string, Submission>()
    for (const s of this.approved()) {
      const have = latest.get(s.app)
      if (!have || compareSemver(s.version, have.version) > 0) latest.set(s.app, s)
    }
    const q = query.trim().toLowerCase()
    const all = [...latest.values()]
      .map((s): Listing => ({ app: s.app, name: displayText(s.manifest.name), description: displayText(s.manifest.description), publisher: s.app.split("/")[0]!, version: s.version, sha256: s.sha256, size: s.size, approved_at: s.decided_at ?? 0, manifest: s.manifest }))
      .filter((l) => !q || l.app.includes(q) || l.name.toLowerCase().includes(q) || l.description.toLowerCase().includes(q))
      .filter((l) => !cursor || l.app > cursor)
      .sort((a, b) => (a.app < b.app ? -1 : a.app > b.app ? 1 : 0))
    const page = all.slice(0, PAGE)
    return all.length > PAGE ? { listings: page, cursor: page.at(-1)!.app } : { listings: page }
  }

  async app(app: string): Promise<{ app: string; latest: string; versions: Array<{ version: string; sha256: string; size: number; approved_at: number; notes: string | null }> } | null> {
    const versions = this.approved(app).sort((a, b) => compareSemver(b.version, a.version))
    if (versions.length === 0) return null
    return { app, latest: versions[0]!.version, versions: versions.map((s) => ({ version: s.version, sha256: s.sha256, size: s.size, approved_at: s.decided_at ?? 0, notes: s.notes })) }
  }

  /** The files of an approved version only. */
  async bundle(app: string, version: string): Promise<{ app: string; version: string; sha256: string; files: Record<string, string> } | null> {
    const s = this.approved(app).find((v) => v.version === version)
    if (!s) return null
    // No prototype: a file may be named `__proto__`, which `{}` would swallow.
    const files: Record<string, string> = Object.create(null) as Record<string, string>
    for (const f of this.fileList(s.id)) files[f.path] = encodeBase64(this.fileBytes(s.id, f.path)!)
    return { app, version, sha256: s.sha256, files }
  }
}
