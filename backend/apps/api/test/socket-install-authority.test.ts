import { env } from "cloudflare:workers"
import { describe, expect, it } from "vitest"
import { signedInWithInstall } from "./cloud-bind-support.ts"
import { authorityClient } from "./install-authority-support.ts"
import { closeTeamSocket, listenToOwnerWire } from "./team-role-socket-support.ts"
import { inDO } from "./team-ssh-support.ts"
import { call } from "./pairing-harness.ts"
import { fireAlarm } from "./setup/alarm.ts"

const world = async () => {
  const p = await signedInWithInstall(`authority-push-${crypto.randomUUID()}`)
  const affected = await authorityClient(p.session, p.user), peer = await authorityClient(p.session, p.user)
  // A persisted pre-cap Mac grant. Its existing one-time migration is the real authority edit.
  await inDO(affected.stub, async (instance) => {
    const state = instance.bind(p.user).currentState
    state.grants[affected.grant] = { ...state.grants[affected.grant],
      op_classes: [...state.grants[affected.grant].op_classes, "execute"] }
    state.migrations = { ...state.migrations, mac_execute_narrow: true }
  })
  return { affected, peer }
}
type Client = Awaited<ReturnType<typeof world>>["affected"]
type Owner = "user" | "team" | "cloud"
const count = (c: Client, owner: Owner) => {
  const ns = (env as unknown as Record<string, DurableObjectNamespace>)[owner.toUpperCase() + "_DO"]!
  const stub = ns.get(ns.idFromName(owner === "user" ? c.user : c.team))
  return inDO(stub, async (_instance, state) => state.getWebSockets().filter((socket) =>
    socket.readyState === WebSocket.READY_STATE_OPEN && socket.deserializeAttachment()?.principal?.install === c.install).length)
}
const narrow = async (c: Client) => {
  await inDO(c.stub, async (instance) => { instance.boundEngine.currentState.migrations.mac_execute_narrow = false })
  const current = await c.stub.installGrant(c.user, c.install, c.grant)
  expect(current.ok).toBe(true)
  expect(current.op_classes).not.toContain("execute")
}

describe("committed install authority changes retire idle owner sockets", { timeout: 60_000 }, () => {
  it.each(["user", "team", "cloud"] as const)("%s: grant narrowing retires only the affected install", async (owner) => {
    const { affected: c, peer } = await world()
    const old = await listenToOwnerWire(c.token, c.team, owner), unaffected = await listenToOwnerWire(peer.token, peer.team, owner)
    try {
      await narrow(c)
      await fireAlarm(c.stub)
      expect(await count(c, owner)).toBe(0)
      expect(await count(peer, owner)).toBe(1)
    } finally { closeTeamSocket(old); closeTeamSocket(unaffected) }
  })

  it("delayed delivery preserves a freshly verified connection of the same install", async () => {
    const { affected: c } = await world(), old = await listenToOwnerWire(c.token, c.team, "cloud")
    await narrow(c)
    const fresh = await listenToOwnerWire(c.token, c.team, "cloud")
    try {
      await fireAlarm(c.stub)
      expect(await count(c, "cloud")).toBe(1)
    } finally { closeTeamSocket(old); closeTeamSocket(fresh) }
  })

  it("presentation changes preserve a current connection", async () => {
    const { affected: c } = await world(), socket = await listenToOwnerWire(c.token, c.team, "cloud")
    try {
      const renamed = await call("/v1/ops", c.token, { op: "install.rename", params: { install: c.install, name: "Renamed" },
        idempotency_key: crypto.randomUUID(), origin: "user" })
      expect(renamed.json.ok).toBe(true)
      await fireAlarm(c.stub)
      expect(await count(c, "cloud")).toBe(1)
    } finally { closeTeamSocket(socket) }
  })

  it("repeated no-op migration preserves the current incarnation", async () => {
    const { affected: c } = await world()
    await narrow(c); await fireAlarm(c.stub)
    const socket = await listenToOwnerWire(c.token, c.team, "cloud")
    try {
      const result = await c.stub.submit(c.user, { identity: "system:user", kind: "system" }, {
        op: "install.mac_execute_narrow", params: {}, idempotency_key: crypto.randomUUID(), origin: "script"
      })
      expect(result.frames.some((frame: { t: string }) => frame.t === "result")).toBe(true)
      await fireAlarm(c.stub)
      expect(await count(c, "cloud")).toBe(1)
    } finally { closeTeamSocket(socket) }
  })

  it("published actors omit private socket incarnation metadata", async () => {
    const { affected: c } = await world(), socket = await listenToOwnerWire(c.token, c.team, "user")
    const event = new Promise<{ actor: Record<string, unknown> }>((resolve, reject) => {
      const cleanup = () => { clearTimeout(deadline); socket.removeEventListener("message", message); socket.removeEventListener("close", closed) }
      const message = (raw: MessageEvent) => {
        try {
          const frame = JSON.parse(raw.data as string)
          if (frame.t === "event" && frame.op === "install.rename") { cleanup(); resolve(frame) }
        } catch { cleanup(); reject(new Error("invalid owner event")) }
      }
      const closed = () => { cleanup(); reject(new Error("owner closed before its event")) }
      // A missing protocol response must fail without leaving a listener or an unbounded wait.
      const deadline = setTimeout(() => { cleanup(); reject(new Error("owner event deadline exceeded")) }, 10_000)
      socket.addEventListener("message", message); socket.addEventListener("close", closed)
    })
    try {
      socket.send(JSON.stringify({ t: "op", op: "install.rename", params: { install: c.install, name: "Renamed" },
        idempotency_key: crypto.randomUUID(), origin: "user" }))
      const frame = await event
      expect(frame.actor).toMatchObject({ user: c.user, install: c.install })
      expect(frame.actor).not.toHaveProperty("install_authority")
    } finally { closeTeamSocket(socket) }
  })
})
