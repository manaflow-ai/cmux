import { createExecutionContext, env, runInDurableObject, waitOnExecutionContext } from "cloudflare:test"
import { describe, expect, it } from "vitest"
import handler from "../src/index.ts"
import { memoryStore, type DeviceInput } from "../src/store.ts"
import { userHubName, type TeamHub } from "../src/team-hub.ts"
import { token, worker } from "./helpers.ts"

/**
 * Build spaces (PROTOCOL.md "Build spaces"): a dev build sends `X-Cmux-Build-Space: dev:<slug>`, nightly and
 * stable send nothing. The same signed-in person in three spaces must see three disjoint sets of devices,
 * presence, signaling peers, pushes and prefs.
 */
const HEADER = "x-cmux-build-space"
const A = "dev:a"
const B = "dev:b"
const SPACES = [A, B, ""] as const
const HEX = "cd".repeat(32)
const MACHINE = "0123456789abcdef0123456789abcdef"
const hubs = (env as unknown as { TEAM_HUB: DurableObjectNamespace<TeamHub> }).TEAM_HUB

const headersIn = (space: string, tok?: string): Record<string, string> => ({
  "content-type": "application/json",
  ...(tok ? { authorization: `Bearer ${tok}` } : {}),
  ...(space ? { [HEADER]: space } : {})
})

const callIn = async (space: string, method: string, path: string, tok: string | undefined, body?: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, { method, headers: headersIn(space, tok), ...(body === undefined ? {} : { body: JSON.stringify(body) }) })
  return { status: res.status, json: (await res.json()) as any }
}

const registerIn = async (space: string, tok: string, kind: "mac" | "phone", teamId: string, extra: Record<string, unknown> = {}) => {
  const deviceId = crypto.randomUUID()
  const r = await callIn(space, "POST", "/v1/devices", tok, { deviceId, kind, name: `${kind} in ${space || "stable"}`, teamId, ...extra })
  expect(r.status).toBe(200)
  return deviceId
}

interface Sock {
  ws: WebSocket
  frames: Array<any>
  until(pred: (s: Sock) => boolean): Promise<void>
  send(f: unknown): void
}

const upgrade = (space: string, tok: string, teamId: string, deviceId: string) =>
  worker.fetch(`https://api.test/v1/teams/${teamId}/signal?deviceId=${deviceId}`, { headers: { ...headersIn(space, tok), Upgrade: "websocket" } })

const connectIn = async (space: string, tok: string, teamId: string, deviceId: string): Promise<Sock> => {
  const res = await upgrade(space, tok, teamId, deviceId)
  expect(res.status).toBe(101)
  const ws = res.webSocket!
  const s: Sock = {
    ws,
    frames: [],
    until: async (pred) => {
      const deadline = Date.now() + 3000
      while (!pred(s)) {
        if (Date.now() > deadline) throw new Error(`timed out; frames: ${JSON.stringify(s.frames)}`)
        await new Promise((r) => setTimeout(r, 20))
      }
    },
    send: (f) => ws.send(JSON.stringify(f))
  }
  ws.addEventListener("message", (e) => {
    if (typeof e.data === "string" && e.data !== "pong") s.frames.push(JSON.parse(e.data))
  })
  ws.accept()
  return s
}

/** One person with a Mac and a phone in each of dev:a, dev:b and stable, all in their personal space. */
const threeSpaces = async (sub: string) => {
  const tok = await token(sub)
  const team = `personal-${sub}`
  const macs: Record<string, string> = {}
  const phones: Record<string, string> = {}
  for (const space of SPACES) {
    macs[space] = await registerIn(space, tok, "mac", team)
    phones[space] = await registerIn(space, tok, "phone", team)
  }
  return { tok, team, macs, phones }
}

