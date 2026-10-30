import { importPKCS8, SignJWT } from "jose"
import type { Env } from "../env.ts"
import { aadFor, open, seal, type SealedSecret } from "../integrations/crypto.ts"

/**
 * A Chief's own GitHub login (plans/cmux-next/chief-github-DESIGN.md; Lawrence, 2026-10-23: GitHub sign-in is a
 * default onboarding step for every Chief). One brain object per Chief named `<agent>/github`, table cc_github:
 * the token (sealed with INTEGRATIONS_KEK, AAD bound to the agent and a generation that goes up at every change),
 * who it is, its scopes and expiry. Kinds: `device` (the GitHub CLI's device flow, the default), `pat` (a pasted
 * token), `mac` (the Mac's `gh auth token`, pasted by `chief-github mac`) and `app` (a GitHub App's private key and
 * installation; each turn gets an installation token with at least 10 minutes left).
 *
 * The device flow outlives the turn that started it: the object keeps the sealed device code and polls GitHub
 * from its own job (`gh-poll`) until the person approves, denies or the code expires.
 *
 * Callers: the turn machine's `chief-github` (POST /vm {action: github_*}, turn.ts ccNotes), the owner's settings
 * route (GET/POST /v1/chiefs/<agent>/github, chief-brain/routes.ts) and turn.ts (ccGithubTurn). Token bytes never
 * go to a log, an error, a status or a reply; only `github_wait` from the Chief's own turn machine gets the token
 * back, so the same turn can push (the machine gets it at its next turn anyway).
 */
/** The GitHub CLI's OAuth app (public client id; what `gh auth login --web` uses). */
export const GH_CLIENT_ID = "178c6fc778ccc68e1d6a"
/** gh's defaults plus `workflow` (pushes that touch .github/workflows need it; a600). */
export const GH_SCOPES = "repo read:org gist workflow"
const WEB = "https://github.com"
const API = "https://api.github.com"
const DEVICE_PAGE = "https://github.com/login/device"
const REVOKE_PAGE = "https://github.com/settings/applications"
/** A device sign-in keeps a fresh code (GitHub's last ~15 minutes) this long before it gives up. */
const DEVICE_WINDOW_MS = 3 * 60 * 60_000
/** An App installation token is minted again when it has less than this left. */
const APP_MARGIN_MS = 10 * 60_000

type Kind = "device" | "pat" | "mac" | "app"
interface Login {
  kind: Kind
  login: string
  scopes: Array<string>
  expires_at: number | null
  set_at: number
  checked_at: number
  token: SealedSecret
  app?: { app_id: string; installation_id: string; key: SealedSecret }
}
interface Pending {
  user_code: string
  verification_uri: string
  expires_at: number
  interval_ms: number
  device: SealedSecret
  /** The first code's time: new codes are made until DEVICE_WINDOW_MS after it. */
  started_at: number
  renewals: number
}
export interface GithubStatus {
  signed_in: boolean
  kind?: Kind
  login?: string
  scopes?: Array<string>
  expires_at?: number | null
  set_at?: number
  checked_at?: number
  pending?: { user_code: string; verification_uri: string; expires_at: number; renewals: number; until: number }
  last_error?: string
  note?: string
}
type Out = { status: number; json: unknown }

const SCHEMA = `CREATE TABLE IF NOT EXISTS cc_github (name TEXT PRIMARY KEY, value TEXT NOT NULL)`
const read = <T>(sql: SqlStorage, name: string): T | undefined => {
  sql.exec(SCHEMA)
  const v = sql.exec<{ value: string }>(`SELECT value FROM cc_github WHERE name = ?`, name).toArray()[0]?.value
  return v === undefined ? undefined : (JSON.parse(v) as T)
}
const write = (sql: SqlStorage, name: string, value: unknown) => {
  sql.exec(SCHEMA)
  sql.exec(`INSERT INTO cc_github (name, value) VALUES (?, ?) ON CONFLICT (name) DO UPDATE SET value = excluded.value`, name, JSON.stringify(value))
}
const drop = (sql: SqlStorage, ...names: Array<string>) => {
  sql.exec(SCHEMA)
  for (const n of names) sql.exec(`DELETE FROM cc_github WHERE name = ?`, n)
}

