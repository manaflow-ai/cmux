import { Type, type Static } from "@earendil-works/pi-ai"
import type { ToolRegistration } from "@earendil-works/pi-durable"
import type { Env } from "../env.ts"
import { githubOf } from "../chief-brain-cc/github.ts"
import { effectRefusal } from "./effect-policy.ts"

/**
 * The Chief's `code` tool: code search, file reads and git history of a GitHub repository with no machine.
 * Searching code and reading `git log` need only the repository, not a sandbox: on 2026-11-27 the cmux Slack bot
 * could not start a sandbox twice (Freestyle 429 "infrastructure overloaded") and answered from docs only. This
 * path is four GitHub REST calls from the Worker with the Chief's own GitHub login (chief-brain-cc/github.ts),
 * so it never waits on provider capacity. Read only: it never writes to GitHub.
 *
 * - search: GitHub code search (the repository's default branch; words, "quoted phrases", path:, language:).
 * - read: a file (or a directory listing) at any ref, numbered lines from `start`.
 * - log: commits at a ref, optionally of one path; with `query`, a commit message search.
 * - show: one commit's message, files and patch.
 */
const Args = Type.Object({
  action: Type.Union([Type.Literal("search"), Type.Literal("read"), Type.Literal("log"), Type.Literal("show")]),
  repo: Type.String({ description: "owner/name, e.g. manaflow-ai/cmux" }),
  query: Type.Optional(Type.String({ description: "search: code search terms; log: words of commit messages" })),
  path: Type.Optional(Type.String({ description: "read: the file or directory; log: commits touching it; search: limits to it" })),
  ref: Type.Optional(Type.String({ description: "read/log: branch, tag or sha (default: the default branch)" })),
  sha: Type.Optional(Type.String({ description: "show: the commit" })),
  start: Type.Optional(Type.Integer({ description: "read: first line (default 1)" })),
  lines: Type.Optional(Type.Integer({ description: "read: how many lines (default 200, at most 400)" })),
  n: Type.Optional(Type.Integer({ description: "search/log: how many results (default 20, at most 50)" }))
})
export type CodeArgs = Static<typeof Args>

export const CODE_DESCRIPTION =
  "Read a GitHub repository with no machine (never waits for a sandbox): search (code search on the default branch), read (a file or directory at any ref, numbered lines), log (commits at a ref or of a path; query searches commit messages), show (one commit's files and patch). Use it for code and git history questions before starting a sandbox."

const API = "https://api.github.com"
const REPO = /^[A-Za-z0-9_.-]{1,100}\/[A-Za-z0-9_.-]{1,100}$/
const REF = /^[A-Za-z0-9._\/-]{1,200}$/
const OUT_MAX = 40_000

/** One GitHub GET: path is below api.github.com; accept is the media type. */
export type GithubGet = (path: string, accept: string) => Promise<Response | null>

const clip = (s: string, max = OUT_MAX) => (s.length > max ? `${s.slice(0, max)}\n… (${s.length - max} more characters)` : s)
const bound = (v: number | undefined, d: number, lo: number, hi: number) => (typeof v === "number" && Number.isInteger(v) ? Math.min(hi, Math.max(lo, v)) : d)
const cleanPath = (p: string | undefined) => (p ?? "").trim().replace(/^\/+/, "").replace(/\/+$/, "")
const encPath = (p: string) => p.split("/").map(encodeURIComponent).join("/")

const failure = async (what: string, res: Response | null): Promise<string> => {
  if (!res) return `code error: ${what}: GitHub did not answer`
  const body = (await res.json().catch(() => null)) as { message?: string } | null
  const limited = res.status === 403 && res.headers.get("x-ratelimit-remaining") === "0"
  const hint = res.status === 404 ? " (no such repository, path or ref, or this Chief's GitHub login cannot see it)" : res.status === 401 ? " (this Chief's GitHub login is not valid; the owner signs it in again)" : limited ? " (GitHub rate limit; try again in a minute)" : ""
  return `code error: ${what}: GitHub ${res.status}${body?.message ? ` ${String(body.message).slice(0, 200)}` : ""}${hint}`
}