describe("build space header", () => {
  it("refuses a malformed header with 400 build_space.invalid, never falling back to stable", async () => {
    const tok = await token("bs-bad")
    const bad = ["", "dev:", "dev:A", "dev:-a", "dev:a-", "dev:a_b", "prod:a", "dev", "nightly", "dev:a b", `dev:${"a".repeat(65)}`, "dev:default", "dev:a/b", "user:x"]
    for (const value of bad) {
      const res = await worker.fetch("https://api.test/v1/me/devices", { headers: { authorization: `Bearer ${tok}`, [HEADER]: value } })
      expect({ value, status: res.status }).toEqual({ value, status: 400 })
      expect(((await res.json()) as any).error.code).toBe("build_space.invalid")
    }
    // The longest valid slug (64, the dev tag cap of scripts/lib/mobile-attach.sh) is accepted.
    expect((await callIn(`dev:${"a".repeat(64)}`, "GET", "/v1/me/devices", tok)).status).toBe(200)
    expect((await callIn("dev:a-1-b", "GET", "/v1/me/devices", tok)).status).toBe(200)
  })

  it("refuses every dev space in the production environment", async () => {
    const prodEnv = { ...(env as object), ENVIRONMENT: "prod" } as unknown as Parameters<typeof handler.fetch>[1]
    const run = async (space: string, path: string) => {
      const ctx = createExecutionContext()
      const req = new Request(`https://api.test${path}`, { headers: headersIn(space, await token("bs-prod")) })
      const res = await handler.fetch(req, prodEnv, ctx)
      await waitOnExecutionContext(ctx)
      return { status: res.status, json: (await res.json()) as any }
    }
    const refused = await run(A, "/v1/me/devices")
    expect(refused.status).toBe(403)
    expect(refused.json.error.code).toBe("build_space.not_allowed")
    expect((await run(A, "/v1/health")).status).toBe(403)
    // Stable (no header) is served as before.
    expect((await run("", "/v1/health")).status).toBe(200)
    // Dev and local Workers accept dev spaces (the test Worker is ENVIRONMENT=test).
    expect((await callIn(A, "GET", "/v1/health", undefined)).status).toBe(200)
  })

  it("serves dev spaces only in environments that allow them, so an unknown or missing environment refuses them", async () => {
    const health = async (environment: string | undefined, space: string) => {
      const e = { ...(env as object), ENVIRONMENT: environment } as unknown as Parameters<typeof handler.fetch>[1]
      const ctx = createExecutionContext()
      const res = await handler.fetch(new Request("https://api.test/v1/health", { headers: headersIn(space) }), e, ctx)
      await waitOnExecutionContext(ctx)
      return { status: res.status, code: res.status === 200 ? null : ((await res.json()) as any).error.code }
    }
    for (const environment of ["production", "Prod", "staging", "dev ", "DEV", "", undefined]) {
      expect({ environment, ...(await health(environment, A)) }).toEqual({ environment, status: 403, code: "build_space.not_allowed" })
      expect({ environment, ...(await health(environment, "")) }).toEqual({ environment, status: 200, code: null })
    }
    for (const environment of ["dev", "test", "local"]) expect({ environment, ...(await health(environment, A)) }).toEqual({ environment, status: 200, code: null })
  })
})

