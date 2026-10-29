/**
 * A cloud environment: what a new cloud workspace already has when it opens. Repo + setup script +
 * environment variables, nothing else (plans/cmux-next/cloud-environments-DESIGN.md). Pure values and
 * validation; no I/O. Runs in Workers (nodejs_compat) and Node: the digest is synchronous because
 * CloudDO's reducers are.
 */
import { createHash } from "node:crypto"

export interface EnvironmentRepo {
  readonly owner: string
  readonly name: string
  /** Branch, tag or full commit; null is the repository's default branch. */
  readonly ref: string | null
}

/** A plain variable is baked into the snapshot; a secret is only named (its value comes from the vault at boot). */
export type EnvironmentVariable = { readonly name: string; readonly value: string } | { readonly name: string; readonly secret: string }

export interface EnvironmentSpec {
  readonly name: string
  readonly repo: EnvironmentRepo | null
  readonly setupScript: string
  readonly env: ReadonlyArray<EnvironmentVariable>
}

export interface EnvironmentSpecError {
  readonly field: string
  readonly message: string
}

export const ENVIRONMENT_LIMITS = { nameChars: 80, setupScriptBytes: 64 * 1024, variables: 100, valueBytes: 32 * 1024 } as const

const OWNER = /^[A-Za-z0-9][A-Za-z0-9-]{0,38}$/
const REPO_NAME = /^[A-Za-z0-9._-]{1,100}$/
const REF = /^[A-Za-z0-9._/-]{1,200}$/
const VAR_NAME = /^[A-Za-z_][A-Za-z0-9_]{0,127}$/
const SECRET_NAME = /^[A-Za-z0-9._-]{1,128}$/
// Variables the machine owns: overriding them breaks the shell, the loader or cmux's guest integration.
const RESERVED_VARS: ReadonlySet<string> = new Set(["PATH", "HOME", "USER", "LOGNAME", "SHELL", "PWD", "TERM", "LD_PRELOAD", "LD_LIBRARY_PATH", "BASH_ENV", "ENV"])

type Parsed<T> = { readonly ok: true; readonly value: T } | { readonly ok: false; readonly error: EnvironmentSpecError }
const fail = (field: string, message: string): { ok: false; error: EnvironmentSpecError } => ({ ok: false, error: { field, message } })
const bytes = (text: string) => new TextEncoder().encode(text).byteLength
const REPO_FORMAT: EnvironmentSpecError = { field: "repo", message: "Enter a GitHub repository as owner/name or a GitHub URL." }

const supportedRef = (ref: string) => REF.test(ref) && !ref.startsWith("-") && !ref.includes("..") && !ref.endsWith("/") && !ref.endsWith(".lock")

const githubUrlPath = (raw: string): Parsed<{ path: string; ref: string | null }> => {
  let url: URL
  try {
    url = new URL(raw)
  } catch {
    return { ok: false, error: REPO_FORMAT }
  }
  if (url.username || url.password) return fail("repo", "Remove the username or password from the repository URL.")
  if (url.hostname.toLowerCase() !== "github.com") return fail("repo", "Only GitHub repositories are supported.")
  const path = url.pathname.replace(/^\/+|\/+$/g, "").replace(/\.git$/, "")
  const tree = path.match(/^([^/]+\/[^/]+)\/tree\/(.+)$/)
  return { ok: true, value: tree ? { path: tree[1]!, ref: tree[2]! } : { path, ref: null } }
}

/** `owner/name[@ref]` or a github.com URL; credentials in the URL are refused. */
export const parseEnvironmentRepo = (input: string): Parsed<EnvironmentRepo> => {
  const raw = input.trim()
  let path = raw
  let ref: string | null = null
  if (/^https?:\/\//i.test(raw)) {
    const parsed = githubUrlPath(raw)
    if (!parsed.ok) return parsed
    ;({ path, ref } = parsed.value)
  } else if (raw.lastIndexOf("@") > 0) {
    const at = raw.lastIndexOf("@")
    ref = raw.slice(at + 1)
    path = raw.slice(0, at)
  }
  const [owner, name, ...rest] = path.split("/")
  const validName = !!name && REPO_NAME.test(name) && name !== "." && name !== ".."
  if (!owner || !OWNER.test(owner) || !validName || rest.length > 0) return { ok: false, error: REPO_FORMAT }
  if (ref !== null && !supportedRef(ref)) return fail("repo", "The branch, tag, or commit name is not supported.")
  return { ok: true, value: { owner, name: name!, ref } }
}

/** The repo in the form a person types it back (`owner/name@ref`). */
export const formatEnvironmentRepo = (repo: EnvironmentRepo | null): string | null =>
  repo ? `${repo.owner}/${repo.name}${repo.ref ? `@${repo.ref}` : ""}` : null

