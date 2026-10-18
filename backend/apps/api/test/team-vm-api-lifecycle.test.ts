import { expect, it, vi } from "vitest"
import { withTeamVmApi } from "./team-vm-api-owner-support.ts"

it("routes an API VM's retirement, saved files and deletion through its recorded transport after a rebuild to direct", async () => {
  await withTeamVmApi(async (t) => {
    await t.wake()
    const old = (await t.status()).vm!
    await t.restart({ TEAM_VM_TRANSPORT: "direct" })
    const rebuilt = await t.owner.adminAction(t.team, { action: "rebuild", epoch: 1, by: t.user, key: crypto.randomUUID() })
    expect(rebuilt.ok).toBe(true)
    const current = await t.status()
    expect(current.vm).toMatch(/^fakevm-/)
    expect(current.retired).toMatchObject([{ vm: old, state: "paused" }])
    expect(t.service.vms.get(old)?.retired).toBe(true)
    const before = t.service.calls.length
    const exported = await t.owner.adminAction(t.team, { action: "export", vm: old, by: t.user, key: crypto.randomUUID() })
    expect(exported.ok).toBe(true)
    if (!exported.ok) throw Error(exported.code)
    const ticket = String(exported.value.path).split("/").pop()!
    t.service.control.breakNextFileRead = true
    const response = await t.owner.exportDownload(t.team, ticket)
    expect(response.status).toBe(200)
    expect(new TextDecoder().decode(await response.arrayBuffer())).toContain("saved content")
    expect(t.service.control.fileOffsets).toEqual([0, 5])
    expect((await t.owner.exportDownload(t.team, ticket)).status).toBe(404)
    expect(t.service.calls.slice(before).every((c) => c.method === "GET" && c.path.includes("/files/"))).toBe(true)
    t.service.control.forbidden = true
    await expect(t.owner.adminAction(t.team, { action: "delete", vm: old, by: t.user, key: crypto.randomUUID() })).rejects.toThrow("delete HTTP 404")
    expect((await t.owner.ledger(t.team)).rows.find((r) => r.provider_id === old)?.state).toBe("confirmed")
    t.service.control.forbidden = false
    const gone = await t.owner.adminAction(t.team, { action: "delete", vm: old, by: t.user, key: crypto.randomUUID() })
    expect(gone.ok).toBe(true)
    expect(t.service.vms.has(old)).toBe(false)
    expect((await t.owner.ledger(t.team)).rows.find((r) => r.provider_id === old)).toMatchObject({ state: "deleted", transport: "vm-api" })
    expect(t.service.control.creates).toBe(1)
  })
})

it("keeps a legacy VM on direct while a later epoch uses the tenant API", async () => {
  await withTeamVmApi(async (t) => {
    await t.wake()
    const old = (await t.status()).vm!
    expect(old).toMatch(/^fakevm-/)
    expect(t.identityCreates).toBe(0)
    await t.owner.fakeControl({ drop_ledger: true })
    await t.restart({ TEAM_VM_TRANSPORT: "vm-api" })
    await t.wake()
    expect((await t.status()).vm).toBe(old)
    expect(t.service.calls).toHaveLength(0)
    expect((await t.owner.adminAction(t.team, { action: "rebuild", epoch: 1, by: t.user, key: crypto.randomUUID() })).ok).toBe(true)
    expect((await t.status()).vm).toMatch(/^vm_/)
    expect((await t.status()).retired).toMatchObject([{ vm: old, state: "paused" }])
    expect(t.service.calls.some((c) => c.path.includes(old))).toBe(false)
    expect((await t.owner.ledger(t.team)).rows.map((r) => r.transport)).toEqual(["direct", "vm-api"])
  }, { TEAM_VM_TRANSPORT: "direct" })
})

it("replays the pinned create after a lost response and changed image, prefix and deployment default", async () => {
  await withTeamVmApi(async (t) => {
    t.service.control.loseNextCreate = true
    await t.wake()
    expect((await t.status()).vm).toBeNull()
    expect(t.service.control.creates).toBe(1)
    await t.restart({ TEAM_VM_TRANSPORT: "direct", TEAM_VM_API_IMAGE_REVISION: "v2", TEAM_VM_SLUG_PREFIX: "cmuxnp-dev-other-" })
    await t.owner.fakeAlarm(5_000)
    expect((await t.status()).vm).toMatch(/^vm_/)
    expect(t.service.control.creates).toBe(1)
    const posts = t.service.calls.filter((c) => c.method === "POST" && c.path === "/v1/vms")
    expect(posts).toHaveLength(2)
    expect(posts[1]).toEqual(posts[0])
    expect(posts[1]!.body?.image.revision).toBe("v1")
  })
})

