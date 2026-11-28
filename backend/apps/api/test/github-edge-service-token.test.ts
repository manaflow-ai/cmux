import { exports } from "cloudflare:workers"
import { describe, expect, it } from "vitest"
import { mintAccessToken } from "../src/auth.ts"
import { edgeGithubToken, handleGithubToken } from "../src/integrations/github-token-route.ts"
import { signedInWithInstall } from "./cloud-bind-support.ts"
import { inDO, linkGitHub, testEnv } from "./github-token-support.ts"

/**
 * The platform edge's GitHub token mint without a platform-held signing key (MachineEdgeSignin.githubToken,
 * github-token-route.ts edgeGithubToken): every gate of the vmSelf edge path, the edge must carry the machine, and a
 * guest-minted bearer still never gets a GitHub token.
 */
const MACHINE = `vm_${"4".repeat(20)}`, OTHER_MACHINE = `vm_${"5".repeat(20)}`

const setup = async (sub: string) => {
  const a = await signedInWithInstall(sub, "cli")
  const { gh } = await linkGitHub(a.session, a.team)
  const userDO = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(a.user))
  const edit = (f: (s: any) => void) => inDO(userDO, async (i) => f(i.boundEngine.currentState))
  const vmInstall = async (classes: Array<string> = ["vm-self"], extra: Record<string, unknown> = {}) => {
    const id = `inst_vm${crypto.randomUUID().replace(/-/g, "").slice(0, 18)}`, grant = `grant_${crypto.randomUUID().replace(/-/g, "").slice(0, 20)}`
    await edit((s) => {
      s.installs[id] = { ...s.installs[a.install], id, kind: "vm", grant, revoked_at: null, bound_team: a.team, bound_machine: MACHINE, ...extra }
      s.grants[grant] = { id: grant, grantee: id, op_classes: classes, approval: "none", expires_at: null, revoked_at: null, created_from: "install" }
    })
    return { install: id, grant }
  }
  // cmux-platform's cloud.vm.self.get over PLATFORM: the install's own live machine, and whether its edge carries it.
  const live = new Set([MACHINE]), edged = new Set([MACHINE])
  const reads: Array<string> = []
  const PLATFORM = { fetch: async (req: Request) => {
    const { op, params } = (await req.json()) as { op: string; params: { machine?: string } }
    reads.push(op)
    return op === "cloud.vm.self.get" && live.has(params.machine ?? "") && /^Bearer ./.test(req.headers.get("authorization") ?? "")
      ? Response.json({ op, value: { machine: { id: params.machine }, ...(edged.has(params.machine ?? "") ? { platform_edge: true } : {}) }, stream: "cloud:t", revision: "cloud:1" })
      : Response.json({ _tag: "Forbidden", code: "auth.forbidden", message: "not this machine" }, { status: 403 })
  } }
  const env = { ...testEnv, PLATFORM } as any
  return { a, gh, edit, vmInstall, live, edged, reads, env }
}