class GithubError extends Error {
  constructor(
    readonly status: number,
    message: string
  ) {
    super(message)
  }
}

/** The object's side: its SQL, the Worker env, and how it schedules its poll job. */
export interface GithubHost {
  readonly sql: SqlStorage
  readonly env: Env
  schedule(at: number): Promise<void>
}

const kekOf = (env: Env) => {
  if (!env.INTEGRATIONS_KEK) throw new GithubError(503, "this deployment has no INTEGRATIONS_KEK, so it cannot keep a GitHub token")
  return env.INTEGRATIONS_KEK
}
const genOf = (sql: SqlStorage) => read<number>(sql, "gen") ?? 0
const aad = (agent: string, gen: number, what: string) => aadFor(`chief-github:${agent}:${what}`, agent, "github", gen)
/** Seals `text` under the next generation (the caller writes that generation with the row). */
const sealAt = (env: Env, agent: string, gen: number, what: string, text: string) => seal(kekOf(env), text, aad(agent, gen, what))
const openAt = (env: Env, agent: string, gen: number, what: string, s: SealedSecret) => open(kekOf(env), s, aad(agent, gen, what))

const ghHeaders = (token: string) => ({ authorization: `Bearer ${token}`, accept: "application/vnd.github+json", "x-github-api-version": "2022-11-28", "user-agent": "cmux-chief" })
const formPost = (url: string, body: Record<string, string>) =>
  fetch(url, { method: "POST", headers: { accept: "application/json", "content-type": "application/x-www-form-urlencoded", "user-agent": "cmux-chief" }, body: new URLSearchParams(body).toString() })

/** `github-authentication-token-expiration` ("2026-12-01 00:00:00 UTC" or "... +0000") in ms, or null. */
export const expiryOf = (header: string | null): number | null => {
  const m = /^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}) (UTC|[+-]\d{4})$/.exec((header ?? "").trim())
  if (!m) return null
  const zone = m[3] === "UTC" ? "Z" : `${m[3]!.slice(0, 3)}:${m[3]!.slice(3)}`
  const t = Date.parse(`${m[1]}T${m[2]}${zone}`)
  return Number.isFinite(t) ? t : null
}

/** Who a user token is: GET /user (401: refused). Scopes from x-oauth-scopes (none for fine-grained tokens). */
const whoIs = async (token: string): Promise<{ login: string; scopes: Array<string>; expires_at: number | null }> => {
  const r = await fetch(`${API}/user`, { headers: ghHeaders(token) })
  if (r.status === 401 || r.status === 403) throw new GithubError(400, `GitHub refused the token (HTTP ${r.status})`)
  if (!r.ok) throw new GithubError(502, `GitHub did not answer /user (HTTP ${r.status})`)
  const body = (await r.json()) as { login?: unknown }
  const scopes = (r.headers.get("x-oauth-scopes") ?? "").split(",").map((s) => s.trim()).filter(Boolean).sort()
  return { login: typeof body.login === "string" ? body.login : "", scopes, expires_at: expiryOf(r.headers.get("github-authentication-token-expiration")) }
}

const appJwt = async (appId: string, pem: string) => {
  let key: CryptoKey
  try {
    key = await importPKCS8(pem, "RS256")
  } catch {
    throw new GithubError(400, "private_key must be a PKCS#8 PEM (BEGIN PRIVATE KEY); convert with `openssl pkcs8 -topk8 -nocrypt -in KEY.pem`")
  }
  const now = Math.floor(Date.now() / 1000)
  return new SignJWT({}).setProtectedHeader({ alg: "RS256" }).setIssuer(appId).setIssuedAt(now - 60).setExpirationTime(now + 540).sign(key)
}
const mintInstallation = async (appId: string, installation: string, pem: string) => {
  const jwt = await appJwt(appId, pem)
  const r = await fetch(`${API}/app/installations/${encodeURIComponent(installation)}/access_tokens`, { method: "POST", headers: ghHeaders(jwt) })
  if (!r.ok) throw new GithubError(r.status === 401 || r.status === 404 ? 400 : 502, `GitHub did not mint an installation token (HTTP ${r.status})`)
  const body = (await r.json()) as { token?: unknown; expires_at?: unknown; permissions?: Record<string, string> }
  if (typeof body.token !== "string") throw new GithubError(502, "GitHub's installation token answer has no token")
  const scopes = Object.entries(body.permissions ?? {}).map(([k, v]) => `${k}:${v}`).sort()
  return { token: body.token, expires_at: Date.parse(String(body.expires_at ?? "")) || Date.now() + 50 * 60_000, scopes, jwt }
}