it.each(["credential", "deadline", "missing-context", "partial-context"])("refuses an uncertain create after its %s changes without another POST", async (change) => {
  await withTeamVmApi(async (t) => {
    t.service.control.loseNextCreate = true
    await t.wake()
    if (change === "credential") {
      t.service.control.key = "rotated-test-key"
      await t.restart({ TEAM_VM_API_SERVICE_KEY: "rotated-test-key" })
    } else if (change === "deadline") t.state.storage.sql.exec(`UPDATE team_vm_ledger SET api_sent_at = ?`, Date.now() - 23 * 60 * 60_000)
    else if (change === "missing-context") t.state.storage.sql.exec(`UPDATE team_vm_ledger SET api_sent_key = NULL, api_sent_at = NULL`)
    else t.state.storage.sql.exec(`UPDATE team_vm_ledger SET api_sent_at = NULL`)
    await t.owner.fakeAlarm(5_000)
    expect((await t.status()).vm).toBeNull()
    expect(t.service.calls.filter((c) => c.method === "POST" && c.path === "/v1/vms")).toHaveLength(1)
    expect(t.service.control.creates).toBe(1)
    expect((await t.owner.ledger(t.team)).rows[0]?.state).toBe("unconfirmed")
  })
})

it.each([false, true])("replaces a physically missing VM, while lost authorization cannot spend on a replacement: missing=%s", async (missing) => {
  await withTeamVmApi(async (t) => {
    await t.wake()
    const old = (await t.status()).vm!
    if (missing) t.service.vms.get(old)!.present = false
    else t.service.control.forbidden = true
    await t.wake()
    expect(t.service.control.creates).toBe(missing ? 2 : 1)
    expect((await t.status()).epoch).toBe(missing ? 2 : 1)
    if (!missing) expect((await t.status()).vm).toBe(old)
  })
})

it("does not spend on a VM when the wake lease expires during personal-tenant provisioning", async () => {
  await withTeamVmApi(async (t) => {
    let restoreClock = () => {}
    t.onTenantCreate = async () => {
      const expired = Date.now() + 700_000
      const clock = vi.spyOn(Date, "now").mockReturnValue(expired)
      restoreClock = () => { clock.mockRestore() }
    }
    try {
      await t.wake()
      expect(t.identityCreates).toBe(1)
      expect(t.service.calls).toHaveLength(0)
      expect((await t.status()).vm).toBeNull()
      expect((await t.status()).leases).toEqual([])
    } finally { restoreClock() }
  })
})

it("refuses unknown recorded transports without contacting either backend", async () => {
  await withTeamVmApi(async (t) => {
    await t.wake()
    t.state.storage.sql.exec(`UPDATE team_vm_ledger SET transport = 'unknown'`)
    const before = t.service.calls.length
    await t.restart({ TEAM_VM_TRANSPORT: "direct" })
    await t.wake()
    expect(t.service.calls).toHaveLength(before)
    expect(t.service.control.creates).toBe(1)
    expect((await t.status()).last_error?.code).toBe("team_vm.not_configured")
  })
})

it("keeps the production plan gate closed for API-backed Team VMs", async () => {
  await withTeamVmApi(async (t) => {
    const result = await t.wake()
    expect(result.frames.find((f) => f.t === "reject")).toMatchObject({ code: "team_vm.plan_gate_missing" })
    expect(t.identityCreates).toBe(0)
    expect(t.service.calls).toHaveLength(0)
  }, { ENVIRONMENT: "production" })
})

it("refuses a rebuild before changing the current VM if its recorded backend is unconfigured", async () => {
  await withTeamVmApi(async (t) => {
    await t.wake()
    const old = (await t.status()).vm!
    await t.restart({ TEAM_VM_TRANSPORT: "direct", TEAM_VM_API_SERVICE_KEY: undefined })
    const result = await t.owner.adminAction(t.team, { action: "rebuild", epoch: 1, by: t.user, key: crypto.randomUUID() })
    expect(result).toMatchObject({ ok: false, code: "team_vm.not_configured" })
    expect((await t.status()).vm).toBe(old)
    expect((await t.status()).retired ?? []).toEqual([])
  })
})

it("refuses an unknown creation default without provisioning a tenant or using the legacy backend", async () => {
  await withTeamVmApi(async (t) => {
    await t.wake()
    expect((await t.status()).vm).toBeNull()
    expect((await t.status()).last_error?.code).toBe("team_vm.not_configured")
    expect(t.identityCreates).toBe(0)
    expect(t.service.calls).toHaveLength(0)
  }, { TEAM_VM_TRANSPORT: "unknown" })
})
