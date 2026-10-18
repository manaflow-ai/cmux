import { env } from "cloudflare:workers"
import { vi } from "vitest"
import { TeamVmDO } from "../src/team-vm-do.ts"
import type { Env } from "../src/env.ts"
import type { TeamVmState } from "../src/domains/team-vm.ts"
import { personalTeamIdFor } from "../src/domains/user.ts"
import type { PersonalTenantMarker } from "../src/team-vm-api-personal-store.ts"
import { inDO } from "./team-ssh-support.ts"
import { mirroredTeam, teamStub } from "./team-stack-support.ts"
import { teamVmApiService } from "./team-vm-api-service-support.ts"

interface Fixture {
  owner: TeamVmDO
  team: string
  user: string
  service: ReturnType<typeof teamVmApiService>
  identityCreates: number
  onTenantCreate: () => void
  restart(overrides: Partial<Env>): Promise<void>
  wake(): ReturnType<TeamVmDO["ensureAwake"]>
  status(): Promise<TeamVmState>
  state: DurableObjectState
}

/** Real TeamDO, TeamVmDO, UserDO, reducers and SQLite; replace only the two external services. */
export const withTeamVmApi = async (run: (t: Fixture) => Promise<void>, overrides: Partial<Env> = {}) => {
  const t = await mirroredTeam("Team VM transport"), team = personalTeamIdFor(t.user), tenant = crypto.randomUUID()
  const service = teamVmApiService(tenant)
  let fixture: Fixture
  await inDO(teamStub(team), async (owner) => {
    let found: Array<{ id: string; marker: PersonalTenantMarker }> = []
    owner.personalStack = { find: async () => found, members: async () => [t.stackUser], create: async (marker: PersonalTenantMarker) => {
      fixture.identityCreates++; fixture.onTenantCreate(); const receipt = { id: tenant, marker }; found = [receipt]; return receipt
    } }
  })
  const spy = vi.spyOn(globalThis, "fetch").mockImplementation(service.fetch)
  let e: Env = { ...(env as Env), TEAM_VM_TRANSPORT: "vm-api", TEAM_VM_API_ORIGIN: "https://vm.test", TEAM_VM_API_SERVICE_KEY: "team-transport-test-key",
    TEAM_VM_API_IMAGE: "team-agent", TEAM_VM_API_IMAGE_REVISION: "v1", TEAM_VM_SLUG_PREFIX: "cmuxnp-dev-tvm-", TEAM_VM_BIND_ENABLED: "1", CLOUD_API_ORIGIN: "https://api.test", ...overrides }
  const p = { identity: `user:${t.user}`, kind: "session" as const, user: t.user, team }
  try {
    await inDO((env as Env).TEAM_VM_DO.get((env as Env).TEAM_VM_DO.idFromName(team)), async (_instance, state) => {
      fixture = { owner: new TeamVmDO(state, e), team, user: t.user, service, state, identityCreates: 0, onTenantCreate: () => {},
        restart: async (next) => { e = { ...e, ...next }; fixture.owner = new TeamVmDO(state, e); await fixture.owner.readOp(team, p, "team_vm.status", {}) },
        wake: () => fixture.owner.ensureAwake(team, p, { t: "op", op: "team_vm.ensure_awake", params: { reason: "ssh" }, idempotency_key: crypto.randomUUID(), origin: "user" }),
        status: async () => { const r = await fixture.owner.readOp(team, p, "team_vm.status", {}); if (!r.ok) throw Error(r.code); return r.value as TeamVmState }
      }
      await fixture.owner.readOp(team, p, "team_vm.status", {})
      await run(fixture)
    })
  } finally { spy.mockRestore() }
}