describe("build spaces isolate one person's data", () => {
  it("lists only the space's own Macs and devices", async () => {
    const { tok, team, macs, phones } = await threeSpaces("bs-list")
    for (const space of SPACES) {
      const mine = await callIn(space, "GET", "/v1/me/macs", tok)
      expect(mine.status).toBe(200)
      expect(mine.json.macs.map((m: any) => m.deviceId)).toEqual([macs[space]])
      const inTeam = await callIn(space, "GET", `/v1/teams/${team}/macs`, tok)
      expect(inTeam.json.macs.map((m: any) => m.deviceId)).toEqual([macs[space]])
      const devices = await callIn(space, "GET", "/v1/me/devices", tok)
      expect(devices.json.devices.map((d: any) => d.deviceId).sort()).toEqual([macs[space], phones[space]].sort())
    }
  })

  it("bootstrap keeps its parts in the caller's space", async () => {
    const { tok, team, macs } = await threeSpaces("bs-boot")
    const r = await callIn(A, "POST", "/v1/me/bootstrap", tok, { teamId: team, devices: [] })
    expect(r.status).toBe(200)
    expect(r.json.macs.macs.map((m: any) => m.deviceId)).toEqual([macs[A]])
    expect(r.json.myMacs.macs.map((m: any) => m.deviceId)).toEqual([macs[A]])
  })

  it("never finds a device of another space by id", async () => {
    const { tok, macs, phones } = await threeSpaces("bs-byid")
    const body = { eventId: "evt-1", kind: "question", agent: "Claude", place: "repo" }
    for (const [space, other] of [[A, B], [A, ""], ["", A], [B, A]] as const) {
      expect((await callIn(space, "POST", `/v1/devices/${macs[other]}/notify`, tok, body)).status).toBe(404)
      expect((await callIn(space, "PUT", `/v1/devices/${phones[other]}/push`, tok, { token: HEX, environment: "sandbox", topic: "dev.cmux.mobile" })).status).toBe(404)
      expect((await callIn(space, "DELETE", `/v1/devices/${phones[other]}/push`, tok)).status).toBe(404)
      const id = crypto.randomUUID()
      expect((await callIn(space, "POST", `/v1/devices/${macs[other]}/mailbox`, tok, { id, from: phones[space], sealed: "AAAA" })).status).toBe(404)
      expect((await callIn(space, "GET", `/v1/devices/${macs[other]}/mailbox/${id}`, tok)).status).toBe(404)
      expect((await callIn(space, "DELETE", `/v1/devices/${phones[other]}`, tok)).status).toBe(404)
    }
    // Nothing was deleted anywhere.
    for (const space of SPACES) expect((await callIn(space, "GET", "/v1/me/devices", tok)).json.devices).toHaveLength(2)
  })

  it("refuses a device id another user registered in another space and leaves that row alone", async () => {
    const tok = await token("bs-conflict")
    const team = "personal-bs-conflict"
    const id = await registerIn("", tok, "mac", team)
    const other = await token("bs-conflict-2")
    for (const space of [A, B]) {
      const taken = await callIn(space, "POST", "/v1/devices", other, { deviceId: id, kind: "mac", name: "dev copy", teamId: "personal-bs-conflict-2" })
      expect(taken.status).toBe(409)
      expect(taken.json.error.code).toBe("build_space.device_conflict")
    }
    expect((await callIn("", "GET", "/v1/me/macs", tok)).json.macs).toEqual([expect.objectContaining({ deviceId: id, name: "mac in stable" })])
    expect((await callIn(A, "GET", "/v1/me/macs", other)).json.macs).toEqual([])
  })

  it("moves the same user's stable device into the dev space that registers it, with its push token", async () => {
    // A dev build that registered before build spaces holds a stable ("") row; its next registration sends the
    // header. It must not be refused forever: the row (one install of one build) moves to the dev space.
    const tok = await token("bs-move")
    const team = "personal-bs-move"
    const mac = await registerIn("", tok, "mac", team, { machineId: MACHINE })
    const phone = await registerIn("", tok, "phone", team)
    expect((await callIn("", "PUT", `/v1/devices/${phone}/push`, tok, { token: HEX, environment: "sandbox", topic: "dev.cmux.mobile", kinds: ["question"] })).status).toBe(200)
    const stableMac = await connectIn("", tok, team, mac)
    const closed = new Promise<number>((resolve) => stableMac.ws.addEventListener("close", (e) => resolve(e.code)))

    const movedMac = await callIn(A, "POST", "/v1/devices", tok, { deviceId: mac, kind: "mac", name: "mac in dev", teamId: team })
    expect(movedMac.status).toBe(200)
    expect(movedMac.json.device).toMatchObject({ deviceId: mac, name: "mac in dev", machineId: MACHINE })
    expect((await callIn(A, "POST", "/v1/devices", tok, { deviceId: phone, kind: "phone", name: "phone in dev", teamId: team })).status).toBe(200)
    // The stable hub let go of the Mac: its old socket is closed as removed.
    expect(await closed).toBe(4002)

    expect((await callIn("", "GET", "/v1/me/devices", tok)).json.devices).toEqual([])
    expect((await callIn("", "GET", "/v1/me/macs", tok)).json.macs).toEqual([])
    const dev = await callIn(A, "GET", "/v1/me/devices", tok)
    expect(dev.json.devices.map((d: any) => [d.deviceId, d.push]).sort()).toEqual([[mac, false], [phone, true]].sort())
    expect((await callIn(A, "GET", "/v1/me/macs", tok)).json.macs).toEqual([expect.objectContaining({ deviceId: mac, machineId: MACHINE })])
    // Notify in the dev space reaches the moved phone's push registration; stable has none left.
    const body = { eventId: "evt-move", kind: "question", agent: "Claude", place: "repo" }
    expect((await callIn(A, "POST", `/v1/devices/${mac}/notify`, tok, body)).json.wants).toEqual(["question"])
    // The moved device signals in its new space.
    const devMac = await connectIn(A, tok, team, mac)
    devMac.ws.close()
    expect((await upgrade("", tok, team, mac)).status).toBe(403)
  })

  it("moves the same user's device from one dev space to another", async () => {
    // One device id is one install of one build: a build whose dev tag changed takes its device with it.
    const tok = await token("bs-retag")
    const team = "personal-bs-retag"
    const phone = await registerIn(A, tok, "phone", team)
    expect((await callIn(A, "PUT", `/v1/devices/${phone}/push`, tok, { token: HEX, environment: "sandbox", topic: "dev.cmux.mobile" })).status).toBe(200)
    expect((await callIn(B, "POST", "/v1/devices", tok, { deviceId: phone, kind: "phone", name: "retagged", teamId: team })).status).toBe(200)
    expect((await callIn(A, "GET", "/v1/me/devices", tok)).json.devices).toEqual([])
    expect((await callIn(B, "GET", "/v1/me/devices", tok)).json.devices).toEqual([expect.objectContaining({ deviceId: phone, name: "retagged", push: true })])
  })

  it("never gives a machine id to a sibling build of another space", async () => {
    const tok = await token("bs-sibling")
    const team = "personal-bs-sibling"
    const stable = await registerIn("", tok, "mac", team)
    const dev = await registerIn(A, tok, "mac", team, { machineId: MACHINE, siblingDeviceIds: [stable] })
    expect((await callIn("", "GET", "/v1/me/macs", tok)).json.macs).toEqual([expect.not.objectContaining({ machineId: expect.anything() })])
    expect((await callIn(A, "GET", "/v1/me/macs", tok)).json.macs).toEqual([expect.objectContaining({ deviceId: dev, machineId: MACHINE })])
  })

  it("notify reads only the space's phones", async () => {
    const { tok, macs, phones } = await threeSpaces("bs-notify")
    const put = (space: string, kinds: Array<string>) =>
      callIn(space, "PUT", `/v1/devices/${phones[space]}/push`, tok, { token: HEX, environment: "sandbox", topic: "dev.cmux.mobile", kinds })
    expect((await put("", ["question"])).status).toBe(200)
    expect((await put(A, ["completed"])).status).toBe(200)
    const body = { eventId: "evt-1", kind: "completed", agent: "Claude", place: "repo" }
    // `wants` is what the space's phones asked for: dev:a's phone only, never stable's or dev:b's (none).
    expect((await callIn(A, "POST", `/v1/devices/${macs[A]}/notify`, tok, body)).json.wants).toEqual(["completed"])
    expect((await callIn("", "POST", `/v1/devices/${macs[""]}/notify`, tok, body)).json.wants).toEqual(["question"])
    expect((await callIn(B, "POST", `/v1/devices/${macs[B]}/notify`, tok, body)).json.wants).toEqual([])
  })

  it("keeps team prefs per space", async () => {
    const tok = await token("bs-prefs")
    const team = "personal-bs-prefs"
    expect((await callIn(A, "PUT", `/v1/teams/${team}/prefs`, tok, { color: "#112233" })).status).toBe(200)
    expect((await callIn(A, "GET", `/v1/teams/${team}/prefs`, tok)).json.color).toBe("#112233")
    expect((await callIn("", "GET", `/v1/teams/${team}/prefs`, tok)).json.color).toBeNull()
    expect((await callIn(B, "GET", `/v1/teams/${team}/prefs`, tok)).json.color).toBeNull()
  })

  it("DELETE /v1/me in a dev space purges only that space", async () => {
    const { tok, macs } = await threeSpaces("bs-purge")
    expect((await callIn(A, "DELETE", "/v1/me", tok)).json).toEqual({ deleted: { devices: 2 } })
    expect((await callIn(A, "GET", "/v1/me/devices", tok)).json.devices).toEqual([])
    expect((await callIn(B, "GET", "/v1/me/macs", tok)).json.macs.map((m: any) => m.deviceId)).toEqual([macs[B]])
    expect((await callIn("", "GET", "/v1/me/macs", tok)).json.macs.map((m: any) => m.deviceId)).toEqual([macs[""]])
  })
})

