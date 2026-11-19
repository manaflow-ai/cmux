import type { Principal } from "@cmux/ownership"
import { GITHUB_INSTALL_REQUEST_TTL_MS, PENDING_CONNECTION_TTL_MS } from "@cmux/protocol"
import { describe, expect, it, vi } from "vitest"
import { requesterKey } from "../src/integrations/github-handoffs.ts"
import { signedInWithInstall, worker } from "./cloud-bind-support.ts"
import { fakeGitHub, inDO, linkGitHub, ok, op, policy, read, testEnv, token } from "./github-token-support.ts"

/**
 * GitHub changes made on GitHub after Connect, with nobody in cmux clicking (integrations/github-handoffs.ts):
 * repositories added to an installation later, an organization owner approving a member's install request, and
 * pending connects that end (a newer Connect, their lifetime). GitHub is faked; webhooks are signed as GitHub signs them.
 */

const hmacHex = async (secret: string, msg: string) => {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"])
  return [...new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(msg)))].map((b) => b.toString(16).padStart(2, "0")).join("")
}

/** One signed GitHub App webhook; the body's hash is its delivery id, so the same body twice is a redelivery. */
const hook = async (event: string, payload: Record<string, unknown>) => {
  const body = JSON.stringify(payload)
  const res = await worker.fetch("https://api.test/v1/hooks/github", { method: "POST", headers: { "x-hub-signature-256": `sha256=${await hmacHex(testEnv.GITHUB_WEBHOOK_SECRET, body)}`, "x-github-delivery": crypto.randomUUID(), "x-github-event": event }, body })
  expect(res.status).toBe(200)
  return (await res.json()) as { connections: number; approved?: number }
}

const githubRows = async (session: string) => ((await read(session, "integration.list")).body.value.connections as Array<any>).filter((c) => c.provider === "github")
const status = async (bearer: string, team: string) => (await (await worker.fetch(`https://api.test/v1/integrations/github/status?team=${team}`, { headers: { authorization: `Bearer ${bearer}` } })).json()) as any
const mint = (bearer: string, team: string, repo: string) => token(bearer, { team, repo, permissions: { contents: "read" } })

/** Installation 77 on `neworg`, which an owner creates when approving: mints answer, and GitHub user 7 (`linker`) collaborates on neworg/open only. */
const approvingGitHub = () => {
  const gh = fakeGitHub()
  let n = 0
  gh.routes["https://api.github.com/app/installations/77/access_tokens"] = (_req, body) =>
    ok({ token: `ghs_77_${++n}`, expires_at: new Date(Date.now() + 3600_000).toISOString(), permissions: { ...(JSON.parse(body || "{}") as { permissions?: object }).permissions, metadata: "read" } }, 201)
  gh.routes["https://api.github.com/repos/neworg/"] = (req) => new Response(null, { status: req.url === "https://api.github.com/repos/neworg/open/collaborators/linker" ? 204 : 404 })
  return gh
}

const created = (requester: { id: number; login: string }, extra: Record<string, unknown> = {}) => ({
  action: "created",
  installation: { id: 77, account: { login: "neworg", html_url: "https://github.com/neworg" }, permissions: { contents: "write", metadata: "read", pull_requests: "write" }, repository_selection: "selected" },
  repositories: [{ full_name: "neworg/open" }, { full_name: "neworg/closed" }],
  requester,
  sender: { id: 500, login: "owner" },
  ...extra
})

/** Connect, then GitHub's redirect for a member's request: no installation, a code unless `code` is null. */
const requestInstall = async (session: string, code: string | null = "c") => {
  const connect = await op(session, "integration.connect", { provider: "github", sharing: "team" })
  const state = new URL(connect.body.value.authorize_url).searchParams.get("state")!
  const done = await op(session, "integration.complete", { state, setup_action: "request", ...(code ? { code } : {}) })
  expect(done.body.ok).toBe(false)
  return { pending: connect.body.value.connection.id as string, message: done.body.error.message as string }
}

