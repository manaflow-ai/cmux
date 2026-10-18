import { env } from "cloudflare:workers"
import { expect, it, vi } from "vitest"
import { TeamVmDO } from "../src/team-vm-do.ts"
import type { Env } from "../src/env.ts"
import { personalTeamIdFor } from "../src/domains/user.ts"
import type { PersonalTenantMarker } from "../src/team-vm-api-personal-store.ts"
import { inDO } from "./team-ssh-support.ts"
import { mirroredTeam, teamStub } from "./team-stack-support.ts"
import { teamVmApiService } from "./team-vm-api-service-support.ts"

it("creates and binds a personal Team VM through the tenant API, then keeps its route after defaults change", async () => {
  const t = await mirroredTeam("Team VM API transport"), team = personalTeamIdFor(t.user), tenant = crypto.randomUUID()
  let identityCreates = 0
  await inDO(teamStub(team), async (owner) => {
    let found: Array<{ id: string; marker: PersonalTenantMarker }> = []
    owner.personalStack = { find: async () => found, members: async () => [t.stackUser], create: async (marker: PersonalTenantMarker) => { identityCreates++; const receipt = { id: tenant, marker }; found = [receipt]; return receipt } }
  })
  const service = teamVmApiService(tenant), spy = vi.spyOn(globalThis, "fetch").mockImplementation(service.fetch)
  const e = { ...(env as Env), TEAM_VM_TRANSPORT: "vm-api", TEAM_VM_API_ORIGIN: "https://vm.test", TEAM_VM_API_SERVICE_KEY: "team-transport-test-key", TEAM_VM_API_IMAGE: "team-agent", TEAM_VM_API_IMAGE_REVISION: "v1", TEAM_VM_SLUG_PREFIX: "cmuxnp-dev-tvm-", TEAM_VM_BIND_ENABLED: "1", CLOUD_API_ORIGIN: "https://api.test" }
  const p = { identity: `user:${t.user}`, kind: "session" as const, user: t.user, team }
  try {
    await inDO((env as Env).TEAM_VM_DO.get((env as Env).TEAM_VM_DO.idFromName(team)), async (_instance, state) => {
      let owner = new TeamVmDO(state, e)
      await owner.readOp(team, p, "team_vm.status", {})
      expect(identityCreates).toBe(0)
      const wake = () => owner.ensureAwake(team, p, { t: "op", op: "team_vm.ensure_awake", params: { reason: "ssh" }, idempotency_key: crypto.randomUUID(), origin: "user" })
      const first = await wake(), result = first.frames.find((f) => f.t === "result")
      expect(result?.t).toBe("result")
      const vm = (result as { value: { vm: string } }).value.vm
      expect(vm).toMatch(/^vm_[0-9a-hjkmnp-tv-z]{26}$/)
      expect(service.control.creates).toBe(1)
      expect(service.vms.get(vm)?.install).toMatch(/^inst_/)
      expect(identityCreates).toBe(1)
      service.vms.get(vm)!.state = "paused"
      owner = new TeamVmDO(state, { ...e, TEAM_VM_TRANSPORT: "direct" })
      await owner.readOp(team, p, "team_vm.status", {})
      const resumed = await wake()
      expect(resumed.frames.find((f) => f.t === "result")).toMatchObject({ value: { vm, status: "running" } })
      expect(service.calls.filter((c) => c.path === `/v1/vms/${vm}/start`)).toHaveLength(1)
      expect(service.control.creates).toBe(1)
    })
  } finally { spy.mockRestore() }
})
