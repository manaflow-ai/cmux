import { env } from "cloudflare:workers"
import { expect, it, vi } from "vitest"
import { CloudDO } from "../src/cloud-do.ts"
import type { Env } from "../src/env.ts"
import { personalTeamIdFor } from "../src/domains/user.ts"
import type { PersonalTenantMarker } from "../src/team-vm-api-personal-store.ts"
import { mirroredTeam, teamStub } from "./team-stack-support.ts"
import { inDO } from "./team-ssh-support.ts"

it("does not create a VM when its intent is cancelled while personal identity provisioning is in flight", async () => {
  const t = await mirroredTeam("Cancel personal provisioning"), team = personalTeamIdFor(t.user)
  let entered = () => {}, resume = () => {}, committed = () => {}
  const provisioning = new Promise<void>((resolve) => { entered = resolve })
  const release = new Promise<void>((resolve) => { resume = resolve })
  const deleted = new Promise<void>((resolve) => { committed = resolve })
  let receipt: { id: string; marker: PersonalTenantMarker } | undefined
  await inDO(teamStub(team), async (instance) => {
    instance.personalStack = {
      find: async () => receipt ? [receipt] : [], members: async () => [t.stackUser],
      create: async (marker: PersonalTenantMarker) => { entered(); await release; receipt = { id: "c38e0227-882f-429c-aa40-dcccb4571fc4", marker }; return receipt }
    }
  })
  let vmCreates = 0
  const spy = vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const r = new Request(input, init)
    if (r.method === "POST") { vmCreates++; return Response.json({ message: "unexpected create" }, { status: 503 }) }
    return Response.json({ items: [], nextCursor: null })
  })
  const e = { ...(env as Env), CLOUD_ALLOWED_TEAMS: team, CLOUD_VM_TRANSPORT: "vm-api", CLOUD_VM_API_ORIGIN: "https://vm.test", CLOUD_VM_API_SERVICE_KEY: "test-cancel-key", CLOUD_VM_API_IMAGE: "cloud-agent", CLOUD_VM_API_IMAGE_REVISION: "v1" }
  try {
    await inDO(e.CLOUD_DO.get(e.CLOUD_DO.idFromName(team)), async (_instance, state) => {
      const owner = new CloudDO(state, e), p = { identity: `user:${t.user}`, kind: "session" as const, user: t.user, team }
      // Observe the real delete commit as the readiness signal; no sleeps or store mutation.
      const after = Reflect.get(owner, "afterOp")
      Reflect.set(owner, "afterOp", (...args: unknown[]) => { Reflect.apply(after, owner, args); if (args[1] === "cloud.machine.delete") committed() })
      const creating = owner.submit(team, p, { t: "op", op: "cloud.machine.create", params: { size: { memory_mb: 4096 } }, idempotency_key: "cancel-during-identity-create", origin: "user" })
      await provisioning
      const listed = await owner.readOp(team, p, "cloud.machine.list", {})
      if (!listed.ok) throw new Error("cannot read pending machine")
      const machine = (listed.value as { machines: Array<{ id: string }> }).machines[0]!.id
      const removing = owner.submit(team, p, { t: "op", op: "cloud.machine.delete", params: { machine }, idempotency_key: "delete-during-identity-create", origin: "user" })
      await deleted
      resume()
      await Promise.all([creating, removing])
    })
    expect(vmCreates).toBe(0)
  } finally { resume(); spy.mockRestore() }
}, 60_000)
