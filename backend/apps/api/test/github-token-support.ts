import { env } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { expect } from "vitest"
import { post } from "./cloud-bind-support.ts"
import { settlePolicy } from "./integration-policy-settle.ts"

/** Shared helpers for the GitHub token endpoint tests (github-token*.test.ts): ops, policy, a fake GitHub and a linked connection. */


export const testEnv = env as unknown as Record<string, any>
export const inDO = runInDurableObject as unknown as (stub: unknown, cb: (instance: any) => Promise<void>) => Promise<void>
export const ok = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } })
export const op = (token: string, name: string, params: unknown) => post("/v1/ops", token, { op: name, params, idempotency_key: crypto.randomUUID(), origin: "cli" })
export const read = (token: string, name: string, params: unknown = {}) => post("/v1/read", token, { op: name, params })
export const asJson = (r: { status: number; body: any }) => ({ status: r.status, json: r.body })
export const policy = (token: string, team: string, fields: unknown) => settlePolicy((t, n, p) => op(t, n, p).then(asJson), (t, n, p) => read(t, n, p).then(asJson), token, team, fields)
export const token = (bearer: string, body: unknown) => post("/v1/integrations/github/token", bearer, body)

/** The fake GitHub's signed-in (linking) user id. */
export const LINKING_GITHUB_ID = 4242

/** A fake GitHub: the App's installation 99 on account acme; records every request. */
export const fakeGitHub = () => {
  const calls: Array<{ method: string; url: string; auth: string | null; body: string }> = []
  let n = 0
  const routes: Record<string, (req: Request, body: string) => Response> = {
    "https://github.com/login/oauth/access_token": () => ok({ access_token: "ghu_user" }),
    "https://api.github.com/user/installations/99/repositories": () => ok({ repositories: [{ full_name: "acme/web" }, { full_name: "acme/api" }] }),
    "https://api.github.com/user/installations": () => ok({ installations: [{ id: 99, account: { login: "acme", type: "Organization" }, permissions: { contents: "write", pull_requests: "write", issues: "write", workflows: "write", metadata: "read" } }] }),
    "https://api.github.com/app/installations/99/access_tokens": (_req, body) =>
      ok({ token: `ghs_secret_${++n}`, expires_at: new Date(Date.now() + 3600_000).toISOString(), permissions: { ...(JSON.parse(body || "{}") as { permissions?: object }).permissions, metadata: "read" } }, 201),
    "https://api.github.com/installation/token": () => new Response(null, { status: 204 }),
    // The linking user (GET /user); last, so the /user/installations routes above match first.
    "https://api.github.com/user": () => ok({ id: LINKING_GITHUB_ID, login: "linker" })
  }
  const http = async (req: Request) => {
    const body = await req.clone().text()
    calls.push({ method: req.method, url: req.url, auth: req.headers.get("authorization"), body })
    const key = Object.keys(routes).find((k) => req.url.startsWith(k))
    return key ? routes[key]!(req, body) : new Response("not found", { status: 404 })
  }
  return { http, calls, routes, mints: () => calls.filter((c) => c.url.endsWith("/access_tokens")), deletes: () => calls.filter((c) => c.method === "DELETE") }
}

/** Links a team-shared GitHub connection (installation 99, repos acme/web and acme/api) in `team`. */
export const linkGitHub = async (session: string, team: string, setup?: (gh: ReturnType<typeof fakeGitHub>) => void) => {
  const gh = fakeGitHub()
  setup?.(gh)
  await inDO(testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(team)), async (instance) => void (instance.http = gh.http))
  const connect = await op(session, "integration.connect", { provider: "github", sharing: "team" })
  const state = new URL(connect.body.value.authorize_url).searchParams.get("state")!
  const done = await op(session, "integration.complete", { state, code: "c", installation_id: "99", setup_action: "install" })
  expect(done.body, JSON.stringify(done.body)).toMatchObject({ ok: true, value: { status: "active" } })
  return { gh }
}