const statusOf = (sql: SqlStorage): GithubStatus => {
  const login = read<Login>(sql, "login")
  const pending = read<Pending>(sql, "pending")
  const lastError = read<string>(sql, "last_error")
  const s: GithubStatus = login
    ? { signed_in: true, kind: login.kind, login: login.login, scopes: login.scopes, expires_at: login.expires_at, set_at: login.set_at, checked_at: login.checked_at }
    : { signed_in: false }
  if (pending && pending.expires_at > Date.now())
    s.pending = { user_code: pending.user_code, verification_uri: pending.verification_uri, expires_at: pending.expires_at, renewals: pending.renewals ?? 0, until: (pending.started_at ?? pending.expires_at) + DEVICE_WINDOW_MS }
  if (lastError) s.last_error = lastError
  return s
}

/** The page as a Markdown link named by its address without the scheme (`[github.com/login/device](https://…)`). */
const pageLink = (uri: string) => `[${uri.replace(/^https?:\/\//, "")}](${uri})`

/**
 * The message the Chief posts: the code in backticks (one tap copies it) and the page alone on its line as a
 * Markdown link (Lawrence 2026-10-23: a bare or bold URL did not open in every chat).
 */
export const cardOf = (p: { user_code: string; verification_uri: string }) =>
  `Sign in to GitHub for this Chief: copy the code \`${p.user_code}\`, open the page below and approve.\n${pageLink(p.verification_uri)}`

/** One line of the turn's system prompt (turn.ts): who the Chief is on GitHub, or the onboarding step. */
export const githubLine = (s: GithubStatus): string => {
  if (s.signed_in) {
    const exp = s.expires_at ? `, expires ${new Date(s.expires_at).toISOString().slice(0, 10)}` : ""
    return `GitHub: signed in as ${s.login} (${s.kind}; ${s.scopes?.length ? s.scopes.join(" ") : "fine-grained"}${exp}). \`chief-github status|logout\`; rotate with \`chief-github login\`.`
  }
  if (s.pending) return `GitHub: sign-in waiting for the person (code ${s.pending.user_code} at ${pageLink(s.pending.verification_uri)}, ends ${new Date(s.pending.expires_at).toISOString().slice(11, 16)} UTC; a fresh code follows until approved, 3 h at most). Post the current code if the person has not seen it; \`chief-wake\` to come back when it ends; skill github-signin.`
  return "GitHub: this Chief is not signed in to GitHub yet. Offer it once (skill github-signin, Native/OptChat/optchat-chief/skills/github-signin/SKILL.md in ~/work/cmux): run `chief-github login` and post its card (the code and the page link) as your reply, as printed; it keeps waiting after your turn and wakes you (chief-wake) to post a fresh code when this one ends. Other ways: `chief-github pat FILE` (a fine-grained token), `chief-github mac` (the Mac's gh login), `chief-github app APP_ID INSTALLATION_ID KEY.pem`."
}

/** Keeps a login (a new generation: the old seals no longer open). */
const keep = async (h: GithubHost, agent: string, kind: Kind, token: string, who: { login: string; scopes: Array<string>; expires_at: number | null }, app?: { app_id: string; installation_id: string; pem: string }) => {
  const gen = genOf(h.sql) + 1
  const now = Date.now()
  const login: Login = {
    kind,
    login: who.login,
    scopes: who.scopes,
    expires_at: who.expires_at,
    set_at: now,
    checked_at: now,
    token: await sealAt(h.env, agent, gen, "token", token),
    ...(app ? { app: { app_id: app.app_id, installation_id: app.installation_id, key: await sealAt(h.env, agent, gen, "app_key", app.pem) } } : {})
  }
  write(h.sql, "gen", gen)
  write(h.sql, "login", login)
  drop(h.sql, "pending", "last_error")
}

