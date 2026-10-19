import { afterEach, expect, it, vi } from "vitest"
import { MESH, NATIVE, mesh, targetFixture } from "./cloud-vm-api-network-target-support.ts"

afterEach(() => vi.restoreAllMocks())

it("discovers the sole tenant mesh without VM image configuration or owner writes", async () => {
  const f = await targetFixture(), before = await f.owner.debug(f.team.team)
  const reply = await f.read()
  expect(reply.status).toBe(200)
  expect(reply.json.value).toEqual(f.expected)
  expect(f.requests.map((r) => r.url)).toEqual([`${NATIVE}/v1/meshes`])
  const after = await f.owner.debug(f.team.team)
  expect(after.seq).toBe(before.seq)
  expect(after.ledger).toEqual(before.ledger)
})

it("resolves an explicit mesh through the authenticated tenant instead of guessing", async () => {
  const f = await targetFixture()
  f.respond(mesh())
  const reply = await f.read({ mesh: MESH })
  expect(reply.status).toBe(200)
  expect(reply.json.value).toEqual(f.expected)
  expect(f.requests.map((r) => r.url)).toEqual([`${NATIVE}/v1/meshes/${MESH}`])
})

it("reports an absent mesh without silently creating a network", async () => {
  const f = await targetFixture()
  f.respond({ items: [] })
  const reply = await f.read()
  expect(reply.json.error?.code ?? reply.json.code).toBe("selector.not_found")
  expect(f.requests).toHaveLength(1)
})