describe("edge service GitHub token", { timeout: 60_000 }, () => {
  it("mints for an edge machine's live vm install under its grant, and the reply is the /token answer", async () => {
    const t = await setup("gh-edge-svc-ok")
    const vm = await t.vmInstall()
    const r = await edgeGithubToken(t.env, { team: t.a.team, machine: MACHINE, creator: t.a.user, ...vm, sso_team: null, repo: "acme/web", permissions: { contents: "write" } })
    expect(r.status, JSON.stringify(r.body)).toBe(200)
    expect(r.body).toMatchObject({ repo: "acme/web", permissions: { contents: "write" } })
    expect(typeof (r.body as any).token).toBe("string")
    expect(t.reads).toContain("cloud.vm.self.get")
    // Outside the team's allowlist and connection: refused as /token refuses it.
    const unlinked = await edgeGithubToken(t.env, { team: t.a.team, machine: MACHINE, creator: t.a.user, ...vm, repo: "acme/unlinked", permissions: { contents: "read" } })
    expect([unlinked.status, JSON.stringify(unlinked.body).includes("ghs_")]).toEqual([403, false])
  })

  it("refuses a machine the edge does not carry, a gone machine, another machine, a dead install or grant, and a bad request", async () => {
    const t = await setup("gh-edge-svc-refuse")
    const vm = await t.vmInstall()
    const ask = (over: Record<string, unknown> = {}) => edgeGithubToken(t.env, { team: t.a.team, machine: MACHINE, creator: t.a.user, ...vm, repo: "acme/web", permissions: { contents: "read" }, ...over } as any)
    const code = async (over: Record<string, unknown> = {}) => {
      const r = await ask(over)
      expect(JSON.stringify(r.body).includes("ghs_")).toBe(r.status === 200)
      return r.status === 200 ? "ok" : `${r.status} ${(r.body as any).error.code}`
    }
    expect(await code()).toBe("ok")
    // Edge-only: a machine whose platform edge does not carry it gets nothing from the service mint.
    t.edged.delete(MACHINE)
    expect(await code()).toBe("403 auth.forbidden")
    t.edged.add(MACHINE)
    // vmGate: no longer the install's live machine.
    t.live.delete(MACHINE)
    expect(await code()).toBe("403 auth.forbidden")
    t.live.add(MACHINE)
    expect(await code({ machine: OTHER_MACHINE })).toBe("403 auth.forbidden")
    expect(await code({ team: "team_" + "9".repeat(20) })).toBe("403 auth.forbidden")
    expect(await code({ creator: "user_99999999999999999999" })).toBe("403 auth.forbidden")
    expect(await code({ install: t.a.install })).toBe("403 auth.forbidden")
    expect(await code({ team: "not-a-team" })).toBe("400 request.invalid")
    expect(await code({ permissions: {} })).toBe("400 request.invalid")
    expect(await code({ repo: 7 })).toBe("400 request.invalid")
    const noSelf = await t.vmInstall(["read"])
    expect(await code(noSelf)).toBe("403 auth.forbidden")
    // An install registered under SSO: the platform's copy must name the same team.
    const sso = await t.vmInstall(["vm-self"], { sso_team: "team_" + "1".repeat(20) })
    expect(await code({ ...sso, sso_team: "team_" + "2".repeat(20) })).toBe("403 auth.forbidden")
    expect(await code({ ...sso, sso_team: null })).toBe("403 auth.forbidden")
    await t.edit((s) => { s.grants[vm.grant] = { ...s.grants[vm.grant], expires_at: Date.now() - 1 } })
    expect(await code()).toBe("403 auth.forbidden")
    await t.edit((s) => { s.grants[vm.grant] = { ...s.grants[vm.grant], expires_at: null }; s.installs[vm.install] = { ...s.installs[vm.install], revoked_at: 1 } })
    expect(await code()).toBe("403 auth.forbidden")
  })

  it("a guest-minted bearer still never gets a GitHub token on an edge machine", async () => {
    const t = await setup("gh-edge-svc-guest")
    const vm = await t.vmInstall()
    // The guest's own bearer (edge sign-in or its install key: never the `edge` claim) on /token and the seam.
    const guestIn = async (envIn: any) => (await mintAccessToken(envIn, { user: t.a.user, team: t.a.team, install: vm.install, grant: vm.grant, vm: true })).token
    const guest = await guestIn(testEnv)
    for (const sub of ["token", "machine-token"]) {
      // The machine-only seam answers only in a deployed environment; a token's issuer names its environment.
      const envIn = sub === "machine-token" ? { ...t.env, ENVIRONMENT: "production" } : t.env
      const res = await handleGithubToken(new Request(`https://api.test/v1/integrations/github/${sub}`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${await guestIn(envIn)}` }, body: JSON.stringify({ team: t.a.team, repo: "acme/web", permissions: { contents: "read" } }) }), envIn, sub)
      const text = await res.text()
      expect([sub, res.status, JSON.parse(text).error.code, text.includes("ghs_")]).toEqual([sub, 403, "github.edge_only", false])
    }
    // The service mint is no HTTP route: the public path set is unchanged.
    const res = await (exports as any).default.fetch(new Request("https://api.test/v1/integrations/github/edge-token", { method: "POST", headers: { authorization: `Bearer ${guest}` }, body: "{}" }))
    expect(res.status).toBe(404)
  })

  it("is on the MachineEdgeSignin entrypoint, and answers without a token when the platform is not bound", async () => {
    const t = await setup("gh-edge-svc-entry")
    const vm = await t.vmInstall()
    const r = await (exports as any).MachineEdgeSignin.githubToken({ team: t.a.team, machine: MACHINE, creator: t.a.user, ...vm, repo: "acme/web", permissions: { contents: "read" } })
    // The test Worker binds no PLATFORM: vmGate cannot read the machine, so it retries and mints nothing.
    expect([r.status, r.body.error.code, JSON.stringify(r).includes("ghs_")]).toEqual([503, "integration.unavailable", false])
  })
})
