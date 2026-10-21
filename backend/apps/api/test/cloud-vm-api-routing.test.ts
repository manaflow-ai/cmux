import { env } from "cloudflare:workers"
import { expect, it } from "vitest"
import type { Env } from "../src/env.ts"
import { cloudDriverFor } from "../src/cloud-vm-api-driver.ts"
import { personalTeamIdFor } from "../src/domains/user.ts"
import { deliver, mirroredTeam } from "./team-stack-support.ts"
import { inDO } from "./team-ssh-support.ts"

const e = { ...(env as Env), CLOUD_VM_TRANSPORT: "vm-api", CLOUD_VM_API_ORIGIN: "https://vm.test", CLOUD_VM_API_SERVICE_KEY: "test-service-key", CLOUD_VM_API_IMAGE: "cloud-agent", CLOUD_VM_API_IMAGE_REVISION: "v1" }
const cloud = (team: string) => e.CLOUD_DO.get(e.CLOUD_DO.idFromName(team))
const name = "cmuxnp-test-cld-vm-bbbbbbbbbbbbbbbbbbbb"

it("uses the TeamDO's canonical Stack tenant in actual generated-client requests", async () => {
  const t = await mirroredTeam("Cloud API routing")
  const calls: Request[] = []
  const fetchFn: typeof fetch = async (input, init) => {
    const request = new Request(input, init)
    calls.push(request)
    expect(request.headers.get("x-cmux-team-id")).toBe(t.stackTeam)
    expect(request.headers.get("x-cmux-team-id")).not.toBe(t.team)
    return Response.json({ items: [], nextCursor: null })
  }
  expect(await inDO(cloud(t.team), async (instance) => {
    const driver = await cloudDriverFor(e, instance.sqlStore, t.team, { transport: "vm-api" }, "operate", fetchFn)
    if (!driver) throw new Error("no API driver")
    return driver.peek(name)
  })).toBeNull()
  expect(calls).toHaveLength(1)
})

it("keeps legacy rows direct while missing API settings, personal mappings and future markers fail closed", async () => {
  const t = await mirroredTeam("Cloud API guards")
  const missing = { ...e, CLOUD_VM_API_SERVICE_KEY: undefined }
  expect(await inDO(cloud(t.team), async (instance) => {
    const sql = instance.sqlStore
    return {
      legacy: Boolean(await cloudDriverFor(missing, sql, t.team, {})),
      apiMissing: Boolean(await cloudDriverFor(missing, sql, t.team, { transport: "vm-api" })),
      personal: Boolean(await cloudDriverFor(e, sql, personalTeamIdFor(t.user), { transport: "vm-api" })),
      future: Boolean(await cloudDriverFor(e, sql, t.team, JSON.parse('{"transport":"future"}')))
    }
  })).toEqual({ legacy: true, apiMissing: false, personal: false, future: false })
})

it("refuses deleted-team execution but retains its owner-derived cleanup route", async () => {
  const t = await mirroredTeam("Cloud API cleanup")
  t.w.teams.delete(t.stackTeam)
  expect((await deliver("team.deleted", { id: t.stackTeam })).status).toBe(200)
  expect(await inDO(cloud(t.team), async (instance) => ({
    operate: Boolean(await cloudDriverFor(e, instance.sqlStore, t.team, { transport: "vm-api" }, "operate")),
    cleanup: Boolean(await cloudDriverFor(e, instance.sqlStore, t.team, { transport: "vm-api" }, "cleanup"))
  }))).toEqual({ operate: false, cleanup: true })
})
