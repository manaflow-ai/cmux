import { env } from "cloudflare:workers"
import { describe, expect, it } from "vitest"
import type { Env } from "../src/env.ts"
import { pairApprove } from "../src/pair-routes.ts"
import { beginPairing, op, read, sessionPrincipal, sessionToken, testEnv, userSubmit, waitFor } from "./pairing-harness.ts"

const MESH = "mesh_00000000000000000000000000"
const DEVICE = "dev_00000000000000000000000000"
const NATIVE = "native_team_network"
const CODE = "msc_00000000000000000000000000"
type Transport = { session: string; fetch: typeof fetch }
// The old route ignores the extra transport context; the regression still
// executes its real approval path before checking the missing delivery.
const approveNetwork = pairApprove as (...args: [...Parameters<typeof pairApprove>, Transport]) => ReturnType<typeof pairApprove>

const fixture = async () => {
  const token = await sessionToken(`stack-network-${crypto.randomUUID()}`)
  await op(token, "user.ensure", {})
  const team = (await read(token, "team.directory", {})).json.value.team as string
  const user = (await read(token, "install.list", {})).json.value.user.id as string
  const begun = await beginPairing(Date.now(), false, crypto.randomUUID())
  const publicKey = btoa(String.fromCharCode(...new Uint8Array(await crypto.subtle.exportKey("raw", begun.pair.publicKey))))
  const binding = { name: "Studio", wgPublicKey: begun.wg, installPublicKey: publicKey }
  const grant = { code: CODE, deviceId: DEVICE, meshId: MESH, tenantId: NATIVE, expiresAt: new Date(Date.now() + 600_000).toISOString(), binding }
  const owner = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team)) as any
  const calls: Request[] = []
  let response: unknown = grant
  let unavailable = false
  const fetchFn: typeof fetch = async (input, init) => {
    const request = new Request(input, init); calls.push(request)
    if (unavailable) throw new Error("Native response lost")
    return Response.json(response, { status: 201 })
  }
  const e = { ...(env as Env), CLOUD_VM_API_ORIGIN: "https://vm.test", TEAM_DO: {
    idFromName: (id: string) => testEnv.TEAM_DO.idFromName(id),
    get: () => ({
      canEnrollServer: (...args: unknown[]) => owner.canEnrollServer(...args),
      enrollServer: (...args: unknown[]) => owner.enrollServer(...args),
      vmApiTenant: async () => ({ team, tenant: NATIVE, project: testEnv.STACK_PROJECT_ID })
    })
  } } as unknown as Env
  const frame = { op: "server.pair.approve", params: { code: begun.res.json.code, team, name: "Studio", mesh: MESH }, idempotency_key: "network-approval" }
  const approve = (params = frame.params, submit = userSubmit) => approveNetwork(e, sessionPrincipal(user, team), { ...frame, params }, submit as never, { session: token, fetch: fetchFn })
  return { token, team, user, begun, binding, grant, calls, e, frame, approve, setResponse: (value: unknown) => { response = value }, setUnavailable: (value: boolean) => { unavailable = value } }
}

describe("network enrollment over approved server pairing", () => {
  it("uses the authoritative Native tenant and delivers a pinned code only to the collect socket", async () => {
    const f = await fixture()
    const waiter = await waitFor(f.begun.res.json.code, f.begun.res.json.collect_secret)
    await waiter.until(() => waiter.frames.length > 0)
    const approved = await f.approve()
    expect(approved.ok).toBe(true)
    expect(f.calls).toHaveLength(1)
    const request = f.calls[0]!
    expect(request.url).toBe(`https://vm.test/v1/meshes/${MESH}/overlay-server-codes`)
    expect(request.headers.get("authorization")).toBe(`Bearer ${f.token}`)
    expect(request.headers.get("x-cmux-team-id")).toBe(NATIVE)
    expect(request.redirect).toBe("manual")
    expect(await request.json()).toEqual(f.binding)
    expect(approved.value).toMatchObject({ network: { tenant: NATIVE, mesh: MESH, device: DEVICE } })
    expect(JSON.stringify(approved)).not.toContain(CODE)
    await waiter.until(() => waiter.frames.some((frame) => frame.t === "paired"))
    expect(waiter.frames.find((frame) => frame.t === "paired")).toMatchObject({ network_enrollment: { origin: "https://vm.test", ...f.grant } })
    expect(JSON.stringify(waiter.frames)).not.toContain(f.token)
    const retry = await f.approve()
    expect(retry.value).toEqual(approved.value)
    expect(f.calls).toHaveLength(1)
    const reconnected = await waitFor(f.begun.res.json.code, f.begun.res.json.collect_secret)
    await reconnected.until(() => reconnected.frames.length > 0)
    expect(reconnected.frames[0]).toMatchObject({ t: "paired", network_enrollment: { code: CODE } })
    expect((await waitFor(f.begun.res.json.code, "not-the-collect-secret")).status).toBe(404)
    const user = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(f.user)) as any
    const dump = await user.debug(f.user)
    expect(JSON.stringify(dump)).not.toContain(CODE)
    expect(JSON.stringify(dump)).not.toContain(f.token)
    const team = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(f.team)) as any
    expect(JSON.stringify(await team.debug(f.team))).not.toContain(CODE)
  })

  it.each(["tenant", "install", "wireguard", "mesh", "expiry"])("refuses a mismatched %s response before registering an install or host", async (field) => {
    const f = await fixture()
    const wrong = { ...f.grant, binding: { ...f.binding } }
    if (field === "tenant") wrong.tenantId = "different_native_team"
    if (field === "install") wrong.binding.installPublicKey = "B" + "A".repeat(86) + "="
    if (field === "wireguard") wrong.binding.wgPublicKey = "A".repeat(43) + "="
    if (field === "mesh") wrong.meshId = "mesh_11111111111111111111111111"
    if (field === "expiry") wrong.expiresAt = new Date(Date.now() - 1).toISOString()
    f.setResponse(wrong)
    expect((await f.approve()).ok).toBe(false)
    const installs = (await read(f.token, "install.list", {})).json.value.installs
    expect(installs.filter((item: any) => item.kind === "daemon")).toHaveLength(0)
    const hosts = (await read(f.token, "team.directory", {})).json.value.hosts
    expect(hosts.filter((item: any) => item.kind === "server")).toHaveLength(0)
  })

  it("pins the approval intent before an external failure and refuses a changed mesh or name", async () => {
    const f = await fixture(); f.setUnavailable(true)
    const first = await f.approve()
    expect(first.ok).toBe(false)
    f.setUnavailable(false)
    expect((await f.approve({ ...f.frame.params, mesh: "mesh_11111111111111111111111111" })).ok).toBe(false)
    expect((await f.approve({ ...f.frame.params, name: "changed" })).ok).toBe(false)
    expect(f.calls).toHaveLength(1)
    expect((await f.approve()).ok).toBe(true)
    expect(f.calls).toHaveLength(2)
  })

  it("reuses a durably stored grant after install registration loses its response", async () => {
    const f = await fixture()
    const lost: typeof userSubmit = async (...args) => { await userSubmit(...args); throw new Error("install response lost") }
    await expect(f.approve(f.frame.params, lost)).rejects.toThrow("install response lost")
    expect(f.calls).toHaveLength(1)
    expect((await f.approve()).ok).toBe(true)
    expect(f.calls).toHaveLength(1)
    expect((await read(f.token, "install.list", {})).json.value.installs.filter((item: any) => item.kind === "daemon")).toHaveLength(1)
  })
})