const str = (v: unknown) => (typeof v === "string" ? v.trim() : "")

/** One `chief-github` call or settings change. `machine`: from the Chief's own turn machine (only it gets a token back). */
export const githubCall = async (h: GithubHost, agent: string, raw: unknown, machine: boolean): Promise<Out> => {
  const req = (raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {}) as Record<string, unknown>
  const action = str(req.action).replace(/^github_/, "")
  try {
    write(h.sql, "agent", agent)
    if (action === "login") {
      kekOf(h.env)
      const pending = await startDevice(h, agent, null)
      return { status: 200, json: { ...statusOf(h.sql), card: cardOf(pending), wake_in: Math.max(30, Math.ceil((pending.expires_at - Date.now()) / 1000) + 5) } }
    }
    if (action === "status") {
      await renewIfExpired(h, agent)
      return { status: 200, json: statusOf(h.sql) }
    }
    if (action === "wait") {
      // One poll now (the job keeps going without it), then the status; the token only to the Chief's machine.
      await renewIfExpired(h, agent)
      if (read<Pending>(h.sql, "pending")) await githubPoll(h, false)
      const s = statusOf(h.sql)
      if (machine && s.signed_in) return { status: 200, json: { ...s, token: (await githubTurn(h, agent)).token } }
      return { status: 200, json: s }
    }
    if (action === "pat" || action === "mac") {
      const token = str(req.token)
      if (!token || token.length > 400 || /\s/.test(token)) throw new GithubError(400, "token must be one GitHub token")
      kekOf(h.env)
      await keep(h, agent, action, token, await whoIs(token))
      return { status: 200, json: statusOf(h.sql) }
    }
    if (action === "app") {
      const appId = str(req.app_id)
      const installation = str(req.installation_id)
      const pem = str(req.private_key)
      if (!/^\d{1,12}$/.test(appId) || !/^\d{1,15}$/.test(installation) || !pem) throw new GithubError(400, "app needs app_id, installation_id (numbers) and private_key (PEM)")
      kekOf(h.env)
      const minted = await mintInstallation(appId, installation, pem)
      const slug = await fetch(`${API}/app`, { headers: ghHeaders(minted.jwt) })
        .then((r) => (r.ok ? (r.json() as Promise<{ slug?: unknown }>) : {}))
        .then((b) => (typeof (b as { slug?: unknown }).slug === "string" ? String((b as { slug: string }).slug) : `app-${appId}`))
        .catch(() => `app-${appId}`)
      await keep(h, agent, "app", minted.token, { login: `${slug}[bot]`, scopes: minted.scopes, expires_at: null }, { app_id: appId, installation_id: installation, pem })
      write(h.sql, "app_token", { sealed: await sealAt(h.env, agent, genOf(h.sql), "app_token", minted.token), expires_at: minted.expires_at })
      return { status: 200, json: statusOf(h.sql) }
    }
    if (action === "logout") {
      const was = read<Login>(h.sql, "login")
      write(h.sql, "gen", genOf(h.sql) + 1)
      drop(h.sql, "login", "pending", "app_token", "last_error")
      const note = was?.kind === "device" || was?.kind === "mac" ? `Forgotten here. The token still works until you revoke it at ${pageLink(REVOKE_PAGE)} ("GitHub CLI").` : was?.kind === "pat" ? `Forgotten here. Delete the token at ${pageLink("https://github.com/settings/personal-access-tokens")} if it is no longer used.` : "Forgotten here."
      return { status: 200, json: { ...statusOf(h.sql), note } }
    }
    return { status: 400, json: { error: "action must be github_status, github_login, github_wait, github_pat, github_mac, github_app or github_logout" } }
  } catch (e) {
    if (e instanceof GithubError) return { status: e.status, json: { error: e.message } }
    return { status: 502, json: { error: "the GitHub call failed" } }
  }
}

