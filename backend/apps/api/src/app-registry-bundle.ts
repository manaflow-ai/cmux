/**
 * The app registry's pure rules (custom-panes-DESIGN.md 6.2 and 6.3): the bundle hash, safe
 * paths, semver order and the submission checks that need no stored state. AppRegistryDO adds
 * the stateful rules (publisher owner, version order, one pending per app).
 */

export const MAX_FILES = 200
export const MAX_DECODED_BYTES = 2 * 1024 * 1024
export const MAX_PATH = 256
export const MAX_NOTES = 2000
export const RESERVED_PUBLISHERS: ReadonlySet<string> = new Set(["cmux", "manaflow-ai", "local"])
/** The manifest's id pattern (schema/v2/cmux-app.schema.json), without the `local` alternative. */
export const PUBLISHER = /^[a-z0-9][a-z0-9-]{0,38}$/
export const APP_NAME = /^[a-z0-9][a-z0-9-]{0,63}$/
export const SEMVER = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/
/** The package's manifest file: the v2 name first, else the v1 name (app-platform.md). */
export const MANIFEST_FILES = ["cmux-app.v2.json", "cmux-app.json"] as const

/**
 * Directives a manifest's `runtime.web.csp` may use, the daemon's list (cmux-app-manifest
 * rules.rs `CSP_DIRECTIVES`): it is sent beside the host's policy, so fetch directives only
 * narrow it, while `report-uri`, `report-to` or `navigate-to` could name a URL the page's data
 * is sent to.
 */
const CSP_DIRECTIVES = new Set([
  "default-src", "script-src", "script-src-elem", "script-src-attr", "style-src", "style-src-elem", "style-src-attr",
  "img-src", "font-src", "connect-src", "media-src", "object-src", "frame-src", "child-src", "worker-src",
  "manifest-src", "base-uri", "form-action", "sandbox",
])

/** The first directive of `csp` that is not allowed, or null. */
export const cspRefusedDirective = (csp: string): string | null => {
  for (const directive of csp.split(/[;,]/)) {
    const name = directive.trim().split(/\s+/)[0]?.toLowerCase() ?? ""
    if (name && !CSP_DIRECTIVES.has(name)) return name
  }
  return null
}

const utf8 = new TextEncoder()

const compareBytes = (a: Uint8Array, b: Uint8Array): number => {
  const n = Math.min(a.length, b.length)
  for (let i = 0; i < n; i++) if (a[i] !== b[i]) return a[i]! - b[i]!
  return a.length - b.length
}

/**
 * sha256 over every file in ascending byte order of its UTF-8 path, each as
 * `path || 0x00 || decimal byte length || 0x00 || bytes`, lowercase hex (6.2).
 */
export const bundleHash = async (files: ReadonlyArray<{ readonly path: string; readonly bytes: Uint8Array }>): Promise<string> => {
  const sorted = files.map((f) => ({ key: utf8.encode(f.path), bytes: f.bytes })).sort((a, b) => compareBytes(a.key, b.key))
  const parts: Array<Uint8Array> = []
  for (const f of sorted) parts.push(f.key, new Uint8Array([0]), utf8.encode(String(f.bytes.length)), new Uint8Array([0]), f.bytes)
  const total = parts.reduce((n, p) => n + p.length, 0)
  const all = new Uint8Array(total)
  let at = 0
  for (const p of parts) {
    all.set(p, at)
    at += p.length
  }
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", all))
  return [...digest].map((b) => b.toString(16).padStart(2, "0")).join("")
}

const SEGMENT = /^[A-Za-z0-9._@+-]+$/

/** A relative path of plain segments: no leading slash, no `.` or `..`, no backslash or control characters. */
export const safePath = (path: string): boolean => {
  if (path.length === 0 || path.length > MAX_PATH) return false
  return path.split("/").every((s) => SEGMENT.test(s) && s !== "." && s !== "..")
}

const BASE64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/

export const decodeBase64 = (s: string): Uint8Array | null => {
  if (!BASE64.test(s)) return null
  const bin = atob(s)
  const out = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
  return out
}

export const encodeBase64 = (bytes: Uint8Array): string => {
  let bin = ""
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
  return btoa(bin)
}

/** Exact precedence of nonnegative decimal identifiers, even beyond Number.MAX_SAFE_INTEGER. */
const compareDecimalIdentifiers = (a: string, b: string): number => {
  // Numeric prerelease identifiers cannot have leading zeroes in valid SemVer;
  // normalize them defensively because the current input regex also accepts those strings.
  const left = a.replace(/^0+(?=\d)/, "")
  const right = b.replace(/^0+(?=\d)/, "")
  if (left.length !== right.length) return left.length < right.length ? -1 : 1
  return left < right ? -1 : left > right ? 1 : 0
}

