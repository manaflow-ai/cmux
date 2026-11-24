import { exports } from "cloudflare:workers"
import { describe, expect, it } from "vitest"
import type { Env } from "../src/env.ts"
import type { Principal } from "@cmux/ownership"
import { joinedMachineToken, machineGitHubOn, revokeJoinedMachineTokens } from "../src/integrations/machine-github.ts"
import { ssoRefusal } from "../src/policy-gate.ts"
import { post, signedInWithInstall } from "./cloud-bind-support.ts"
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

describe("joined machine GitHub token: gates", { timeout: 60_000 }, () => {
  it("runs the team's SSO gate on the machine's principal, which shows no SSO sign-in, so an SSO team refuses it", async () => {
    const a = await signedInWithInstall("joined-sso", "cli")
    const { gh } = await linkGitHub(a.session, a.team)
    const seen: Principal[] = []
    const enforced = { sso_required: true, minimum_version: null, allowed_classes: [] }
    // The live gate with this team's rules set to sso.enforce (turning it on needs a live IdP: policy-gate.test.ts).
    const sso = async (_env: unknown, p: Principal) => {
      seen.push(p)
      const refusal = ssoRefusal(p, enforced, p.team)
      return refusal ? { principal: p, refusal } : { principal: p }
    }
    const reply = await joinedMachineToken(testEnv as unknown as Env, { machine: "mach_sso1", team: a.team, user: a.user, repo: "acme/web", permissions: { contents: "write" } }, { sso: sso as any })
    expect(reply, JSON.stringify(reply)).toMatchObject({ ok: false, status: 403, code: "auth.sso_required" })
    expect((reply as { message: string }).message).toContain("a joined machine has no SSO sign-in")
    expect(seen).toMatchObject([{ kind: "install", install_kind: "joined", team: a.team, user: a.user, bound_machine: "mach_sso1" }])
    expect(seen[0]!.sso_team).toBeUndefined()
    // A gate that cannot be evaluated fails closed too.
    const down = await joinedMachineToken(testEnv as unknown as Env, { machine: "mach_sso1", team: a.team, user: a.user, repo: "acme/web", permissions: { contents: "read" } }, { sso: (async () => { throw new Error("TeamDO down") }) as any })
    expect(down).toMatchObject({ ok: false, status: 503, code: "integration.unavailable" })
    expect(gh.mints()).toHaveLength(0)
  })

  it("is on by default in every environment, and PLATFORM_MACHINE_GITHUB \"off\" refuses every method", async () => {
    const a = await signedInWithInstall("joined-off", "cli")
    const { gh } = await linkGitHub(a.session, a.team)
    const ask = { machine: "mach_off1", team: a.team, user: a.user, repo: "acme/web", permissions: { contents: "read" } } as const
    for (const environment of ["development", "staging", "production", "test"]) {
      expect(machineGitHubOn({ ...testEnv, PLATFORM_MACHINE_GITHUB: undefined, ENVIRONMENT: environment } as unknown as Env)).toBe(true)
    }
    for (const env of [{ ...testEnv, PLATFORM_MACHINE_GITHUB: "off" }, { ...testEnv, PLATFORM_MACHINE_GITHUB: "off", ENVIRONMENT: "production" }]) {
      expect(machineGitHubOn(env as unknown as Env)).toBe(false)
      expect(await joinedMachineToken(env as unknown as Env, ask)).toMatchObject({ ok: false, status: 404, code: "platform.machine_github_off" })
      expect(await revokeJoinedMachineTokens(env as unknown as Env, { machine: "mach_off1", team: a.team })).toMatchObject({ ok: false, status: 404, code: "platform.machine_github_off" })
    }
    expect(gh.mints()).toHaveLength(0)
  })

  it("revokes every live token of one joined machine, and only that machine's", async () => {
    const a = await signedInWithInstall("joined-revoke", "cli")
    const { gh } = await linkGitHub(a.session, a.team)
    const entry = (exports as any).MachineGitHub
    for (const machine of ["mach_rv1", "mach_rv2"]) {
      const minted = await entry.joinedMachineToken({ machine, team: a.team, user: a.user, repo: "acme/web", permissions: { contents: "read" } })
      expect(minted.ok, JSON.stringify(minted)).toBe(true)
    }
    expect(await entry.revokeJoinedMachineTokens({ machine: "mach_rv1", team: a.team })).toEqual({ ok: true, value: { revoked: 1 } })
    expect(await entry.revokeJoinedMachineTokens({ machine: "mach_rv1", team: a.team })).toEqual({ ok: true, value: { revoked: 0 } })
    await inDO(testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(a.team)), async (instance) => {
      const rows = instance.ctx.storage.sql.exec("SELECT principal, revoking FROM github_tokens ORDER BY principal").toArray() as Array<{ principal: string; revoking: number }>
      expect(rows.filter((r) => r.revoking === 0).map((r) => r.principal)).toEqual(["machine:mach_rv2"])
    })
    // The revoked machine asking again mints a new token instead of reusing the revoked one.
    const again = await entry.joinedMachineToken({ machine: "mach_rv1", team: a.team, user: a.user, repo: "acme/web", permissions: { contents: "read" } })
    expect([again.ok, gh.mints().length]).toEqual([true, 3])
    expect(await entry.revokeJoinedMachineTokens({ machine: "", team: a.team })).toMatchObject({ ok: false, status: 400 })
  })

  it("rate-limits a person's joined machines together, not one bucket per machine", async () => {
    const a = await signedInWithInstall("joined-rate", "cli")
    await linkGitHub(a.session, a.team)
    // The minter's bucket in this team, emptied: any of their machines (a new one too) waits.
    await inDO(testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(a.team)), async (instance) => {
      instance.ghBuckets.set(`joined-user:${a.user}`, { tokens: 0, at: Date.now() })
    })
    for (const machine of ["mach_rate1", "mach_rate2"]) {
      const reply = await joinedMachineToken(testEnv as unknown as Env, { machine, team: a.team, user: a.user, repo: "acme/web", permissions: { contents: "read" } })
      expect(reply, machine).toMatchObject({ ok: false, status: 429, code: "rate_limited" })
    }
  })
})

describe("joined machine GitHub token: a team admin's revoke", { timeout: 60_000 }, () => {
  it("POST /token/revoke {team, machine} revokes that joined machine's tokens", async () => {
    const a = await signedInWithInstall("joined-admin-revoke", "cli")
    await linkGitHub(a.session, a.team)
    const entry = (exports as any).MachineGitHub
    const minted = await entry.joinedMachineToken({ machine: "machine_adm1", team: a.team, user: a.user, repo: "acme/web", permissions: { contents: "read" } })
    expect(minted.ok, JSON.stringify(minted)).toBe(true)
    const both = await post("/v1/integrations/github/token/revoke", a.session, { team: a.team, machine: "machine_adm1", install: a.install })
    expect(both.status).toBe(400)
    // The personal team's owner administers it.
    expect((await post("/v1/integrations/github/token/revoke", a.session, { team: a.team, machine: "machine_adm1" })).body).toEqual({ revoked: 1 })
    expect((await post("/v1/integrations/github/token/revoke", a.session, { team: a.team, machine: "not-a-machine" })).status).toBe(400)
  })
})
