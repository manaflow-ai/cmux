import { env, exports } from "cloudflare:workers"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"

/**
 * Cloud groups, slice 1 (plans/cmux-next/cloud-groups-DESIGN.md section 8.1): the group record lives in
 * TeamDO, the server mints its id, only members read it, and the web hand-off page carries no group data.
 */
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string }
const worker = (exports as unknown as { default: Fetcher }).default
const token = async (sub: string) =>
  new SignJWT({ email: `${sub}@example.com`, email_verified: true, name: sub })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))
const post = async (path: string, t: string, body: unknown, team?: string) =>
  (await (
    await worker.fetch(`https://api.test${path}`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${t}`, ...(team ? { "x-cmux-team": team } : {}) },
      body: JSON.stringify(body)
    })
  ).json()) as any
const op = (t: string, name: string, params: unknown, key: string, team?: string) => post("/v1/ops", t, { op: name, params, idempotency_key: key, origin: "user" }, team)
const read = (t: string, name: string, params: unknown, team?: string) => post("/v1/read", t, { op: name, params }, team)
const signIn = async (sub: string) => {
  const t = await token(sub)
  const team = (await op(t, "user.ensure", {}, "ensure")).value.personal_team as string
  return { t, team }
}

describe("cloud groups (TeamDO)", { timeout: 120_000 }, () => {
  it("group.create mints a grp_ id; a repeat with the same key returns the same group; a client id is refused", async () => {
    const { t } = await signIn("groups-create")
    const a = await op(t, "group.create", { name: "Fix login" }, "g1")
    expect(a.ok, JSON.stringify(a)).toBe(true)
    expect(a.value.id).toMatch(/^grp_[a-z0-9]{20}$/)
    expect(a.value).toMatchObject({ name: "Fix login", archived: false, item_count: 0, role: "owner", default_placement: "local" })
    const again = await op(t, "group.create", { name: "Fix login" }, "g1")
    expect(again.value.id).toBe(a.value.id)
    const list = await read(t, "group.list", {})
    expect(list.value.groups.map((g: { id: string }) => g.id)).toEqual([a.value.id])
    const forged = await op(t, "group.create", { name: "Forged", id: "grp_00000000000000000000" }, "g2")
    expect(forged.ok).toBe(false)
  })

  it("only a member reads a group; group.get answers its record and links without any host", async () => {
    const owner = await signIn("groups-owner")
    const other = await signIn("groups-other")
    const g = (await op(owner.t, "group.create", { name: "Private" }, "g")).value
    const got = await read(owner.t, "group.get", { group: g.id })
    expect(got.value, JSON.stringify(got)).toBeDefined()
    expect(got.value.group.id).toBe(g.id)
    expect(got.value.items).toEqual([])
    expect(got.value.link).toBe(`cmux://group/${g.id}`)
    expect(got.value.web_link).toBe(`https://cloud-api.cmux.dev/g/${g.id}`)
    // Another person, in their own team: the group is not there.
    const miss = await read(other.t, "group.get", { group: g.id })
    expect(miss.value, JSON.stringify(miss)).toBeUndefined()
    expect(JSON.stringify(miss)).toContain("selector.not_found")
    // Another person naming the owner's team: not a member of it.
    const forbidden = await read(other.t, "group.get", { group: g.id }, owner.team)
    expect(forbidden.value, JSON.stringify(forbidden)).toBeUndefined()
  })

  it("group.add_workspace keeps placement; the same workspace twice is one row; a workspace in another group is a conflict", async () => {
    const { t } = await signIn("groups-items")
    const g1 = (await op(t, "group.create", { name: "One" }, "c1")).value
    const g2 = (await op(t, "group.create", { name: "Two" }, "c2")).value
    const add = await op(t, "group.add_workspace", { group: g1.id, workspace: "ws_44220fb62e6d67c82e50c9faf18eb4c3", placement: { kind: "cloud_vm", machine: "vm-1" }, title: "Login" }, "a1")
    expect(add.ok, JSON.stringify(add)).toBe(true)
    expect(add.value).toMatchObject({ workspace: "ws_44220fb62e6d67c82e50c9faf18eb4c3", placement: { kind: "cloud_vm", machine: "vm-1" }, position: 0 })
    const again = await op(t, "group.add_workspace", { group: g1.id, workspace: "ws_44220fb62e6d67c82e50c9faf18eb4c3", placement: { kind: "local", host: "lawbook0" } }, "a2")
    expect(again.ok).toBe(true)
    await op(t, "group.add_workspace", { group: g1.id, workspace: "ws_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", placement: { kind: "mini", host: "cmux15" } }, "a3")
    const got = (await read(t, "group.get", { group: g1.id })).value
    expect(got.group.item_count).toBe(2)
    expect(got.items.map((i: { workspace: string; placement: { kind: string } }) => [i.workspace, i.placement.kind])).toEqual([
      ["ws_44220fb62e6d67c82e50c9faf18eb4c3", "local"],
      ["ws_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "mini"]
    ])
    const clash = await op(t, "group.add_workspace", { group: g2.id, workspace: "ws_44220fb62e6d67c82e50c9faf18eb4c3", placement: { kind: "local" } }, "a4")
    expect(clash.ok).toBe(false)
    expect(clash.error?.code ?? clash.code).toBe("conflict")
  })

  it("rename and archive; an archived group still answers group.get and leaves group.list unless asked", async () => {
    const { t } = await signIn("groups-archive")
    const g = (await op(t, "group.create", { name: "Old" }, "c")).value
    expect((await op(t, "group.rename", { group: g.id, name: "New" }, "r")).value.name).toBe("New")
    expect((await op(t, "group.archive", { group: g.id }, "x")).value.archived).toBe(true)
    expect((await read(t, "group.get", { group: g.id })).value.group).toMatchObject({ name: "New", archived: true })
    expect((await read(t, "group.list", {})).value.groups).toEqual([])
    expect((await read(t, "group.list", { include_archived: true })).value.groups.map((x: { id: string }) => x.id)).toEqual([g.id])
  })

  it("GET /g/<id> is a hand-off page with the cmux:// link and no group data; a bad id is 404", async () => {
    const { t } = await signIn("groups-link")
    const g = (await op(t, "group.create", { name: "Secret project name" }, "c")).value
    const page = await worker.fetch(`https://api.test/g/${g.id}`)
    expect(page.status).toBe(200)
    expect(page.headers.get("content-type")).toContain("text/html")
    const body = await page.text()
    expect(body).toContain(`cmux://group/${g.id}`)
    expect(body).not.toContain("Secret project name")
    expect((await worker.fetch("https://api.test/g/grp_nothex!")).status).toBe(404)
  })
})
