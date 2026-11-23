import { exports } from "cloudflare:workers"
import { describe, expect, it } from "vitest"
import type { Env } from "../src/env.ts"
import { joinedMachineToken } from "../src/integrations/machine-github.ts"
import { signedInWithInstall } from "./cloud-bind-support.ts"
import { inDO, linkGitHub, testEnv } from "./github-token-support.ts"

/**
 * The MachineGitHub entrypoint cmux-platform's POST /v1/machines/github/token calls once it has checked a joined
 * machine's `cmm_` credential (RFD 0053): a token for the join record's team, keyed by machine, with no install.
 */
describe("joined machine GitHub token", { timeout: 60_000 }, () => {
  it("mints a one-hour token for the team's repo through the named entrypoint, keyed by the machine", async () => {
    const a = await signedInWithInstall("joined-mint", "cli")
    const { gh } = await linkGitHub(a.session, a.team)
    const entry = (exports as any).MachineGitHub
    const reply = await entry.joinedMachineToken({ machine: "mach_joined1", team: a.team, user: a.user, repo: "acme/web", permissions: { contents: "read" }, label: "build" })
    expect(reply.ok, JSON.stringify(reply)).toBe(true)
    expect(reply.value).toMatchObject({ repo: "acme/web", permissions: { contents: "read" } })
    expect(Date.parse(reply.value.expires_at) - Date.now()).toBeLessThanOrEqual(3600_000)
    expect(reply.value.token_id).toBeTruthy()
    expect(gh.mints()).toHaveLength(1)
    await inDO(testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(a.team)), async (instance) => {
      const rows = instance.ctx.storage.sql.exec("SELECT principal FROM github_tokens").toArray() as Array<{ principal: string }>
      expect(rows.map((r) => r.principal)).toEqual(["machine:mach_joined1"])
    })
    // The same machine asking again reuses its cached token instead of minting another.
    const again = await entry.joinedMachineToken({ machine: "mach_joined1", team: a.team, user: a.user, repo: "acme/web", permissions: { contents: "read" } })
    expect([again.ok && again.value.token_id, gh.mints().length]).toEqual([reply.value.token_id, 1])
  })

  it("refuses a repo the team's installation does not cover", async () => {
    const a = await signedInWithInstall("joined-uncovered", "cli")
    const { gh } = await linkGitHub(a.session, a.team)
    const reply = await joinedMachineToken(testEnv as unknown as Env, { machine: "mach_joined2", team: a.team, user: a.user, repo: "elsewhere/secret", permissions: { contents: "read" } })
    expect(reply, JSON.stringify(reply)).toMatchObject({ ok: false, status: 403, code: "policy.denied" })
    expect(gh.mints()).toHaveLength(0)
  })

  it("refuses a minter who is not a member of a shared team", async () => {
    const a = await signedInWithInstall("joined-outsider", "cli")
    const reply = await joinedMachineToken(testEnv as unknown as Env, { machine: "mach_joined3", team: "team_0123456789abcdef0123", user: a.user, repo: "acme/web", permissions: { contents: "read" } })
    expect(reply).toMatchObject({ ok: false, status: 403, code: "auth.forbidden" })
  })

  it("refuses malformed input before it reaches the connection", async () => {
    const a = await signedInWithInstall("joined-bad", "cli")
    const base = { machine: "mach_joined4", team: a.team, user: a.user, repo: "acme/web", permissions: { contents: "read" } } as const
    for (const bad of [{ ...base, team: "acme" }, { ...base, machine: "" }, { ...base, permissions: {} }, { ...base, repo: "not a repo" }, { ...base, permissions: { contents: "admin" } }]) {
      expect(await joinedMachineToken(testEnv as unknown as Env, bad as any), JSON.stringify(bad)).toMatchObject({ ok: false, status: 400, code: "request.invalid" })
    }
  })
})
