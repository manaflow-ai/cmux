import { importPKCS8, SignJWT } from "jose"

/**
 * code.storage client (decisions A12, C1): one repository per team holds the
 * code Chief writes (automations, later apps). Every call signs a short-lived
 * ES256 JWT scoped to one repository with WebCrypto through jose, so it runs in
 * workerd. The private key is a Worker secret and never leaves this module.
 * Docs: https://code.storage/docs/llms.txt (authentication, repos.commits.get,
 * repos.files.get). Repository creation and push tokens come with the CLI (slice 8).
 */

export interface CodeStorageEnv {
  readonly ENVIRONMENT: string
  /** The code.storage organization (the JWT `iss` and the API host's subdomain). */
  readonly CODE_STORAGE_ORG?: string
  /** Secret: PKCS#8 PEM of the organization's ES256 key. */
  readonly CODE_STORAGE_PRIVATE_KEY?: string
}

export type CodeStorageError =
  | { readonly code: "code.unavailable"; readonly message: string; readonly retryable: boolean }
  | { readonly code: "code.not_found"; readonly message: string; readonly retryable: false }
  | { readonly code: "code.too_large"; readonly message: string; readonly retryable: false }

/** Largest bundle a run loads (Dynamic Worker modules are held in memory). */
export const MAX_BUNDLE_BYTES = 5 * 1024 * 1024

export type CodeResult<T> = { readonly ok: true; readonly value: T } | ({ readonly ok: false } & CodeStorageError)

/** The fetch the client uses; tests replace it (the Worker passes the global fetch). */
export type HttpFetch = (input: string, init?: RequestInit) => Promise<Response>

const TOKEN_TTL_SECONDS = 300

/**
 * The one repository of a team in this environment. Staging and development
 * share an organization (decision A2), so the environment is part of the name;
 * the team id is the only other input, so no client value can name another team's repository.
 */
export const teamRepoName = (environment: string, team: string) => `cmux-${environment}-${team}`

export const codeStorageConfigured = (env: CodeStorageEnv) => Boolean(env.CODE_STORAGE_ORG && env.CODE_STORAGE_PRIVATE_KEY)

const keys = new Map<string, Promise<CryptoKey>>()
const signingKey = (pem: string) => {
  let k = keys.get(pem)
  if (!k) {
    k = importPKCS8(pem, "ES256")
    keys.set(pem, k)
  }
  return k
}

const token = async (env: CodeStorageEnv, repo: string, scopes: ReadonlyArray<"git:read" | "git:write" | "repo:write">) =>
  new SignJWT({ repo, scopes: [...scopes] })
    .setProtectedHeader({ alg: "ES256" })
    .setIssuer(env.CODE_STORAGE_ORG!)
    .setSubject("cmux-api")
    .setIssuedAt()
    .setExpirationTime(`${TOKEN_TTL_SECONDS}s`)
    .sign(await signingKey(env.CODE_STORAGE_PRIVATE_KEY!))

const apiBase = (env: CodeStorageEnv) => `https://api.${env.CODE_STORAGE_ORG}.code.storage/api`

const unavailable = (message: string, retryable: boolean): CodeResult<never> => ({ ok: false, code: "code.unavailable", message, retryable })

/** Problem-detail `code` of a code.storage error response (RFC 9457 body), when it has one. */
const problemCode = async (res: Response): Promise<string | undefined> => {
  try {
    const body = (await res.json()) as { code?: unknown }
    return typeof body.code === "string" ? body.code : undefined
  } catch {
    return undefined
  }
}

/** Maps a failed response: missing repository, ref or file is `code.not_found`; the rest is the service. */
const failure = async (res: Response, what: string): Promise<CodeResult<never>> => {
  const code = await problemCode(res)
  if (res.status === 404) return { ok: false, code: "code.not_found", message: `${what} not found (${code ?? "not_found"})`, retryable: false }
  const retryable = res.status === 429 || res.status >= 500 || code === "repository_thawing" || code === "authentication_unavailable"
  return unavailable(`code.storage ${res.status} ${code ?? ""} for ${what}`.trim(), retryable)
}