describe("build spaces isolate signaling", () => {
  it("hello, presence and admission stay inside the space", async () => {
    const { tok, team, macs, phones } = await threeSpaces("bs-signal")
    const phoneA = await connectIn(A, tok, team, phones[A]!)
    await phoneA.until((s) => s.frames.some((f) => f.type === "hello"))
    expect(phoneA.frames[0].macs.map((m: any) => m.deviceId)).toEqual([macs[A]])

    // Macs of dev:b and stable come online: dev:a's phone hears nothing of them.
    const macB = await connectIn(B, tok, team, macs[B]!)
    const macStable = await connectIn("", tok, team, macs[""]!)
    const macA = await connectIn(A, tok, team, macs[A]!)
    await phoneA.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.deviceId === macs[A] && f.mac.online))
    expect(phoneA.frames.filter((f) => f.type === "presence").map((f) => f.mac.deviceId)).toEqual([macs[A]])

    // dev:a's phone may signal its own space's Mac, never dev:b's or stable's.
    for (const other of [B, ""]) {
      const sessionId = crypto.randomUUID()
      phoneA.send({ type: "signal", to: macs[other], sessionId, payload: { kind: "webrtc-offer", sdp: "v=0" } })
      await phoneA.until((s) => s.frames.some((f) => f.type === "error" && f.sessionId === sessionId))
      expect(phoneA.frames.find((f) => f.type === "error" && f.sessionId === sessionId)).toMatchObject({ code: "not_owner" })
    }
    const ok = crypto.randomUUID()
    phoneA.send({ type: "signal", to: macs[A], sessionId: ok, payload: { kind: "webrtc-offer", sdp: "v=0" } })
    await macA.until((s) => s.frames.some((f) => f.type === "signal" && f.sessionId === ok))
    expect(macB.frames.some((f) => f.type === "signal")).toBe(false)
    expect(macStable.frames.some((f) => f.type === "signal")).toBe(false)

    for (const s of [phoneA, macA, macB, macStable]) s.ws.close()
  })

  it("refuses a socket for a device of another space", async () => {
    const { tok, team, phones, macs } = await threeSpaces("bs-socket")
    expect((await upgrade(A, tok, team, phones[""]!)).status).toBe(403)
    expect((await upgrade("", tok, team, macs[A]!)).status).toBe(403)
    expect((await upgrade(B, tok, team, phones[A]!)).status).toBe(403)
  })
})

