import { SEMVER_PATTERN } from "@cmux/protocol"

/**
 * Minimal semver 2.0.0: parse, compare (prerelease ordering per spec section
 * 11) and ranges as cmux app manifests and installs use them: `*`, exact
 * `1.2.3`, `^1.2.3`, `~1.2.3`, `>=1.2.3`, `1.x`, `1.2.x`, and partial
 * `^1.2` / `~1`. A prerelease satisfies only a range that names the same
 * major.minor.patch with a prerelease (npm rule), so `*` never picks one.
 */
export interface SemVer {
  readonly major: number
  readonly minor: number
  readonly patch: number
  readonly pre: ReadonlyArray<string>
}

export const parseSemver = (v: string): SemVer | null => {
  const m = SEMVER_PATTERN.exec(v)
  if (!m) return null
  return { major: Number(m[1]), minor: Number(m[2]), patch: Number(m[3]), pre: m[4] ? m[4].split(".") : [] }
}

const cmpIdent = (a: string, b: string): number => {
  const an = /^\d+$/.test(a)
  const bn = /^\d+$/.test(b)
  if (an && bn) return Number(a) - Number(b)
  if (an) return -1
  if (bn) return 1
  return a < b ? -1 : a > b ? 1 : 0
}

export const compareSemver = (a: SemVer, b: SemVer): number => {
  if (a.major !== b.major) return a.major - b.major
  if (a.minor !== b.minor) return a.minor - b.minor
  if (a.patch !== b.patch) return a.patch - b.patch
  if (a.pre.length === 0 || b.pre.length === 0) return (a.pre.length === 0 ? 1 : 0) - (b.pre.length === 0 ? 1 : 0)
  for (let i = 0; i < Math.max(a.pre.length, b.pre.length); i++) {
    if (a.pre[i] === undefined) return -1
    if (b.pre[i] === undefined) return 1
    const c = cmpIdent(a.pre[i]!, b.pre[i]!)
    if (c !== 0) return c
  }
  return 0
}

export const compareVersions = (a: string, b: string): number => compareSemver(parseSemver(a)!, parseSemver(b)!)

interface Bound {
  readonly lo: SemVer
  readonly hi: SemVer | null
  readonly exact: boolean
}

const v = (major: number, minor: number, patch: number, pre: ReadonlyArray<string> = []): SemVer => ({ major, minor, patch, pre })

/** Parses a range into a half-open bound, or null when the range is not understood. */
const parseRange = (range: string): Bound | null => {
  const r = range.trim()
  if (r === "*" || r === "x" || r === "") return { lo: v(0, 0, 0), exact: false, hi: null }
  const op = /^(\^|~|>=)?\s*(.*)$/.exec(r)!
  const kind = op[1] ?? ""
  const body = op[2]!
  const parts = /^(0|[1-9]\d*)(?:\.(0|[1-9]\d*|x|\*))?(?:\.(0|[1-9]\d*|x|\*))?(?:-([0-9A-Za-z.-]+))?$/.exec(body)
  if (!parts) return null
  const major = Number(parts[1])
  const wild = (s: string | undefined) => s === undefined || s === "x" || s === "*"
  const minorWild = wild(parts[2])
  const patchWild = wild(parts[3])
  if (minorWild && !patchWild && parts[3] !== undefined) return null
  const minor = minorWild ? 0 : Number(parts[2])
  const patch = patchWild ? 0 : Number(parts[3])
  const pre = parts[4] && !patchWild ? parts[4].split(".") : []
  const lo = v(major, minor, patch, pre)
  if (kind === ">=") return { lo, exact: false, hi: null }
  if (kind === "^") {
    if (major > 0 || minorWild) return { lo, exact: false, hi: v(major + 1, 0, 0, ["0"]) }
    if (minor > 0 || patchWild) return { lo, exact: false, hi: v(0, minor + 1, 0, ["0"]) }
    return { lo, exact: false, hi: v(0, 0, patch + 1, ["0"]) }
  }
  if (kind === "~" || minorWild || patchWild) {
    if (minorWild) return { lo, exact: false, hi: v(major + 1, 0, 0, ["0"]) }
    return { lo, exact: false, hi: v(major, minor + 1, 0, ["0"]) }
  }
  // Exact.
  return { lo, hi: null, exact: true }
}

export const isValidRange = (range: string): boolean => parseRange(range) !== null

export const satisfies = (version: string, range: string): boolean => {
  const sv = parseSemver(version)
  const b = parseRange(range)
  if (!sv || !b) return false
  if (b.exact) return compareSemver(sv, b.lo) === 0
  if (sv.pre.length > 0) {
    // npm rule: a prerelease only matches a range whose lower bound is a prerelease of the same triple.
    if (b.lo.pre.length === 0 || sv.major !== b.lo.major || sv.minor !== b.lo.minor || sv.patch !== b.lo.patch) return false
  }
  if (compareSemver(sv, b.lo) < 0) return false
  return b.hi === null || compareSemver(sv, b.hi) < 0
}

/** Newest version in `versions` that satisfies `range`. */
export const maxSatisfying = (versions: Iterable<string>, range: string): string | null => {
  let best: string | null = null
  for (const ver of versions) if (satisfies(ver, range) && (best === null || compareVersions(ver, best) > 0)) best = ver
  return best
}