describe("GitHub handoffs", { timeout: 60_000 }, () => {
  it("a repository added on GitHub joins when the person who linked added it or can reach it; one they cannot reach stays out", async () => {
    const a = await signedInWithInstall("gh-handoff-added", "cli")
    const { gh } = await linkGitHub(a.session, a.team)
    // GitHub user 7 (the linker) collaborates on acme/shared, not on acme/secret.
    gh.routes["https://api.github.com/repos/acme/"] = (req) => new Response(null, { status: req.url === "https://api.github.com/repos/acme/shared/collaborators/linker" ? 204 : 404 })
    const added = (sender: number, repos: Array<string>) =>
      hook("installation_repositories", { action: "added", installation: { id: 99, account: { login: "acme" } }, repository_selection: "selected", repositories_added: repos.map((full_name) => ({ full_name })), repositories_removed: [], sender: { id: sender, login: sender === 7 ? "linker" : "someone" } })

    // The linker added it themselves (adding takes admin access): it joins without asking GitHub anything.
    const before = gh.calls.length
    await added(7, ["acme/mine", "other/elsewhere"])
    expect(gh.calls.length).toBe(before)
    expect((await githubRows(a.session))[0].resources.repos).toEqual(["acme/api", "acme/mine", "acme/web"])

    // Someone else added two: GitHub is asked about the linker on each, with a metadata-only token for just those, revoked after.
    await added(8, ["acme/shared", "acme/secret"])
    expect((await githubRows(a.session))[0].resources.repos).toEqual(["acme/api", "acme/mine", "acme/shared", "acme/web"])
    const narrowed = gh.mints().map((m) => JSON.parse(m.body || "{}"))
    expect(narrowed).toContainEqual({ repositories: ["shared", "secret"], permissions: { metadata: "read" } })
    expect(gh.deletes().map((d) => d.url)).toContain("https://api.github.com/installation/token")
    expect(gh.calls.map((c) => c.url)).toContain("https://api.github.com/user/7")

    expect((await mint(a.installToken, a.team, "acme/shared")).status).toBe(200)
    expect((await mint(a.installToken, a.team, "acme/mine")).status).toBe(200)
    const refused = await mint(a.installToken, a.team, "acme/secret")
    expect([refused.status, refused.body.error.reason]).toEqual([403, "repo_not_granted"])
  })

  it("a connection whose linker GitHub did not name joins no added repository", async () => {
    const a = await signedInWithInstall("gh-handoff-added-nolinker", "cli")
    const gh = fakeGitHub()
    gh.routes["https://api.github.com/user"] = () => new Response("unavailable", { status: 503 })
    await inDO(testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(a.team)), async (instance) => void (instance.http = gh.http))
    const connect = await op(a.session, "integration.connect", { provider: "github", sharing: "team" })
    const state = new URL(connect.body.value.authorize_url).searchParams.get("state")!
    expect((await op(a.session, "integration.complete", { state, code: "c", installation_id: "99", setup_action: "install" })).body.ok).toBe(true)
    await hook("installation_repositories", { action: "added", installation: { id: 99, account: { login: "acme" } }, repositories_added: [{ full_name: "acme/new" }], sender: { id: 7, login: "linker" } })
    expect((await githubRows(a.session))[0].resources.repos).toEqual(["acme/api", "acme/web"])
  })

  it("an owner's approval of a member's request links the installation to the waiting team, with only the repositories the requester can reach", async () => {
    const a = await signedInWithInstall("gh-handoff-approval", "cli")
    const gh = approvingGitHub()
    await inDO(testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(a.team)), async (instance) => void (instance.http = gh.http))

    const { pending, message } = await requestInstall(a.session)
    expect(message).toContain("When an owner approves it, cmux connects it to this team without another Connect")
    // The connect's page is done: no pending connect remains; the request is what status reports.
    expect((await githubRows(a.session)).map((c) => [c.id, c.status])).toEqual([[pending, "expired"]])
    const waiting = await status(a.installToken, a.team)
    expect(waiting.connection).toBeNull()
    expect(waiting.pending_approval).toMatchObject({ github_login: "linker", links_on_approval: true, approved_account: null, detail: null })
    expect(waiting.pending_approval.expires_at - waiting.pending_approval.requested_at).toBe(GITHUB_INSTALL_REQUEST_TTL_MS)

    // An installation whose requester is another GitHub user links nothing here.
    expect((await hook("installation", created({ id: 8, login: "other" }))).approved).toBe(0)
    expect((await status(a.installToken, a.team)).pending_approval).not.toBeNull()

    // The owner approves this person's request.
    const body = created({ id: 7, login: "linker" })
    expect((await hook("installation", body)).approved).toBe(1)
    const linked = await status(a.installToken, a.team)
    expect(linked.pending_approval).toBeNull()
    expect(linked.connection).toMatchObject({ account: "neworg", status: "active", repos: ["neworg/open"] })
    expect((await mint(a.installToken, a.team, "neworg/open")).status).toBe(200)
    expect((await mint(a.installToken, a.team, "neworg/closed")).status).toBe(403)
    // GitHub's redelivery links nothing twice.
    expect((await hook("installation", body)).approved).toBe(0)
    expect((await githubRows(a.session)).filter((c) => c.status === "active")).toHaveLength(1)
    // The approval route is gone with the request.
    expect((await testEnv.ACCOUNT_INDEX_DO.get(testEnv.ACCOUNT_INDEX_DO.idFromName(requesterKey(7))).list()).filter((l: { team: string }) => l.team === a.team)).toEqual([])
  })

  it("an approval the team policy will not link by itself, or a request GitHub sent without a code, leaves Connect GitHub to the person", async () => {
    const a = await signedInWithInstall("gh-handoff-approval-admin", "cli")
    const gh = approvingGitHub()
    await inDO(testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(a.team)), async (instance) => void (instance.http = gh.http))
    await policy(a.session, a.team, { github: { require_org_admin: true } })
    expect((await requestInstall(a.session)).message).toContain("When an owner approves it, choose Connect GitHub in cmux again")
    expect((await status(a.installToken, a.team)).pending_approval).toMatchObject({ links_on_approval: false, approved_account: null })
    expect((await hook("installation", created({ id: 7, login: "linker" }))).approved).toBe(0)
    const seen = (await status(a.installToken, a.team)).pending_approval
    expect(seen).toMatchObject({ links_on_approval: false, approved_account: "neworg" })
    expect(seen.detail).toContain("requires a neworg organization admin")
    expect((await githubRows(a.session)).filter((c) => c.status === "active")).toHaveLength(0)

    const b = await signedInWithInstall("gh-handoff-approval-nocode", "cli")
    await inDO(testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(b.team)), async (instance) => void (instance.http = approvingGitHub().http))
    expect((await requestInstall(b.session, null)).message).toContain("choose Connect GitHub in cmux again")
    expect((await status(b.installToken, b.team)).pending_approval).toMatchObject({ github_login: null, links_on_approval: false })
  })

  it("a newer Connect ends the earlier pending one; a pending connect past its lifetime reads as expired; a request leaves after its lifetime", async () => {
    const a = await signedInWithInstall("gh-handoff-pending", "cli")
    const stub = testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(a.team))
    await inDO(stub, async (instance) => void (instance.http = approvingGitHub().http))
    const first = await op(a.session, "integration.connect", { provider: "github", sharing: "team" })
    const second = await op(a.session, "integration.connect", { provider: "github", sharing: "team" })
    const ids = [first.body.value.connection.id, second.body.value.connection.id]
    expect((await githubRows(a.session)).map((c) => [c.id, c.status])).toEqual([[ids[0], "expired"], [ids[1], "pending"]])
    // The earlier page is refused as expired.
    const stale = new URL(first.body.value.authorize_url).searchParams.get("state")!
    const late = await op(a.session, "integration.complete", { state: stale, code: "c", installation_id: "99", setup_action: "install" })
    expect(late.body.error.message).toContain("expired")

    await inDO(stub, async (instance) => {
      const p: Principal = { identity: `user:${a.user}`, kind: "session", user: a.user, team: a.team }
      const state = instance.boundEngine.currentState
      const createdAt = state.connections[ids[1]].created_at
      const clock = vi.spyOn(Date, "now").mockReturnValue(createdAt + PENDING_CONNECTION_TTL_MS)
      try {
        // The alarm has not committed the expiry yet; the list already reads it as expired.
        expect(state.connections[ids[1]].status).toBe("pending")
        expect(instance.read(state, "integration.list", {}, p).value.connections.find((c: any) => c.id === ids[1]).status).toBe("expired")
      } finally {
        clock.mockRestore()
      }
    })

    // A recorded request leaves owner state (and the approval route) after GITHUB_INSTALL_REQUEST_TTL_MS.
    await requestInstall(a.session)
    const routes = async () => (await testEnv.ACCOUNT_INDEX_DO.get(testEnv.ACCOUNT_INDEX_DO.idFromName(requesterKey(7))).list()).filter((l: { team: string }) => l.team === a.team)
    expect(await routes()).toHaveLength(1)
    await inDO(stub, async (instance) => {
      const r = Object.values(instance.boundEngine.currentState.github_requests ?? {})[0] as { requested_at: number }
      const at = r.requested_at + GITHUB_INSTALL_REQUEST_TTL_MS
      expect(instance.nextWakeAt(instance.boundEngine.currentState, r.requested_at)).toBeLessThanOrEqual(at)
      await instance.onWake(at)
      expect(instance.boundEngine.currentState.github_requests).toEqual({})
    })
    expect(await routes()).toEqual([])
    expect((await status(a.installToken, a.team)).pending_approval).toBeNull()
  })
})