/** Asks GitHub for a device code and keeps it pending (a renewal keeps the first code's start), then polls from the job. */
const startDevice = async (h: GithubHost, agent: string, prev: Pending | null): Promise<Pending> => {
  const r = await formPost(`${WEB}/login/device/code`, { client_id: GH_CLIENT_ID, scope: GH_SCOPES })
  const body = (await r.json().catch(() => ({}))) as { device_code?: unknown; user_code?: unknown; verification_uri?: unknown; expires_in?: unknown; interval?: unknown }
  if (!r.ok || typeof body.device_code !== "string" || typeof body.user_code !== "string") throw new GithubError(502, `GitHub did not start a device sign-in (HTTP ${r.status})`)
  const now = Date.now()
  const pending: Pending = {
    user_code: body.user_code,
    verification_uri: typeof body.verification_uri === "string" ? body.verification_uri : DEVICE_PAGE,
    expires_at: now + (Number(body.expires_in) || 900) * 1000,
    interval_ms: Math.max(0, Number(body.interval ?? 5)) * 1000,
    device: await sealAt(h.env, agent, genOf(h.sql), "device", body.device_code),
    started_at: prev?.started_at ?? now,
    renewals: prev ? (prev.renewals ?? 0) + 1 : 0
  }
  write(h.sql, "pending", pending)
  drop(h.sql, "last_error")
  await h.schedule(now + pending.interval_ms)
  return pending
}

/** An expired code is replaced by a new one until DEVICE_WINDOW_MS after the first (so a woken Chief posts a live code), then dropped. */
const renewIfExpired = async (h: GithubHost, agent: string): Promise<void> => {
  const pending = read<Pending>(h.sql, "pending")
  if (!pending || pending.expires_at > Date.now()) return
  if (Date.now() < (pending.started_at ?? pending.expires_at) + DEVICE_WINDOW_MS) {
    try {
      await startDevice(h, agent, pending)
      return
    } catch {}
  }
  drop(h.sql, "pending")
  write(h.sql, "last_error", "no one approved the GitHub sign-in in 3 hours; run `chief-github login` again")
}

/** The `gh-poll` job: one device-flow poll. Returns the next time to poll, or null when done. `reschedule`: from the job. */
export const githubPoll = async (h: GithubHost, reschedule = true): Promise<number | null> => {
  const pending = read<Pending>(h.sql, "pending")
  const agent = read<string>(h.sql, "agent")
  if (!pending || !agent) return null
  if (pending.expires_at <= Date.now()) {
    await renewIfExpired(h, agent)
    const next = read<Pending>(h.sql, "pending")
    return next ? Date.now() + next.interval_ms : null
  }
  const next = async (interval: number) => {
    if (interval !== pending.interval_ms) write(h.sql, "pending", { ...pending, interval_ms: interval })
    return Date.now() + interval
  }
  try {
    const device = await openAt(h.env, agent, genOf(h.sql), "device", pending.device)
    const r = await formPost(`${WEB}/login/oauth/access_token`, { client_id: GH_CLIENT_ID, device_code: device, grant_type: "urn:ietf:params:oauth:grant-type:device_code" })
    const body = (await r.json().catch(() => ({}))) as { access_token?: unknown; error?: unknown; interval?: unknown }
    if (typeof body.access_token === "string") {
      await keep(h, agent, "device", body.access_token, await whoIs(body.access_token))
      return null
    }
    if (body.error === "authorization_pending" || (!r.ok && body.error === undefined)) return next(pending.interval_ms)
    if (body.error === "slow_down") return next(Math.max(pending.interval_ms + 5000, Number(body.interval ?? 0) * 1000))
    drop(h.sql, "pending")
    write(h.sql, "last_error", body.error === "access_denied" ? "the sign-in was denied on GitHub" : `GitHub ended the sign-in (${String(body.error ?? r.status).slice(0, 60)})`)
    return null
  } catch (e) {
    if (e instanceof GithubError && e.status === 503) return null
    return reschedule ? Date.now() + Math.max(pending.interval_ms, 5000) : null
  }
}