/** Semver precedence (semver.org 11): build metadata is ignored. Inputs must match SEMVER. */
export const compareSemver = (a: string, b: string): number => {
  const pa = SEMVER.exec(a)!
  const pb = SEMVER.exec(b)!
  for (let i = 1; i <= 3; i++) {
    const d = compareDecimalIdentifiers(pa[i]!, pb[i]!)
    if (d !== 0) return d
  }
  const ra = pa[4]
  const rb = pb[4]
  if (ra === undefined || rb === undefined) return ra === rb ? 0 : ra === undefined ? 1 : -1
  const xa = ra.split(".")
  const xb = rb.split(".")
  for (let i = 0; i < Math.min(xa.length, xb.length); i++) {
    const x = xa[i]!
    const y = xb[i]!
    if (x === y) continue
    const nx = /^\d+$/.test(x)
    const ny = /^\d+$/.test(y)
    if (nx && ny) {
      const d = compareDecimalIdentifiers(x, y)
      if (d !== 0) return d
      continue
    }
    if (nx !== ny) return nx ? -1 : 1
    return x < y ? -1 : 1
  }
  return Math.sign(xa.length - xb.length)
}

/** JSON with object keys sorted, so two parses compare equal regardless of key order. */
export const canonicalJson = (v: unknown): string => {
  if (Array.isArray(v)) return `[${v.map(canonicalJson).join(",")}]`
  if (v && typeof v === "object") {
    const o = v as Record<string, unknown>
    return `{${Object.keys(o)
      .sort()
      .map((k) => `${JSON.stringify(k)}:${canonicalJson(o[k])}`)
      .join(",")}}`
  }
  return JSON.stringify(v)
}

/** A manifest text field (a string or a localized object with `en`) as one display string. */
export const displayText = (v: unknown): string => (typeof v === "string" ? v : v && typeof v === "object" && typeof (v as { en?: unknown }).en === "string" ? (v as { en: string }).en : "")

const textOk = (v: unknown): boolean => {
  if (typeof v === "string") return v.length >= 1 && v.length <= 300
  if (!v || typeof v !== "object" || Array.isArray(v)) return false
  const o = v as Record<string, unknown>
  return typeof o.en === "string" && Object.values(o).every((s) => typeof s === "string" && s.length >= 1 && s.length <= 300)
}

export type BundleFile = { readonly path: string; readonly bytes: Uint8Array }
export type CheckedSubmission = {
  readonly app: string
  readonly publisher: string
  readonly name: string
  readonly version: string
  readonly manifest: Record<string, unknown>
  readonly files: ReadonlyArray<BundleFile>
  readonly sha256: string
  readonly size: number
  readonly notes: string | null
}
export type Refusal = { readonly status: number; readonly code: string; readonly message: string }

const refuse = (status: number, code: string, message: string): { ok: false; refusal: Refusal } => ({ ok: false, refusal: { status, code, message } })

