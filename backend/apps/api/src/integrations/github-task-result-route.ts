import type { Principal } from "@cmux/ownership"
import type { Env } from "../env.ts"
import { githubCaller } from "./github-token-route.ts"

/**
 * The cloud task-result boundary publishes a task commit and asks the existing
 * `cmux-next-media` workflow to capture it by adding `media-tour`. The workflow
 * owns the capture runner, signed artifact URLs and PR media publication; this
 * Worker only performs the authenticated GitHub operation that starts it.
 */
export const GITHUB_TASK_RESULT_PATH = "/v1/integrations/github/task-result"
const NO_STORE = { "cache-control": "no-store" }
const fail = (status: number, code: string, message: string) => Response.json({ error: { code, message } }, { status, headers: NO_STORE })
const identifier = (value: unknown) => typeof value === "string" && /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(value)
const taskId = (value: unknown) => typeof value === "string" && /^task_[A-Za-z0-9_-]{8,120}$/.test(value)
const sha = (value: unknown) => typeof value === "string" && /^[0-9a-f]{40}$/.test(value)
const repo = (value: unknown) => typeof value === "string" && /^[A-Za-z0-9_.-]{1,100}\/[A-Za-z0-9_.-]{1,100}$/.test(value)
const ref = (value: unknown) => typeof value === "string" && value.length > 0 && value.length <= 200 && !value.startsWith("-") && !value.startsWith("/") && !value.endsWith("/") && !value.endsWith(".") && !value.includes("..") && !/[\x00-\x20\x7f~^:?*[\\]/.test(value) && value.split("/").every((part) => part.length > 0 && !part.startsWith(".") && !part.endsWith(".lock"))
const title = (value: unknown) => typeof value === "string" && value.trim().length > 0 && value.length <= 256 && !/[\x00-\x1f\x7f]/.test(value)

type TokenReply = { ok: true; value: { token: string } } | { ok: false; status: number; code: string; message: string }
type Connections = { githubToken(entity: string, principal: Principal, ask: { repo: string; permissions: Record<string, "read" | "write">; machine?: string }): Promise<TokenReply> }
type GithubFile = { filename?: unknown; status?: unknown; additions?: unknown; deletions?: unknown; previous_filename?: unknown }

const connections = (env: Env, team: string) => env.CONNECTION_DO.get(env.CONNECTION_DO.idFromName(team)) as unknown as Connections
const encodedRepo = (repository: string) => repository.split("/").map(encodeURIComponent).join("/")

const jsonValue = async (response: Response): Promise<unknown> => {
  const length = Number(response.headers.get("content-length") ?? "0")
  if (Number.isFinite(length) && length > 2 * 1024 * 1024) return null
  const reader = response.body?.getReader()
  if (!reader) return null
  const chunks: Uint8Array[] = []
  let size = 0
  try {
    while (true) {
      const next = await reader.read()
      if (next.done) break
      size += next.value.byteLength
      if (size > 2 * 1024 * 1024) {
        await reader.cancel()
        return null
      }
      chunks.push(next.value)
    }
  } finally {
    reader.releaseLock()
  }
  const bytes = new Uint8Array(size)
  let offset = 0
  for (const chunk of chunks) {
    bytes.set(chunk, offset)
    offset += chunk.byteLength
  }
  let value: unknown
  try {
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)) as unknown
  } catch {
    return null
  }
  return value
}
const jsonBody = async (response: Response) => {
  const value = await jsonValue(response)
  return value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null
}
const jsonList = async (response: Response) => {
  const value = await jsonValue(response)
  return Array.isArray(value) ? value : null
}

