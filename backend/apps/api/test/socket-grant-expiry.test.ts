import { env } from "cloudflare:workers"
import { decodeJwt } from "jose"
import { describe, expect, it } from "vitest"
import { signedInWithInstall } from "./cloud-bind-support.ts"
import { authorityClient } from "./install-authority-support.ts"
import { closeTeamSocket, listenToOwnerWire } from "./team-role-socket-support.ts"
import { inDO, worker } from "./team-ssh-support.ts"
import { quiesce } from "./setup/alarm.ts"

const client = async () => {
  const signed = await signedInWithInstall(`socket-grant-${crypto.randomUUID()}`)
  return authorityClient(signed.session, signed.user)
}
type Client = Awaited<ReturnType<typeof client>>
const namespaces = env as unknown as Record<"USER_DO" | "TEAM_DO" | "CLOUD_DO", DurableObjectNamespace>
const ownerStub = (c: Client, owner: "user" | "team" | "cloud") => {
  const ns = namespaces[owner === "user" ? "USER_DO" : owner === "team" ? "TEAM_DO" : "CLOUD_DO"]
  return ns.get(ns.idFromName(owner === "user" ? c.user : c.team))
}
const editGrant = (c: Client, change: Record<string, unknown>) => inDO(c.stub, async (instance) => {
  const state = instance.bind(c.user).currentState
  state.grants[c.grant] = { ...state.grants[c.grant], ...change }
})

/** Run the real alarm at its deadline, without waiting for wall time or sending a client frame. */
const socketsAfterAlarm = (c: Client, owner: "user" | "team" | "cloud", at: number) =>
  inDO(ownerStub(c, owner), async (instance, state) => {
    await quiesce(instance, state)
    const realNow = Date.now
    Date.now = () => at
    try {
      await instance.alarm()
      return state.getWebSockets().filter((socket) => socket.readyState === WebSocket.READY_STATE_OPEN).length
    } finally { Date.now = realNow }
  })

describe("owner sockets honor their current grant lifetime", { timeout: 60_000 }, () => {
  it.each(["user", "team", "cloud"] as const)("%s: an idle socket closes at grant expiry before token expiry", async (owner) => {
    const c = await client(), expiry = Date.now() + 60_000
    expect(decodeJwt(c.token).exp! * 1000).toBeGreaterThan(expiry)
    await editGrant(c, { expires_at: expiry })
    const socket = await listenToOwnerWire(c.token, c.team, owner)
    try { expect(await socketsAfterAlarm(c, owner, expiry)).toBe(0) }
    finally { closeTeamSocket(socket) }
  })

  it.each(["later", "unlimited"])("a %s grant never extends the token deadline", async (mode) => {
    const c = await client(), tokenExpiry = decodeJwt(c.token).exp! * 1000
    await editGrant(c, { expires_at: mode === "later" ? tokenExpiry + 60_000 : null })
    const socket = await listenToOwnerWire(c.token, c.team, "cloud")
    try { expect(await socketsAfterAlarm(c, "cloud", tokenExpiry)).toBe(0) }
    finally { closeTeamSocket(socket) }
  })

  it.each(["expired", "revoked", "missing"])("the user wire refuses a %s current grant", async (mode) => {
    const c = await client()
    await inDO(c.stub, async (instance) => {
      const state = instance.bind(c.user).currentState
      if (mode === "missing") delete state.grants[c.grant]
      else state.grants[c.grant] = { ...state.grants[c.grant], [mode === "expired" ? "expires_at" : "revoked_at"]: Date.now() - 1 }
    })
    const response = await worker.fetch("https://api.test/v1/wire/user", { headers: {
      Upgrade: "websocket", Authorization: `Bearer ${c.token}`, "Sec-WebSocket-Protocol": "cmux.wire.v1"
    } })
    if (response.webSocket) { response.webSocket.accept(); closeTeamSocket(response.webSocket) }
    expect(response.status).toBe(403)
  })

  it("periodic owner checks reject an expired grant even while its install is active", async () => {
    const c = await client()
    expect(await c.stub.installsActive(c.user, [{ install: c.install, grant: c.grant }])).toEqual([true])
    await editGrant(c, { expires_at: Date.now() - 1 })
    expect(await c.stub.installsActive(c.user, [{ install: c.install, grant: c.grant }])).toEqual([false])
  })

  it("registration refuses a grant revoked after the Worker checked it", async () => {
    const c = await client()
    await editGrant(c, { revoked_at: Date.now() - 1 })
    expect(await c.stub.registerSocket(c.user, c.install, c.grant, "CloudDO", c.team, Date.now() + 60_000)).toBe(false)
  })
})
