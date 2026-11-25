import { describe, expect, it } from "vitest"
import { signedInWithInstall } from "./cloud-bind-support.ts"
import { fakeGitHub, inDO, linkGitHub, ok, op, policy, read, testEnv, token } from "./github-token-support.ts"

/**
 * POST /v1/integrations/github/token refusals: each policy.denied names its reason (workflows,
 * an owner the team has not connected, a repository or permission GitHub did not grant, the team's
 * allowlist, a selected connection on another owner) and, when GitHub's page fixes it, configure_url.
 * GitHub is faked.
 */

describe("GitHub token refusals", { timeout: 60_000 }, () => {
  it("refuses repositories outside the connection or policy, other owners, unknown permissions and workflows without the policy flag", async () => {
    const a = await signedInWithInstall("gh-token-2", "cli")
    const none = (await token(a.installToken, { team: a.team, repo: "acme/web", permissions: { contents: "read" } })).body.error
    expect(none.code).toBe("integration.not_found")
    // Every refusal says what to do next (github-next.ts), and which cmux action does it.
    expect([none.next, none.next_action]).toEqual([expect.stringContaining("Connect GitHub"), "accounts.githubConnect"])
    const { gh } = await linkGitHub(a.session, a.team)
    const t = (repo: string, permissions: unknown) => token(a.installToken, { team: a.team, repo, permissions }).then((r) => [r.status, r.body.error?.code])
    expect(await t("acme/secret", { contents: "read" })).toEqual([403, "policy.denied"])
    expect(await t("other/web", { contents: "read" })).toEqual([403, "policy.denied"])
    expect(await t("acme/web", { administration: "write" })).toEqual([400, "request.invalid"])
    expect(await t("acme/web", { contents: "admin" })).toEqual([400, "request.invalid"])
    expect(await t("acme/web", {})).toEqual([400, "request.invalid"])
    expect(await t("acme/web", { workflows: "write" })).toEqual([403, "policy.denied"])
    const reason = (repo: string, permissions: unknown) => token(a.installToken, { team: a.team, repo, permissions }).then((r) => r.body.error?.reason)
    expect(await reason("acme/web", { workflows: "write" })).toBe("workflows_not_allowed")
    // Only a team admin can allow workflow changes: the step names them, and no Connect button is offered.
    const workflows = (await token(a.installToken, { team: a.team, repo: "acme/web", permissions: { workflows: "write" } })).body.error
    expect([workflows.next, "next_action" in workflows]).toEqual([expect.stringContaining("team admin"), false])
    expect(await reason("other/web", { contents: "read" })).toBe("owner_not_connected")
    expect(gh.mints()).toHaveLength(0)
    await policy(a.session, a.team, { github: { allow_workflows: true } })
    expect(await t("acme/web", { workflows: "write" })).toEqual([200, undefined])
    await policy(a.session, a.team, { github: { repo_allowlist: ["acme/api"] } })
    expect(await t("acme/web", { contents: "read" })).toEqual([403, "policy.denied"])
    // Unauthenticated, and a team the install was not minted for.
    expect((await token("", { team: a.team, repo: "acme/api", permissions: { contents: "read" } })).status).toBe(401)
    expect((await token(a.installToken, { team: "team_00000000000000000000", repo: "acme/api", permissions: { contents: "read" } })).body.error.code).toBe("auth.forbidden")
    // A GitHub refusal (422) is policy.denied.
    gh.routes["https://api.github.com/app/installations/99/access_tokens"] = () => ok({ message: "nope" }, 422)
    expect(await t("acme/api", { checks: "write" })).toEqual([403, "policy.denied"])
  })

  it("a GitHub refusal of the repository names the installation's configure page in the error", async () => {
    const a = await signedInWithInstall("gh-token-cfg-denied", "cli")
    const { gh } = await linkGitHub(a.session, a.team)
    gh.routes["https://api.github.com/app/installations/99"] = () => ok({ id: 99, account: { login: "acme", type: "Organization" } })
    gh.routes["https://api.github.com/app/installations/99/access_tokens"] = () => ok({ message: "There is at least one repository that does not exist or is not accessible to the parent installation." }, 422)
    const denied = await token(a.installToken, { team: a.team, repo: "acme/web", permissions: { contents: "read" } })
    const page = "https://github.com/organizations/acme/settings/installations/99"
    expect([denied.status, denied.body.error]).toEqual([403, { code: "policy.denied", message: expect.any(String), configure_url: page, reason: "repo_not_granted", next: expect.stringContaining("Add the repository"), next_action: "accounts.githubConnect" }])
    // A repository of the owner the link left out (not selected when it was linked) is added on the same page.
    const unlisted = await token(a.installToken, { team: a.team, repo: "acme/secret", permissions: { contents: "read" } })
    expect([unlisted.status, unlisted.body.error]).toEqual([403, { code: "policy.denied", message: expect.any(String), configure_url: page, reason: "repo_not_granted", next: expect.stringContaining("Add the repository"), next_action: "accounts.githubConnect" }])
    // The recorded list is the linking person's access: the installation may already include it, so both fixes are named.
    expect(unlisted.body.error.message).toContain("the person who connected GitHub could see")
    expect(unlisted.body.error.message).toContain("If the installation on GitHub leaves acme/secret out, add it there; then connect GitHub again as someone who can see acme/secret")
    // The installation lacks the asked access (GitHub's other 422): its own reason, and the page where an owner reviews it.
    gh.routes["https://api.github.com/app/installations/99/access_tokens"] = () => ok({ message: "The permissions requested are not granted to this installation." }, 422)
    const access = await token(a.installToken, { team: a.team, repo: "acme/web", permissions: { contents: "write" } })
    expect([access.status, access.body.error.reason, access.body.error.configure_url]).toEqual([403, "permissions_not_granted", page])
    // A team-policy refusal is not fixed on GitHub's page: no configure_url there.
    await policy(a.session, a.team, { github: { repo_allowlist: ["acme/api"] } })
    const policyDenied = await token(a.installToken, { team: a.team, repo: "acme/web", permissions: { contents: "read" } })
    expect([policyDenied.status, policyDenied.body.error.code, policyDenied.body.error.reason, "configure_url" in policyDenied.body.error]).toEqual([403, "policy.denied", "repo_not_allowed", false])
  })

  it("a repository of an account the team has not connected (one the person only collaborates on) says its owner installs the App", async () => {
    const a = await signedInWithInstall("gh-token-other-owner", "cli")
    const { gh } = await linkGitHub(a.session, a.team)
    const other = await token(a.installToken, { team: a.team, repo: "someone/private-app", permissions: { contents: "read" } })
    expect([other.status, other.body.error.code, other.body.error.reason, "configure_url" in other.body.error]).toEqual([403, "policy.denied", "owner_not_connected", false])
    expect(other.body.error.message).toContain("someone")
    // Decided from the team's connections alone: GitHub is not asked.
    expect(gh.mints()).toHaveLength(0)
    expect(gh.calls.filter((c) => c.url.includes("/app/installations/"))).toHaveLength(0)
  })

  it("a selected connection on another account than the repository's owner says so, and never falls back to the owner's connection", async () => {
    const a = await signedInWithInstall("gh-token-selected-other", "cli")
    const { gh } = await linkGitHub(a.session, a.team)
    const acme = ((await read(a.session, "integration.list")).body.value.connections as Array<{ id: string; provider: string }>).find((c) => c.provider === "github")!.id
    // A second installation, 77 on the account `other`.
    gh.routes["https://api.github.com/user/installations"] = (req) =>
      req.url.includes("/user/installations/77/repositories")
        ? ok({ repositories: [{ full_name: "other/app" }] })
        : ok({ installations: [{ id: 77, account: { login: "other", type: "Organization" }, permissions: { contents: "write", metadata: "read" } }] })
    const begin = await op(a.session, "integration.connect", { provider: "github", sharing: "team" })
    const oauthState = new URL(begin.body.value.authorize_url).searchParams.get("state")!
    const done = await op(a.session, "integration.complete", { state: oauthState, code: "c", installation_id: "77", setup_action: "install" })
    expect(done.body, JSON.stringify(done.body)).toMatchObject({ ok: true, value: { status: "active" } })
    const other = done.body.value.id as string
    const ask = (repo: string, connection: string) => token(a.installToken, { team: a.team, repo, permissions: { contents: "read" }, connection })
    // The team has a connection on acme, but the person selected the one on other: name the selection, not "no connection".
    const selected = await ask("acme/web", other)
    expect([selected.status, selected.body.error.code, selected.body.error.reason, "configure_url" in selected.body.error]).toEqual([403, "policy.denied", "connection_other_owner", false])
    expect(selected.body.error.message).toBe("the selected GitHub connection is for other, not acme: select the team's GitHub connection on acme instead")
    // No connection on the owner besides the selected one: say that too.
    const nowhere = await ask("third/app", acme)
    expect([nowhere.status, nowhere.body.error.reason]).toEqual([403, "connection_other_owner"])
    expect(nowhere.body.error.message).toContain("the selected GitHub connection is for acme, not third, and this team has no other cmux GitHub App connection on third")
    // Without a selection, the same repository is not another owner's: the team's acme connection mints it.
    expect(gh.mints()).toHaveLength(0)
    const unselected = await token(a.installToken, { team: a.team, repo: "acme/web", permissions: { contents: "read" } })
    expect([unselected.status, unselected.body.connection_id]).toEqual([200, acme])
  })

  it("an organization install waiting for an owner's approval says so instead of a setup error", async () => {
    const a = await signedInWithInstall("gh-token-org-request", "cli")
    const gh = fakeGitHub()
    await inDO(testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(a.team)), async (instance) => void (instance.http = gh.http))
    const connect = await op(a.session, "integration.connect", { provider: "github", sharing: "team" })
    const state = new URL(connect.body.value.authorize_url).searchParams.get("state")!
    // GitHub's redirect for a member's request: a code (user authorization during installation) and no installation.
    const done = await op(a.session, "integration.complete", { state, code: "c", setup_action: "request" })
    expect(done.body.ok).toBe(false)
    expect(done.body.error.message).toContain("When an owner approves it, choose Connect GitHub in cmux again")
    expect(gh.calls).toHaveLength(0)
  })
})