export class CodeStorage {
  constructor(
    private readonly env: CodeStorageEnv,
    private readonly http: HttpFetch = (input, init) => fetch(input, init)
  ) {}

  get configured() {
    return codeStorageConfigured(this.env)
  }

  private async call(repo: string, scopes: ReadonlyArray<"git:read" | "git:write" | "repo:write">, path: string, init: RequestInit = {}) {
    const headers = new Headers(init.headers)
    headers.set("authorization", `Bearer ${await token(this.env, repo, scopes)}`)
    return this.http(`${apiBase(this.env)}${path}`, { ...init, headers })
  }

  /** Resolves a full commit id in `repo` (code.storage `GET /repos/{repo}/commit?sha=`). */
  async commit(repo: string, sha: string): Promise<CodeResult<{ sha: string }>> {
    if (!this.configured) return unavailable("code storage is not configured on this deployment", false)
    try {
      const res = await this.call(repo, ["git:read"], `/repos/${encodeURIComponent(repo)}/commit?sha=${encodeURIComponent(sha)}`)
      if (!res.ok) return await failure(res, `commit ${sha}`)
      const body = (await res.json()) as { commit?: { sha?: unknown } }
      const got = body.commit?.sha
      // A prefix match or a moved ref must never pin a different commit than the caller named.
      if (got !== sha) return { ok: false, code: "code.not_found", message: `commit ${sha} not found`, retryable: false }
      return { ok: true, value: { sha } }
    } catch (e) {
      return unavailable(`code.storage unreachable: ${e instanceof Error ? e.name : "error"}`, true)
    }
  }

  /** Whether a file exists at an exact commit; reads one byte, not the file. */
  async hasFile(repo: string, commit: string, path: string): Promise<CodeResult<true>> {
    if (!this.configured) return unavailable("code storage is not configured on this deployment", false)
    try {
      const res = await this.call(repo, ["git:read"], `/repos/${encodeURIComponent(repo)}/file?path=${encodeURIComponent(path)}&ref=${encodeURIComponent(commit)}`, { headers: { range: "bytes=0-0" } })
      await res.body?.cancel()
      // 416: the file exists but is empty (no byte 0); an empty bundle still exists.
      if (res.ok || res.status === 416) return { ok: true, value: true }
      return await failure(res, `${path} at ${commit}`)
    } catch (e) {
      return unavailable(`code.storage unreachable: ${e instanceof Error ? e.name : "error"}`, true)
    }
  }


  /** One file at an exact commit, as text; refused above `maxBytes`. */
  async file(repo: string, commit: string, path: string, maxBytes = MAX_BUNDLE_BYTES): Promise<CodeResult<{ text: string }>> {
    if (!this.configured) return unavailable("code storage is not configured on this deployment", false)
    try {
      const res = await this.call(repo, ["git:read"], `/repos/${encodeURIComponent(repo)}/file?path=${encodeURIComponent(path)}&ref=${encodeURIComponent(commit)}`)
      if (!res.ok) return await failure(res, `${path} at ${commit}`)
      const length = Number(res.headers.get("content-length") ?? "0")
      const tooLarge = { ok: false as const, code: "code.too_large" as const, message: `${path} is larger than ${maxBytes} bytes`, retryable: false as const }
      if (length > maxBytes) {
        await res.body?.cancel()
        return tooLarge
      }
      const bytes = new Uint8Array(await res.arrayBuffer())
      if (bytes.byteLength > maxBytes) return tooLarge
      return { ok: true, value: { text: new TextDecoder().decode(bytes) } }
    } catch (e) {
      return unavailable(`code.storage unreachable: ${e instanceof Error ? e.name : "error"}`, true)
    }
  }
}