describe("build space hubs", () => {
  it("names a dev hub `dev:<slug>|user:<owner>` and keeps stable's `user:<owner>`", () => {
    expect(userHubName("o1")).toBe("user:o1")
    expect(userHubName("o1", "")).toBe("user:o1")
    expect(userHubName("o1", A)).toBe("dev:a|user:o1")
    expect(userHubName("proj:o1", B)).toBe("dev:b|user:proj:o1")
  })

  it("a hub binds its space from its name and keeps it after eviction", async () => {
    const { macs } = await threeSpaces("bs-evict")
    const id = hubs.idFromName(userHubName("bs-evict", A))
    expect(await runInDurableObject(hubs.get(id), (_h, state) => state.id.name)).toBe("dev:a|user:bs-evict")
    const bound = () =>
      runInDurableObject(hubs.get(hubs.idFromString(id.toString())), (_h, state) =>
        Object.fromEntries(state.storage.sql.exec<{ key: string; value: string }>(`SELECT key, value FROM meta WHERE key IN ('owner', 'space')`).toArray().map((r) => [r.key, r.value]))
      )
    expect(await bound()).toEqual({ owner: "bs-evict", space: A })

    // Evict: the next call builds a new instance from storage alone. Woken by id rather than by name, it has no
    // ctx.id.name, which is why the hub keeps the space it bound in its own storage instead of reading the name.
    await runInDurableObject(hubs.get(id), (_h, state) => state.abort("evict")).catch(() => {})
    const stub = hubs.get(hubs.idFromString(id.toString()))
    expect(await runInDurableObject(stub, (_h, state) => state.id.name)).toBeUndefined()
    expect(await bound()).toEqual({ owner: "bs-evict", space: A })
    expect((await stub.macs({ ownerKey: "bs-evict", space: A })).map((m) => m.deviceId)).toEqual([macs[A]])
    // The same owner in another space is never this hub. Called on the instance: a refused RPC through the test
    // pool's stub proxy also surfaces as an unhandled rejection, which fails the run even though it is awaited here.
    await runInDurableObject(stub, async (hub) => {
      await expect(hub.macs("bs-evict")).rejects.toThrow("not this user's hub")
      await expect(hub.macs({ ownerKey: "bs-evict", space: B })).rejects.toThrow("not this user's hub")
    })
    // Stable's hub is untouched and never holds dev:a's Mac.
    const stable = hubs.get(hubs.idFromName(userHubName("bs-evict")))
    expect((await stable.macs("bs-evict")).map((m) => m.deviceId)).toEqual([macs[""]])
  })

  it("a dev hub is never retired as a team hub", async () => {
    const { tok, macs } = await threeSpaces("bs-retire")
    const stub = hubs.get(hubs.idFromName(userHubName("bs-retire", A)))
    expect(await stub.retireTeamHub()).toEqual({ closed: 0 })
    expect((await callIn(A, "GET", "/v1/me/macs", tok)).json.macs.map((m: any) => m.deviceId)).toEqual([macs[A]])
  })
})