/** The tool's work, on any GitHub GET (the tests give a fake one). */
export const codeProgram = async (a: CodeArgs, get: GithubGet): Promise<string> => {
  const repo = String(a.repo ?? "").trim()
  if (!REPO.test(repo) || repo.includes("..")) return "code error: repo must be owner/name"
  const path = cleanPath(a.path)
  if (path.split("/").some((s) => s === "..")) return "code error: path must not contain .."
  const ref = a.ref?.trim() || undefined
  if (ref !== undefined && !REF.test(ref)) return "code error: ref is a branch, tag or sha"
  const n = bound(a.n, 20, 1, 50)
  const query = (a.query ?? "").replace(/[\u0000-\u001f\u007f]/g, " ").trim().slice(0, 256)

  if (a.action === "search") {
    if (!query) return "code error: search needs query"
    const q = `${query} repo:${repo}${path ? ` path:${path}` : ""}`
    const res = await get(`/search/code?q=${encodeURIComponent(q)}&per_page=${n}`, "application/vnd.github.text-match+json")
    if (!res?.ok) return failure("search", res)
    const body = (await res.json().catch(() => null)) as { total_count?: number; items?: Array<{ path?: string; text_matches?: Array<{ fragment?: string }> }> } | null
    const items = body?.items ?? []
    if (!items.length) return `no matches for ${JSON.stringify(query)} in ${repo} (code search covers the default branch; read and log take any ref)`
    const out = items.map((it) => {
      const frags = (it.text_matches ?? []).slice(0, 2).map((m) => `    ${String(m.fragment ?? "").replace(/\s*\n\s*/g, " ⏎ ").slice(0, 300)}`)
      return [it.path ?? "?", ...frags].join("\n")
    })
    return clip(`${body?.total_count ?? items.length} matches in ${repo} (default branch); first ${items.length}:\n${out.join("\n")}`)
  }

  if (a.action === "read") {
    if (!path) return "code error: read needs path"
    const res = await get(`/repos/${repo}/contents/${encPath(path)}${ref ? `?ref=${encodeURIComponent(ref)}` : ""}`, "application/vnd.github.raw+json")
    if (!res?.ok) return failure("read", res)
    const type = res.headers.get("content-type") ?? ""
    const text = await res.text().catch(() => "")
    // A directory answers its listing as JSON even when raw is asked.
    if (type.includes("json") && text.startsWith("[")) {
      const list = (JSON.parse(text) as Array<{ name?: string; type?: string }>).map((e) => `${e.name}${e.type === "dir" ? "/" : ""}`)
      return clip(`${repo}/${path}${ref ? ` @ ${ref}` : ""} (directory, ${list.length} entries):\n${list.join("\n")}`)
    }
    const all = text.split("\n")
    const start = bound(a.start, 1, 1, Math.max(1, all.length))
    const count = bound(a.lines, 200, 1, 400)
    const shown = all.slice(start - 1, start - 1 + count).map((l, i) => `${start + i}\t${l}`)
    return clip(`${repo}/${path}${ref ? ` @ ${ref}` : ""}: lines ${start}-${start + shown.length - 1} of ${all.length}\n${shown.join("\n")}`)
  }

  if (a.action === "log") {
    type Commit = { sha?: string; commit?: { message?: string; author?: { name?: string; date?: string } } }
    const line = (c: Commit) => `${String(c.sha ?? "").slice(0, 10)} ${String(c.commit?.author?.date ?? "").slice(0, 16)} ${c.commit?.author?.name ?? "?"}: ${String(c.commit?.message ?? "").split("\n")[0]!.slice(0, 160)}`
    if (query) {
      const res = await get(`/search/commits?q=${encodeURIComponent(`${query} repo:${repo}`)}&sort=committer-date&order=desc&per_page=${n}`, "application/vnd.github+json")
      if (!res?.ok) return failure("log", res)
      const items = ((await res.json().catch(() => null)) as { items?: Array<Commit> } | null)?.items ?? []
      return items.length ? clip(`commits of ${repo} whose message matches ${JSON.stringify(query)}:\n${items.map(line).join("\n")}`) : `no commit of ${repo} matches ${JSON.stringify(query)}`
    }
    const qs = [`per_page=${n}`, ref ? `sha=${encodeURIComponent(ref)}` : "", path ? `path=${encodeURIComponent(path)}` : ""].filter(Boolean).join("&")
    const res = await get(`/repos/${repo}/commits?${qs}`, "application/vnd.github+json")
    if (!res?.ok) return failure("log", res)
    const items = ((await res.json().catch(() => null)) as Array<Commit> | null) ?? []
    return items.length ? clip(`git log ${repo}${ref ? ` ${ref}` : ""}${path ? ` -- ${path}` : ""}:\n${items.map(line).join("\n")}`) : "no commits"
  }

  if (a.action === "show") {
    const sha = a.sha?.trim() ?? ""
    if (!REF.test(sha)) return "code error: show needs sha"
    const res = await get(`/repos/${repo}/commits/${encodeURIComponent(sha)}`, "application/vnd.github+json")
    if (!res?.ok) return failure("show", res)
    const c = (await res.json().catch(() => null)) as { sha?: string; commit?: { message?: string; author?: { name?: string; date?: string } }; files?: Array<{ filename?: string; additions?: number; deletions?: number; patch?: string }> } | null
    const files = c?.files ?? []
    const head = `${c?.sha ?? sha} ${c?.commit?.author?.name ?? "?"} ${c?.commit?.author?.date ?? ""}\n${c?.commit?.message ?? ""}\n\n${files.map((f) => `${f.filename} +${f.additions ?? 0} -${f.deletions ?? 0}`).join("\n")}`
    return clip(`${head}\n\n${files.map((f) => (f.patch ? `--- ${f.filename}\n${f.patch}` : "")).filter(Boolean).join("\n")}`)
  }
  return "code error: action is search, read, log or show"
}