const parseName = (value: unknown): Parsed<string> => {
  const name = typeof value === "string" ? value.trim() : ""
  const control = [...name].some((c) => c.charCodeAt(0) < 0x20)
  if (!name || name.length > ENVIRONMENT_LIMITS.nameChars || control) return fail("name", `Name must be 1-${ENVIRONMENT_LIMITS.nameChars} characters.`)
  return { ok: true, value: name }
}

const parseRepoField = (value: unknown): Parsed<EnvironmentRepo | null> => {
  if (value === undefined || value === null || value === "") return { ok: true, value: null }
  if (typeof value !== "string") return fail("repo", "Expected a string.")
  return parseEnvironmentRepo(value)
}

const parseSetupScript = (value: unknown): Parsed<string> => {
  const script = value ?? ""
  if (typeof script !== "string") return fail("setupScript", "Expected a string.")
  if (bytes(script) > ENVIRONMENT_LIMITS.setupScriptBytes) return fail("setupScript", "The setup script is over 64 KB.")
  if (script.includes("\u0000")) return fail("setupScript", "The setup script contains a NUL byte.")
  return { ok: true, value: script }
}

const parseVariable = (entry: unknown, seen: Set<string>): Parsed<EnvironmentVariable> => {
  if (!entry || typeof entry !== "object") return fail("env", "Each variable is an object.")
  const v = entry as Record<string, unknown>
  const name = v.name
  if (typeof name !== "string" || !VAR_NAME.test(name)) return fail("env", "Variable names are letters, digits and _, not starting with a digit.")
  if (RESERVED_VARS.has(name) || name.startsWith("CMUX_")) return fail("env", `${name} is owned by the machine.`)
  if (seen.has(name)) return fail("env", `${name} is listed twice.`)
  seen.add(name)
  if ((v.value !== undefined) === (v.secret !== undefined)) return fail("env", `${name} needs exactly one of value or secret.`)
  if (v.secret !== undefined) {
    return typeof v.secret === "string" && SECRET_NAME.test(v.secret) ? { ok: true, value: { name, secret: v.secret } } : fail("env", `${name} names an invalid secret.`)
  }
  const ok = typeof v.value === "string" && bytes(v.value) <= ENVIRONMENT_LIMITS.valueBytes && !v.value.includes("\u0000")
  return ok ? { ok: true, value: { name, value: v.value as string } } : fail("env", `${name} must be a string of at most 32 KB.`)
}

const parseVariables = (value: unknown): Parsed<Array<EnvironmentVariable>> => {
  const raw = value ?? []
  if (!Array.isArray(raw)) return fail("env", "Expected a list of variables.")
  if (raw.length > ENVIRONMENT_LIMITS.variables) return fail("env", `At most ${ENVIRONMENT_LIMITS.variables} variables.`)
  const seen = new Set<string>()
  const out: Array<EnvironmentVariable> = []
  for (const entry of raw) {
    const parsed = parseVariable(entry, seen)
    if (!parsed.ok) return parsed
    out.push(parsed.value)
  }
  return { ok: true, value: out }
}

/** Validates an untrusted body (`{ name, repo?, setupScript?, env? }`) into a spec. */
export const parseEnvironmentSpec = (input: unknown): { ok: true; spec: EnvironmentSpec } | { ok: false; error: EnvironmentSpecError } => {
  if (!input || typeof input !== "object" || Array.isArray(input)) return fail("body", "Expected a JSON object.")
  const body = input as Record<string, unknown>
  const name = parseName(body.name)
  if (!name.ok) return name
  const repo = parseRepoField(body.repo)
  if (!repo.ok) return repo
  const setupScript = parseSetupScript(body.setupScript)
  if (!setupScript.ok) return setupScript
  const env = parseVariables(body.env)
  if (!env.ok) return env
  return { ok: true, spec: { name: name.value, repo: repo.value, setupScript: setupScript.value, env: env.value } }
}

/** A spec back in its request shape, so an edit can merge fields over it and validate the whole. */
export const environmentSpecBody = (spec: EnvironmentSpec): Record<string, unknown> => ({
  name: spec.name,
  repo: formatEnvironmentRepo(spec.repo),
  setupScript: spec.setupScript,
  env: spec.env
})

/**
 * The identity of what a snapshot holds: every build input and the base image, not the display name
 * and not variable order. Equal digests mean a snapshot serves the spec; an edit to a build input or a
 * new base image makes it stale.
 */
export const environmentBuildDigest = (spec: EnvironmentSpec, baseImage: string): string => {
  const env = [...spec.env]
    .sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))
    .map((v) => ("value" in v ? ["v", v.name, v.value] : ["s", v.name, v.secret]))
  const canonical = JSON.stringify({ v: 1, baseImage, repo: spec.repo, setupScript: spec.setupScript, env })
  return createHash("sha256").update(canonical).digest("hex")
}