/** The token a turn machine gets (turn.ts): the Chief's own (a fresh App installation token when that is its kind), else null. */
export const githubTurn = async (h: GithubHost, agent: string): Promise<{ token: string | null; status: GithubStatus }> => {
  const login = read<Login>(h.sql, "login")
  if (!login || !h.env.INTEGRATIONS_KEK) return { token: null, status: statusOf(h.sql) }
  const gen = genOf(h.sql)
  try {
    if (login.kind === "app" && login.app) {
      const cached = read<{ sealed: SealedSecret; expires_at: number }>(h.sql, "app_token")
      if (cached && cached.expires_at - Date.now() > APP_MARGIN_MS) return { token: await openAt(h.env, agent, gen, "app_token", cached.sealed), status: statusOf(h.sql) }
      const pem = await openAt(h.env, agent, gen, "app_key", login.app.key)
      const minted = await mintInstallation(login.app.app_id, login.app.installation_id, pem)
      write(h.sql, "app_token", { sealed: await sealAt(h.env, agent, gen, "app_token", minted.token), expires_at: minted.expires_at })
      return { token: minted.token, status: statusOf(h.sql) }
    }
    return { token: await openAt(h.env, agent, gen, "token", login.token), status: statusOf(h.sql) }
  } catch (e) {
    write(h.sql, "last_error", e instanceof GithubError ? e.message : "the kept GitHub token could not be opened")
    return { token: null, status: statusOf(h.sql) }
  }
}

/** Every row as stored (tests check that no token is there in clear). */
export const githubDump = (sql: SqlStorage) => {
  sql.exec(SCHEMA)
  return sql.exec<{ name: string; value: string }>(`SELECT name, value FROM cc_github`).toArray()
}

type GithubStub = {
  ccGithub(agent: string, req: unknown, machine: boolean): Promise<Out>
  ccGithubTurn(agent: string): Promise<{ token: string | null; status: GithubStatus }>
}
/** The Chief's GitHub object (`<agent>/github`; a conversation id always starts with conv_). */
export const githubOf = (env: Env, agent: string): GithubStub => env.CHIEF_BRAIN_DO.get(env.CHIEF_BRAIN_DO.idFromName(`${agent}/github`)) as unknown as GithubStub

/**
 * `chief-github`: the Chief's client in its turn machine (curl to chief-turn-runner on 127.0.0.1:4018, which forwards
 * to the Worker with the turn's token; node only encodes JSON). `wait` writes the token into this machine's gh login.
 */
