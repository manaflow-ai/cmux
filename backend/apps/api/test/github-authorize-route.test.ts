import { describe, expect, it } from "vitest"
import { AUTHORIZE_REFUSED as CONSOLE_REFUSED, GITHUB_AUTHORIZE_PATH as CONSOLE_PATH } from "../../dashboard/src/lib/integration-callback.ts"
import { AUTHORIZE_REFUSED, GITHUB_AUTHORIZE_PATH } from "../src/integrations/github-authorize-route.ts"
import { signState, verifyState } from "../src/integrations/state.ts"
import { signedInWithInstall, worker } from "./cloud-bind-support.ts"
import { fakeGitHub, inDO, op, testEnv } from "./github-token-support.ts"

/**
 * GET /v1/integrations/github/authorize: a connect that came back from GitHub with an installation and no code
 * (the App was already installed on the account, so GitHub showed its settings and redirected with
 * `setup_action=update`) goes on through GitHub's authorize page, and the connection then finishes. GitHub is faked.
 */

const CALLBACK = `${String(testEnv.DASHBOARD_ORIGIN).replace(/\/$/, "")}/integrations/callback`
const authorize = (query: Record<string, string>, method = "GET") => worker.fetch(`https://api.test${GITHUB_AUTHORIZE_PATH}?${new URLSearchParams(query)}`, { method, redirect: "manual" })
const claims = (state: string) => JSON.parse(atob(state.split(".")[1]!.replace(/-/g, "+").replace(/_/g, "/"))) as Record<string, unknown>
const connect = async (session: string, params: Record<string, unknown> = {}) => {
  const started = await op(session, "integration.connect", { provider: "github", sharing: "team", ...params })
  return new URL(started.body.value.authorize_url).searchParams.get("state")!
}

