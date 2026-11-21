import { describe, expect, it } from "vitest"
import { signedInWithInstall, worker } from "./cloud-bind-support.ts"
import { type fakeGitHub, LINKING_GITHUB_ID, linkGitHub, ok, read, testEnv, token } from "./github-token-support.ts"

/**
 * The installation_repositories webhook (gh-app-product contract): a repository the linking user adds to the GitHub
 * App installation joins the team's connection with no relink; another sender's does not. GitHub is faked.
 */

/** The X-Hub-Signature-256 digest GitHub sends with a webhook. */
const hmacHex = async (secret: string, msg: string) => {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"])
  return [...new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(msg)))].map((b) => b.toString(16).padStart(2, "0")).join("")
}

describe("GitHub App: repositories added after linking", { timeout: 60_000 }, () => {
  it("App webhooks: a repository the linking user adds to the installation joins the connection; another sender's, or one on a connection with no recorded linker, does not", async () => {
    const hookFor = (team: string) => async (payload: Record<string, unknown>, delivery = crypto.randomUUID()) => {
      const body = JSON.stringify({ installation: { id: 99, account: { login: "acme" } }, action: "added", repository_selection: "selected", repositories_removed: [], ...payload })
      const res = await worker.fetch("https://api.test/v1/hooks/github", { method: "POST", headers: { "x-hub-signature-256": `sha256=${await hmacHex(testEnv.GITHUB_WEBHOOK_SECRET, body)}`, "x-github-delivery": delivery, "x-github-event": "installation_repositories" }, body })
      expect(res.status).toBe(200)
    }
    const githubOf = async (session: string) => (await read(session, "integration.list")).body.value.connections.find((c: any) => c.provider === "github")
    const picker = async (session: string, team: string) => {
      const res = await worker.fetch(`https://api.test/v1/integrations/github/repos?team=${team}`, { headers: { authorization: `Bearer ${session}` } })
      expect(res.status).toBe(200)
      return ((await res.json()) as any).repos.map((r: any) => r.full_name)
    }
    const installationRepos = (gh: ReturnType<typeof fakeGitHub>) => {
      gh.routes["https://api.github.com/installation/repositories"] = () => ok({ total_count: 4, repositories: ["acme/web", "acme/api", "acme/new", "acme/other"].map((full_name) => ({ full_name, private: true })) })
    }

    // Linked under the default scope: the connection records who linked.
    const a = await signedInWithInstall("gh-token-hooks-added-1", "cli")
    const { gh } = await linkGitHub(a.session, a.team)
    installationRepos(gh)
    expect((await githubOf(a.session)).resources).toEqual({ repos: ["acme/api", "acme/web"], linked_by_github_id: LINKING_GITHUB_ID })
    const hook = hookFor(a.team)
    const mint = (repo: string) => token(a.installToken, { team: a.team, repo, permissions: { contents: "read" } })

    // Another sender (an org owner adding a repository for someone else) joins nothing.
    await hook({ sender: { id: LINKING_GITHUB_ID + 1, login: "someone-else" }, repositories_added: [{ full_name: "acme/other" }] })
    expect((await githubOf(a.session)).resources.repos).toEqual(["acme/api", "acme/web"])
    expect((await mint("acme/other")).status).toBe(403)

    // The linking user adds a repository ("Add more repositories" in the app): the picker shows it and a mint succeeds, no relink.
    const delivery = crypto.randomUUID()
    await hook({ sender: { id: LINKING_GITHUB_ID, login: "linker" }, repositories_added: [{ full_name: "acme/new" }, { full_name: "acme/WEB" }] }, delivery)
    const joined = await githubOf(a.session)
    expect([joined.resources, joined.status]).toEqual([{ repos: ["acme/api", "acme/new", "acme/web"], linked_by_github_id: LINKING_GITHUB_ID }, "active"])
    expect((await picker(a.session, a.team)).sort()).toEqual(["acme/api", "acme/new", "acme/web"])
    expect((await mint("acme/new")).status).toBe(200)
    expect((await mint("acme/other")).status).toBe(403)

    // GitHub's redelivery (same body, same delivery) is a replay: nothing changes.
    const before = (await githubOf(a.session)).updated_at
    await hook({ sender: { id: LINKING_GITHUB_ID, login: "linker" }, repositories_added: [{ full_name: "acme/new" }, { full_name: "acme/WEB" }] }, delivery)
    expect((await githubOf(a.session))).toMatchObject({ updated_at: before, resources: { repos: ["acme/api", "acme/new", "acme/web"] } })

    // A connection linked before the linker was recorded (GET /user unreadable here) keeps today's behavior.
    const b = await signedInWithInstall("gh-token-hooks-added-2", "cli")
    const linked = await linkGitHub(b.session, b.team, (g) => void (g.routes["https://api.github.com/user"] = () => ok({ message: "Not Found" }, 404)))
    installationRepos(linked.gh)
    expect((await githubOf(b.session)).resources).toEqual({ repos: ["acme/api", "acme/web"] })
    await hookFor(b.team)({ sender: { id: LINKING_GITHUB_ID, login: "linker" }, repositories_added: [{ full_name: "acme/new" }] })
    expect((await githubOf(b.session)).resources.repos).toEqual(["acme/api", "acme/web"])
    expect((await picker(b.session, b.team)).sort()).toEqual(["acme/api", "acme/web"])
    expect((await token(b.installToken, { team: b.team, repo: "acme/new", permissions: { contents: "read" } })).status).toBe(403)
  })
})