export const GITHUB_CLIENT = `#!/bin/sh
# chief-github: this Chief's own GitHub login, kept sealed by the Worker and given to every later turn
# machine (apps/api/src/chief-brain-cc/github.ts; plans/cmux-next/chief-github-DESIGN.md).
#   chief-github status
#   chief-github login                 device sign-in: post the printed card; GitHub is polled after this turn
#   chief-github wait [SECONDS]        until signed in (default 600), then gh and git here use the token
#   chief-github pat FILE|-            a pasted token (fine-grained: pick the repos, Contents + Pull requests + Workflows: write)
#   chief-github mac                   the Mac's own gh login (mac -- gh auth token)
#   chief-github app APP_ID INSTALLATION_ID KEY.pem
#   chief-github logout
set -eu
usage() { echo "usage: chief-github status | login | wait [SECONDS] | pat FILE|- | mac | app APP_ID INSTALLATION_ID KEY.pem | logout" >&2; exit 2; }
call() {
  out=$(curl -sS -m 60 -w '\\n%{http_code}' -H 'content-type: application/json' --data-binary @- http://127.0.0.1:4018/vm) || { echo "chief-github: no turn is running on this machine (127.0.0.1:4018 does not answer)" >&2; exit 1; }
  code=$(printf '%s' "$out" | tail -n 1)
  body=$(printf '%s' "$out" | sed '$d')
  [ "$code" = 200 ] || { echo "chief-github: $(printf '%s' "$body" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).error??s)}catch{console.log(s)}})')" >&2; exit 1; }
  printf '%s\\n' "$body"
}
send() { node -e 'const a=process.argv.slice(1);const o={action:a[0]};for(let i=1;i<a.length;i+=2)o[a[i]]=a[i+1];process.stdout.write(JSON.stringify(o))' "$@" | call; }
sendfile() { node -e 'const fs=require("fs");process.stdout.write(JSON.stringify({action:process.argv[1],[process.argv[2]]:fs.readFileSync(process.argv[3],"utf8").trim()}))' "$@" | call; }
uselogin() {
  node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const o=JSON.parse(s);if(!o.token)process.exit(3);process.stdout.write(o.token)})' > "$HOME/.config/gh/.t" || { rm -f "$HOME/.config/gh/.t"; return 1; }
  t=$(cat "$HOME/.config/gh/.t"); rm -f "$HOME/.config/gh/.t"
  umask 077
  printf 'github.com:\\n    git_protocol: https\\n    users:\\n        cloud-chief:\\n            oauth_token: %s\\n    oauth_token: %s\\n    user: cloud-chief\\n' "$t" "$t" > "$HOME/.config/gh/hosts.yml"
  git config --global --get-all credential.https://github.com.helper 2>/dev/null | grep -q 'gh auth git-credential' || {
    git config --global credential.https://github.com.helper ''
    git config --global --add credential.https://github.com.helper '!/usr/bin/gh auth git-credential'
  }
}
mkdir -p "$HOME/.config/gh"
cmd="\${1:-status}"
case "$cmd" in
  status) send github_status ;;
  login)
    out=$(send github_login)
    printf '%s\\n' "$out" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const o=JSON.parse(s);console.log(o.card);console.log("\\n(post the two lines above as your reply; GitHub is polled after your turn. chief-github wait returns once approved.)")})'
    # Wake this Chief when the code ends, to post the fresh one (the Worker makes it; the skill github-signin).
    wake=$(printf '%s' "$out" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).wake_in??""))')
    if [ -n "$wake" ] && [ "\${2:-}" != --no-wake ] && command -v chief-wake >/dev/null 2>&1; then
      chief-wake "$wake" "GitHub sign-in code expired: run chief-github status; if still not signed in, post its new code card and set the next chief-wake for it (skill github-signin)" >/dev/null && echo "(chief-wake set for \${wake}s: you wake to post the next code if this one is not used)"
    fi ;;
  wait)
    limit="\${2:-600}"; start=$(date +%s)
    while :; do
      out=$(send github_wait)
      if printf '%s' "$out" | grep -Eq '"signed_in": ?true'; then
        printf '%s' "$out" | uselogin && echo "signed in; gh and git here use it now" >&2
        printf '%s\\n' "$out" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const o=JSON.parse(s);delete o.token;console.log(JSON.stringify(o))})'
        exit 0
      fi
      printf '%s' "$out" | grep -q '"pending"' || { printf '%s\\n' "$out"; exit 1; }
      [ $(( $(date +%s) - start )) -lt "$limit" ] || { echo "chief-github: still waiting for the person; it keeps polling after this turn" >&2; printf '%s\\n' "$out"; exit 1; }
      sleep 5
    done ;;
  pat)
    [ $# -eq 2 ] || usage
    tmp=$(mktemp); if [ "$2" = - ]; then cat > "$tmp"; else cat -- "$2" > "$tmp"; fi
    sendfile github_pat token "$tmp"; rm -f -- "$tmp" ;;
  mac)
    tmp=$(mktemp); mac -- gh auth token > "$tmp" || { rm -f -- "$tmp"; echo "chief-github: the Mac did not give its gh token (mac health; gh auth status there)" >&2; exit 1; }
    sendfile github_mac token "$tmp"; rm -f -- "$tmp" ;;
  app)
    [ $# -eq 4 ] || usage
    key=$(mktemp)
    if grep -q 'BEGIN RSA PRIVATE KEY' -- "$4"; then openssl pkcs8 -topk8 -nocrypt -in "$4" -out "$key"; else cat -- "$4" > "$key"; fi
    node -e 'const fs=require("fs");process.stdout.write(JSON.stringify({action:"github_app",app_id:process.argv[1],installation_id:process.argv[2],private_key:fs.readFileSync(process.argv[3],"utf8")}))' "$2" "$3" "$key" | call
    rm -f -- "$key" ;;
  logout) send github_logout ;;
  *) usage ;;
esac
`