describe("GitHub authorize route", { timeout: 60_000 }, () => {
  it("the console and the API name the same route and the same refusal", () => {
    expect(CONSOLE_PATH).toBe(GITHUB_AUTHORIZE_PATH)
    expect(CONSOLE_REFUSED).toBe(AUTHORIZE_REFUSED)
  })

  it("an existing installation's redirect (no code) goes through GitHub's authorize page and the connection finishes", async () => {
    const a = await signedInWithInstall("gh-authorize-1", "cli")
    const gh = fakeGitHub()
    await inDO(testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(a.team)), async (instance) => void (instance.http = gh.http))
    const app = "cmux://integration/complete"
    const state = await connect(a.session, { return_to: app })
    // What the app gets today: GitHub's redirect has the installation and no code, and nothing can finish it.
    const stuck = await op(a.session, "integration.complete", { state, installation_id: "99", setup_action: "update" })
    expect(stuck.body).toMatchObject({ ok: false, error: { code: "integration.state_invalid" } })

    const res = await authorize({ state, installation_id: "99" })
    expect(res.status).toBe(302)
    expect(res.headers.get("cache-control")).toBe("no-store")
    expect(res.headers.get("referrer-policy")).toBe("no-referrer")
    const url = new URL(res.headers.get("location")!)
    expect(url.origin + url.pathname).toBe("https://github.com/login/oauth/authorize")
    expect(url.searchParams.get("client_id")).toBe("Iv1.test")
    expect(url.searchParams.get("redirect_uri")).toBe(CALLBACK)
    const next = url.searchParams.get("state")!
    // The same connect, now naming the installation; it expires when the first state does.
    const before = claims(state)
    expect(claims(next)).toMatchObject({ conn: before.conn, team: before.team, sub: before.sub, provider: "github", ret: app, inst: 99, exp: before.exp })

    // GitHub's authorize page brings back a code and no installation: it comes from the state.
    const done = await op(a.session, "integration.complete", { state: next, code: "c" })
    expect(done.body, JSON.stringify(done.body)).toMatchObject({ ok: true, value: { status: "active", account: { key: "github:installation:99" }, resources: { repos: ["acme/api", "acme/web"] } } })
    // HEAD answers as GET does (a link checker or a prefetch gets the same redirect).
    expect((await authorize({ state, installation_id: "99" }, "HEAD")).status).toBe(302)
  })

  it("names nothing the person cannot reach: completion still refuses an installation their GitHub user has no access to", async () => {
    const a = await signedInWithInstall("gh-authorize-2", "cli")
    const gh = fakeGitHub()
    await inDO(testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(a.team)), async (instance) => void (instance.http = gh.http))
    const res = await authorize({ state: await connect(a.session), installation_id: "12345" })
    const next = new URL(res.headers.get("location")!).searchParams.get("state")!
    expect(claims(next).inst).toBe(12345)
    const done = await op(a.session, "integration.complete", { state: next, code: "c" })
    expect(done.body.ok).toBe(false)
    // Another person cannot finish it either: the state still names who started the connect.
    const b = await signedInWithInstall("gh-authorize-3", "cli")
    expect((await op(b.session, "integration.complete", { state: next, code: "c" })).body).toMatchObject({ ok: false, error: { code: "integration.state_invalid" } })
  })

  it("refuses a state it did not sign, an expired one, another provider's, another installation's and a bad id: back to the callback, never to GitHub", async () => {
    const a = await signedInWithInstall("gh-authorize-4", "cli")
    const state = await connect(a.session)
    const refused = async (query: Record<string, string>) => {
      const res = await authorize(query)
      expect(res.status).toBe(302)
      const url = new URL(res.headers.get("location")!)
      expect(url.origin + url.pathname).toBe(CALLBACK)
      expect(url.searchParams.get("error")).toBe(AUTHORIZE_REFUSED)
      expect(url.searchParams.get("code")).toBeNull()
      expect(url.searchParams.get("installation_id")).toBeNull()
      return url.searchParams.get("state")
    }
    const [h, p, s] = state.split(".")
    const altered = `${h}.${btoa(JSON.stringify({ ...claims(state), team: "team_ffffffffffffffffffff" })).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_")}.${s}`
    expect(await refused({ state: altered, installation_id: "99" })).toBe(altered)
    expect(await refused({ state: `${h}.${p}.AAAA`, installation_id: "99" })).toBe(`${h}.${p}.AAAA`)
    expect(await refused({ state: "not-a-jwt", installation_id: "99" })).toBe("not-a-jwt")
    expect(await refused({ installation_id: "99" })).toBeNull()
    expect(await refused({ state: "x".repeat(5000), installation_id: "99" })).toBeNull()
    for (const installation_id of ["", "0", "-1", "9.5", "abc", "99 ", "9".repeat(21), "99999999999999999999"]) await refused({ state, installation_id })
    await refused({ state })

    const mine = (await verifyState(testEnv as never, state))!
    const past = Math.floor(Date.now() / 1000) - 60
    await refused({ state: await signState(testEnv as never, mine, past), installation_id: "99" })
    await refused({ state: await signState(testEnv as never, { ...mine, provider: "linear" }), installation_id: "99" })
    // A connect that already found its installation keeps it: the redirect cannot swap in another.
    const pinned = await signState(testEnv as never, { ...mine, installation: 99, repo: "acme/web", configure_url: "https://github.com/organizations/acme/settings/installations/99" })
    await refused({ state: pinned, installation_id: "100" })
    const same = await authorize({ state: pinned, installation_id: "99" })
    expect(claims(new URL(same.headers.get("location")!).searchParams.get("state")!)).toMatchObject({ inst: 99, repo: "acme/web", cfg: "https://github.com/organizations/acme/settings/installations/99" })
    // A state signed for another environment is not this API's.
    await refused({ state: await signState({ ...testEnv, ENVIRONMENT: "production" } as never, mine), installation_id: "99" })
  })

  it("answers only GET and HEAD", async () => {
    const res = await authorize({ state: "x", installation_id: "1" }, "POST")
    expect(res.status).toBe(405)
    expect(res.headers.get("allow")).toBe("GET, HEAD")
  })
})