export async function handleGithubTaskResult(request: Request, env: Env): Promise<Response> {
  if (request.method !== "POST") return fail(405, "request.invalid", "POST")
  const body = await request.json().catch(() => undefined) as Record<string, unknown> | undefined
  if (!body || typeof body !== "object" || !taskId(body.taskId) || !identifier(body.machineId) || (body.connectionId !== undefined && (typeof body.connectionId !== "string" || !/^conn_[a-z0-9]{20}$/.test(body.connectionId))) || !repo(body.repository) || !ref(body.baseRef) || !sha(body.commitSha) || !title(body.title) || typeof body.openPullRequest !== "boolean" || !identifier(body.idempotencyKey)) {
    return fail(400, "request.invalid", "invalid task result request")
  }
  const repository = body.repository as string
  const team = typeof body.team === "string" ? body.team : undefined
  if (team === undefined) return fail(400, "request.invalid", "team is required")
  const who = await githubCaller(request, env, team)
  if ("status" in who) return fail(who.status, who.code, who.message)
  if (who.machine !== undefined && who.machine !== body.machineId) return fail(403, "auth.forbidden", "the VM may publish only its own machine task")
  const tokenResult = await connections(env, who.team).githubToken(who.team, who.p, { repo: repository, machine: who.machine, permissions: { contents: "write", pull_requests: "write", issues: "write" } }).catch(() => null)
  if (tokenResult === null) return fail(503, "integration.unavailable", "the team's GitHub connection could not be reached")
  if (!tokenResult.ok) return fail(tokenResult.status, tokenResult.code, tokenResult.message)
  const token = tokenResult.value.token
  const api = async (path: string, init: RequestInit = {}) => fetch(`https://api.github.com${path}`, { ...init, headers: { accept: "application/vnd.github+json", "x-github-api-version": "2022-11-28", "user-agent": "cmux-cloud-task-result", authorization: `Bearer ${token}`, ...(init.headers ?? {}) } })
  const encoded = encodedRepo(repository)
  const branch = `cmux-task/${body.taskId as string}`
  const branchPath = `/repos/${encoded}/git/ref/heads/${encodeURIComponent(branch)}`
  const existingRef = await api(branchPath).catch(() => null)
  if (existingRef === null) return fail(503, "integration.unavailable", "GitHub did not answer; retry")
  const existing = existingRef.ok ? await jsonBody(existingRef) : null
  if (existingRef.ok && existing?.object && (existing.object as Record<string, unknown>).sha !== body.commitSha) return fail(409, "task_result.idempotency_conflict", "the task branch already points at another commit")
  if (!existingRef.ok && existingRef.status !== 404) return fail(existingRef.status === 403 ? 403 : 503, existingRef.status === 403 ? "auth.forbidden" : "integration.unavailable", "GitHub refused the task branch")
  if (!existingRef.ok) {
    const created = await api(`/repos/${encoded}/git/refs`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ ref: `refs/heads/${branch}`, sha: body.commitSha }) }).catch(() => null)
    if (created === null) return fail(503, "integration.unavailable", "GitHub did not answer; retry")
    if (!created.ok && created.status !== 422) return fail(created.status === 403 ? 403 : 503, created.status === 403 ? "auth.forbidden" : "integration.unavailable", "GitHub refused the task branch")
    if (!created.ok) {
      const concurrent = await api(branchPath).catch(() => null)
      const concurrentBody = concurrent?.ok ? await jsonBody(concurrent) : null
      if (!concurrent?.ok || (concurrentBody?.object && (concurrentBody.object as Record<string, unknown>).sha !== body.commitSha)) return fail(409, "task_result.idempotency_conflict", "the task branch was concurrently created at another commit")
    }
  }
  let pr: Record<string, unknown> | undefined
  if (body.openPullRequest) {
    const pulls = await api(`/repos/${encoded}/pulls?state=open&head=${encodeURIComponent(repository.split("/")[0]! + ":" + branch)}&per_page=10`).catch(() => null)
    if (pulls === null) return fail(503, "integration.unavailable", "GitHub did not answer; retry")
    const pullBody = pulls.ok ? await jsonList(pulls) : null
    const pullValues = Array.isArray(pullBody) ? pullBody : []
    pr = pullValues.find((value) => value && typeof value === "object" && typeof (value as Record<string, unknown>).number === "number") as Record<string, unknown> | undefined
    if (!pr) {
      const opened = await api(`/repos/${encoded}/pulls`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ title: body.title, head: branch, base: body.baseRef, body: `Cloud task ${body.taskId as string}.` }) }).catch(() => null)
      if (opened === null) return fail(503, "integration.unavailable", "GitHub did not answer; retry")
      if (opened.status === 422) {
        // A concurrent retry may have opened it. Read once by head and continue idempotently.
        const retry = await api(`/repos/${encoded}/pulls?state=open&head=${encodeURIComponent(repository.split("/")[0]! + ":" + branch)}&per_page=10`).catch(() => null)
        const retryBody = retry?.ok ? await jsonList(retry) : null
        const values = Array.isArray(retryBody) ? retryBody : []
        pr = values.find((value) => value && typeof value === "object" && typeof (value as Record<string, unknown>).number === "number") as Record<string, unknown> | undefined
      } else if (opened.ok) pr = await jsonBody(opened) ?? undefined
    }
    if (!pr || typeof pr.number !== "number" || typeof pr.html_url !== "string") return fail(503, "integration.unavailable", "GitHub did not return the task pull request")
  }
  const number = typeof pr?.number === "number" ? pr.number : undefined
  // The existing capture workflow is scoped to cmux NEXT PRs. Other repositories still get
  // normal task publication, with an explicit unsupported proof state rather than a misleading
  // queued label that no workflow can consume.
  const label = number === undefined || repository.toLowerCase() !== "manaflow-ai/cmux" ? null : await api(`/repos/${encoded}/issues/${number}/labels`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ labels: ["media-tour"] }) }).catch(() => null)
  const proof = number === undefined ? undefined : repository.toLowerCase() !== "manaflow-ai/cmux" ? { status: "unsupported" as const } : label?.ok ? { status: "queued" as const, trigger: "media-tour" as const } : { status: "unavailable" as const }
  const compare = await api(`/repos/${encoded}/compare/${encodeURIComponent(body.baseRef as string)}...${encodeURIComponent(branch)}`).catch(() => null)
  if (compare === null || !compare.ok) return fail(503, "integration.unavailable", "GitHub could not compare the task branch; retry")
  const compared = await jsonBody(compare)
  if (!compared || typeof compared.base_commit !== "object" || compared.base_commit === null || typeof (compared.base_commit as Record<string, unknown>).sha !== "string") return fail(503, "integration.unavailable", "GitHub returned no task base commit")
  const files = Array.isArray(compared?.files) ? compared.files as GithubFile[] : []
  const normalized = files.flatMap((file) => {
    if (typeof file.filename !== "string" || !["added", "modified", "removed", "renamed", "copied", "changed"].includes(String(file.status))) return []
    const status = String(file.status) === "removed" ? "deleted" : String(file.status) as "added" | "modified" | "renamed" | "copied" | "changed"
    return [{ path: file.filename, status, additions: typeof file.additions === "number" ? file.additions : 0, deletions: typeof file.deletions === "number" ? file.deletions : 0 }]
  })
  const baseSha = (compared.base_commit as Record<string, unknown>).sha as string
  return Response.json({ repository, branch, baseSha, headSha: body.commitSha, diff: { filesChanged: typeof compared.changed_files === "number" ? compared.changed_files : normalized.length, additions: typeof compared.additions === "number" ? compared.additions : normalized.reduce((n, f) => n + f.additions, 0), deletions: typeof compared.deletions === "number" ? compared.deletions : normalized.reduce((n, f) => n + f.deletions, 0), truncated: false, files: normalized }, pullRequest: number === undefined ? null : { number, url: pr!.html_url as string }, ...(proof === undefined ? {} : { proof }) }, { headers: NO_STORE })
}