/** Every submit rule that needs no stored state (6.3), and the bundle hash. */
export const checkSubmission = async (body: unknown): Promise<{ ok: true; value: CheckedSubmission } | { ok: false; refusal: Refusal }> => {
  if (!body || typeof body !== "object" || Array.isArray(body)) return refuse(400, "registry.invalid", "a JSON object {manifest, files, notes?} is required")
  const { manifest, files, notes } = body as { manifest?: unknown; files?: unknown; notes?: unknown }
  if (!manifest || typeof manifest !== "object" || Array.isArray(manifest)) return refuse(400, "registry.manifest", "manifest must be an object")
  const m = manifest as Record<string, unknown>
  if (m.manifestVersion !== 2) return refuse(400, "registry.manifest", "manifestVersion must be 2")
  const id = typeof m.id === "string" ? m.id : ""
  const slash = id.indexOf("/")
  const publisher = slash > 0 ? id.slice(0, slash) : ""
  const name = slash > 0 ? id.slice(slash + 1) : ""
  if (!PUBLISHER.test(publisher) || !APP_NAME.test(name)) return refuse(400, "registry.manifest", "manifest id must be <publisher>/<name>")
  if (RESERVED_PUBLISHERS.has(publisher)) return refuse(403, "registry.publisher_reserved", `the publisher "${publisher}" is reserved`)
  const version = typeof m.version === "string" ? m.version : ""
  if (!SEMVER.test(version)) return refuse(400, "registry.manifest", "manifest version must be semver")
  if (!textOk(m.name) || !textOk(m.description)) return refuse(400, "registry.manifest", "manifest name and description are required (1 to 300 characters)")
  // The daemon's manifest rule (cmux-app-manifest rules.rs): a store app names a GitHub
  // repository whose owner is its publisher, or its bundle never installs.
  const repository = typeof m.repository === "string" ? m.repository : ""
  const owner = repository.startsWith("https://github.com/") ? (repository.split("/")[3] ?? "").toLowerCase() : ""
  if (owner !== publisher) return refuse(400, "registry.repository", `repository must be https://github.com/${publisher}/<repo>`)
  const web = (m.runtime as { web?: { csp?: unknown } } | undefined)?.web
  const refused = typeof web?.csp === "string" ? cspRefusedDirective(web.csp) : null
  if (refused) return refuse(400, "registry.csp", `${refused} is not allowed in runtime.web.csp; use fetch directives only`)
  if (notes !== undefined && notes !== null && (typeof notes !== "string" || notes.length > MAX_NOTES)) return refuse(400, "registry.notes", `notes must be a string of at most ${MAX_NOTES} characters`)
  if (!files || typeof files !== "object" || Array.isArray(files)) return refuse(400, "registry.files", "files must be an object {path: base64}")
  const entries = Object.entries(files as Record<string, unknown>)
  if (entries.length === 0 || entries.length > MAX_FILES) return refuse(413, "registry.too_many_files", `a bundle has 1 to ${MAX_FILES} files`)
  const decoded: Array<BundleFile> = []
  const folded = new Set<string>()
  let size = 0
  for (const [path, b64] of entries) {
    if (!safePath(path)) return refuse(400, "registry.path", `unsafe path: ${JSON.stringify(path.slice(0, MAX_PATH))}`)
    // Paths that differ only in case would collide on a case-insensitive disk.
    const key = path.toLowerCase()
    if (folded.has(key)) return refuse(400, "registry.path", `duplicate path (ignoring case): ${path}`)
    folded.add(key)
    if (typeof b64 !== "string") return refuse(400, "registry.files", `file ${path} must be base64`)
    size += Math.floor((b64.length * 3) / 4)
    if (size > MAX_DECODED_BYTES + 2) return refuse(413, "registry.too_large", `a bundle is at most ${MAX_DECODED_BYTES} bytes decoded`)
    const bytes = decodeBase64(b64)
    if (!bytes) return refuse(400, "registry.files", `file ${path} is not valid base64`)
    decoded.push({ path, bytes })
  }
  const total = decoded.reduce((n, f) => n + f.bytes.length, 0)
  if (total > MAX_DECODED_BYTES) return refuse(413, "registry.too_large", `a bundle is at most ${MAX_DECODED_BYTES} bytes decoded`)
  // A path that is also a directory of another path cannot be written.
  for (const f of decoded) if (decoded.some((g) => g.path.toLowerCase().startsWith(`${f.path.toLowerCase()}/`))) return refuse(400, "registry.path", `${f.path} is both a file and a directory`)
  // The daemon's catalog reads cmux-app.json when both exist, and a Mac disk ignores case: one
  // manifest file, named in lowercase, so the reviewer approves the manifest that installs.
  const manifestLike = decoded.filter((f) => (MANIFEST_FILES as ReadonlyArray<string>).includes(f.path.toLowerCase()))
  if (manifestLike.length > 1 || manifestLike.some((f) => !(MANIFEST_FILES as ReadonlyArray<string>).includes(f.path))) {
    return refuse(400, "registry.manifest_file", "a bundle has one manifest file, named in lowercase")
  }
  const manifestFile = MANIFEST_FILES.map((p) => decoded.find((f) => f.path === p)).find(Boolean)
  if (!manifestFile) return refuse(400, "registry.manifest_file", `the bundle must contain ${MANIFEST_FILES.join(" or ")}`)
  let parsed: unknown
  try {
    parsed = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(manifestFile.bytes))
  } catch {
    return refuse(400, "registry.manifest_file", `${manifestFile.path} is not valid JSON`)
  }
  if (canonicalJson(parsed) !== canonicalJson(m)) return refuse(400, "registry.manifest_mismatch", `${manifestFile.path} does not equal manifest`)
  return { ok: true, value: { app: id, publisher, name, version, manifest: m, files: decoded, sha256: await bundleHash(decoded), size: total, notes: typeof notes === "string" && notes.trim() ? notes.trim() : null } }
}