/** A GitHub GET with the Chief's own login (none: unauthenticated, which reads public repositories only). */
const githubGet = (token: string | null): GithubGet => (path, accept) =>
  fetch(`${API}${path}`, {
    headers: { accept, "user-agent": "cmux-chief", "x-github-api-version": "2022-11-28", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    redirect: "follow",
    signal: AbortSignal.timeout(20_000)
  }).catch(() => null)

/** The `code` tool of a Chief whose `who()` names it (null: not bound yet). The same effect gate as hands: its login may read private code. */
export const codeTools = (env: Env, who: () => { agent: string | null }, effectsAuthorized: () => boolean = () => true): [ToolRegistration<typeof Args>] => [
  {
    name: "code",
    description: CODE_DESCRIPTION,
    parameters: Args,
    replay: "safe",
    execute: async (args) => {
      if (!effectsAuthorized()) return effectRefusal()
      const { agent } = who()
      if (!agent) return { content: [{ type: "text", text: "code error: this brain has no chief yet" }] }
      const token = await githubOf(env, agent).ccGithubTurn(agent).then((t) => t.token, () => null)
      const text = await codeProgram(args as CodeArgs, githubGet(token))
      const note = token ? "" : "\n(no GitHub login for this Chief: public repositories only, and search needs a login; the owner signs it in with chief-github)"
      console.log(JSON.stringify({ msg: "chief_code.call", action: String((args as CodeArgs).action), ok: !text.startsWith("code error"), login: Boolean(token) }))
      return { content: [{ type: "text", text: text + (text.startsWith("code error") || !token ? note : "") }] }
    }
  }
]