describe("store: a device id moves with its owner", () => {
  it("moves the same owner's row and push token to the registering space, never another owner's", async () => {
    const s = memoryStore()
    const id = crypto.randomUUID()
    const phone = (space: string, ownerUserId = "bs-store-move"): DeviceInput => ({ deviceId: id, space, ownerUserId, teamId: "personal-bs-store-move", kind: "phone", name: "p", wgPublicKey: null })
    const first = await s.upsertDevice(phone(""))
    expect(first).toMatchObject({ movedFrom: null, device: { space: "" } })
    await s.setPush({ deviceId: id, space: "", ownerUserId: "bs-store-move", token: "tok-move", environment: "sandbox", topic: "dev.cmux.mobile", kinds: ["question"], mutedMacs: [], previews: true })

    expect(await s.upsertDevice(phone(A, "bs-store-other"))).toBe("other_space")
    expect(await s.upsertDevice(phone("", "bs-store-other"))).toBe("not_owner")

    expect(await s.upsertDevice(phone(A))).toMatchObject({ movedFrom: "", device: { space: A } })
    expect(await s.getDevice("", id)).toBeUndefined()
    expect((await s.getDevice(A, id))?.space).toBe(A)
    expect(await s.listOwnerPush("", "bs-store-move")).toEqual([])
    expect((await s.listOwnerPush(A, "bs-store-move")).map((p) => [p.token, p.space])).toEqual([["tok-move", A]])
    expect(await s.upsertDevice(phone(A))).toMatchObject({ movedFrom: null })
    expect(await s.upsertDevice(phone(B))).toMatchObject({ movedFrom: A, device: { space: B } })
    expect((await s.listOwnerPush(B, "bs-store-move")).map((p) => p.token)).toEqual(["tok-move"])
    await s.deleteOwner("bs-store-move", "all")
  })
})
