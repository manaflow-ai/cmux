import { describe, expect, it } from "vitest"
import { call, DEV_PROJECT, PROD_PROJECT, register, token } from "./helpers.ts"

describe("HTTP API", () => {
  it("health is public", async () => {
    const r = await call("GET", "/v1/health", undefined)
    expect(r).toMatchObject({ status: 200, json: { ok: true, version: "0.14.0", stackProjects: [DEV_PROJECT, PROD_PROJECT] } })
    expect(r.json).toHaveProperty("colo")
  })

  it("rejects missing, forged, wrong-audience and anonymous tokens", async () => {
    expect((await call("GET", "/v1/ice", undefined)).status).toBe(401)
    expect((await call("GET", "/v1/ice", "not-a-jwt")).status).toBe(401)
    expect((await call("GET", "/v1/ice", await token("alice", { audience: "other-project" }))).status).toBe(401)
    expect((await call("GET", "/v1/ice", await token("alice", { anonymous: true }))).status).toBe(401)
    const r = await call("POST", "/v1/devices", undefined, { deviceId: crypto.randomUUID(), kind: "mac", name: "x", teamId: "team-a" })
    expect(r).toMatchObject({ status: 401, json: { error: { code: "unauthorized" } } })
  })

  it("ice always includes Cloudflare STUN", async () => {
    const r = await call("GET", "/v1/ice", await token("alice"))
    expect(r.status).toBe(200)
    expect(r.json.iceServers[0].urls).toContain("stun:stun.cloudflare.com:3478")
    expect(typeof r.json.ttl).toBe("number")
  })

  it("upserts devices, refuses another owner and non-members", async () => {
    const alice = await token("alice")
    const deviceId = crypto.randomUUID()
    const a = await call("POST", "/v1/devices", alice, { deviceId, kind: "mac", name: "Studio", teamId: "team-a" })
    expect(a).toMatchObject({ status: 200, json: { device: { deviceId, kind: "mac", name: "Studio", teamId: "team-a", ownerUserId: "alice", wgPublicKey: null } } })
    const wg = "A".repeat(43) + "="
    const b = await call("POST", "/v1/devices", alice, { deviceId, kind: "mac", name: "Studio 2", teamId: "team-a", wgPublicKey: wg })
    expect(b.json.device).toMatchObject({ name: "Studio 2", wgPublicKey: wg, createdAt: a.json.device.createdAt })
    const stolen = await call("POST", "/v1/devices", await token("bob"), { deviceId, kind: "mac", name: "Mine now", teamId: "team-a" })
    expect(stolen).toMatchObject({ status: 403, json: { error: { code: "not_owner" } } })
    const outsider = await call("POST", "/v1/devices", await token("mallory"), { deviceId: crypto.randomUUID(), kind: "phone", name: "p", teamId: "team-a" })
    expect(outsider).toMatchObject({ status: 403, json: { error: { code: "not_member" } } })
    const bad = await call("POST", "/v1/devices", alice, { deviceId: "nope", kind: "mac", name: "x", teamId: "team-a" })
    expect(bad.status).toBe(400)
  })

  it("lists the caller's own team macs with presence fields, never a teammate's", async () => {
    const bob = await token("bob")
    const id = await register(bob, "mac", "team-a", "Bob's Mac")
    const r = await call("GET", "/v1/teams/team-a/macs", bob)
    expect(r.status).toBe(200)
    expect(r.json.macs.find((m: any) => m.deviceId === id)).toEqual({ deviceId: id, name: "Bob's Mac", online: false, lastSeenAt: null, ownerUserId: "bob" })
    const asAlice = await call("GET", "/v1/teams/team-a/macs", await token("alice"))
    expect(asAlice.status).toBe(200)
    expect(asAlice.json.macs.some((m: any) => m.deviceId === id || m.ownerUserId !== "alice")).toBe(false)
    expect((await call("GET", "/v1/teams/team-a/macs", await token("mallory"))).status).toBe(403)
  })

  it("stores prefs per user per team", async () => {
    const alice = await token("alice")
    expect((await call("GET", "/v1/teams/team-a/prefs", alice)).json).toEqual({ color: null, emoji: null, transparent: false })
    expect((await call("PUT", "/v1/teams/team-a/prefs", alice, { color: "#ff8800" })).json).toEqual({ color: "#FF8800", emoji: null, transparent: false })
    expect((await call("PUT", "/v1/teams/team-a/prefs", alice, { emoji: "🚀" })).json).toEqual({ color: "#FF8800", emoji: "🚀", transparent: false })
    expect((await call("GET", "/v1/teams/team-a/prefs", alice)).json).toEqual({ color: "#FF8800", emoji: "🚀", transparent: false })
    expect((await call("PUT", "/v1/teams/team-a/prefs", alice, { emoji: null })).json).toEqual({ color: "#FF8800", emoji: null, transparent: false })
    expect((await call("GET", "/v1/teams/team-a/prefs", await token("bob"))).json).toEqual({ color: null, emoji: null, transparent: false })
    expect((await call("PUT", "/v1/teams/team-a/prefs", alice, { color: "red" })).status).toBe(400)
    expect((await call("PUT", "/v1/teams/team-a/prefs", alice, { emoji: "ab" })).status).toBe(400)
    expect((await call("PUT", "/v1/teams/team-a/prefs", alice, { emoji: " " })).status).toBe(400)
    expect((await call("PUT", "/v1/teams/team-a/prefs", alice, { emoji: "" })).json).toEqual({ color: "#FF8800", emoji: "", transparent: false })
    expect((await call("GET", "/v1/teams/team-a/prefs", alice)).json).toEqual({ color: "#FF8800", emoji: "", transparent: false })
    expect((await call("PUT", "/v1/teams/team-a/prefs", alice, { emoji: "Q" })).json).toEqual({ color: "#FF8800", emoji: "Q", transparent: false })
    expect((await call("PUT", "/v1/teams/team-a/prefs", alice, { emoji: "👩‍👩‍👧" })).json).toEqual({ color: "#FF8800", emoji: "👩‍👩‍👧", transparent: false })
    expect((await call("PUT", "/v1/teams/team-a/prefs", await token("mallory"), { color: "#000000" })).status).toBe(403)
  })

  it("transparent background only with an icon, keeping the color as the fallback", async () => {
    const bob = await token("bob")
    const url = "/v1/teams/team-a/prefs"
    const put = async (body: unknown) => call("PUT", url, bob, body)
    // No icon: refused, automatic (null) or none ("") alike.
    expect((await put({ color: "#30D158", transparent: true })).status).toBe(400)
    expect((await put({ color: "#30D158", emoji: "", transparent: true })).status).toBe(400)
    expect((await put({ transparent: "yes" })).status).toBe(400)
    expect((await call("GET", url, bob)).json).toEqual({ color: null, emoji: null, transparent: false })
    // With an icon: stored, and the color stays for clients that cannot draw it.
    expect((await put({ color: "#30d158", emoji: "🚀", transparent: true })).json).toEqual({ color: "#30D158", emoji: "🚀", transparent: true })
    expect((await call("GET", url, bob)).json).toEqual({ color: "#30D158", emoji: "🚀", transparent: true })
    // A later emoji-only change keeps it; removing the icon falls back to the stored color.
    expect((await put({ emoji: "Q" })).json).toEqual({ color: "#30D158", emoji: "Q", transparent: true })
    expect((await put({ emoji: null })).json).toEqual({ color: "#30D158", emoji: null, transparent: false })
    // A new icon does not bring transparency back on its own.
    expect((await put({ emoji: "🚀" })).json).toEqual({ color: "#30D158", emoji: "🚀", transparent: false })
    expect((await put({ emoji: "🚀", transparent: true })).json.transparent).toBe(true)
    expect((await put({ emoji: "" })).json).toEqual({ color: "#30D158", emoji: "", transparent: false })
    // A build that predates transparent sends {color, emoji}: picking a color means a filled badge.
    expect((await put({ emoji: "🚀", transparent: true })).json.transparent).toBe(true)
    expect((await put({ color: "#FF453A", emoji: "🚀" })).json).toEqual({ color: "#FF453A", emoji: "🚀", transparent: false })
    expect((await put({ transparent: true })).json).toEqual({ color: "#FF453A", emoji: "🚀", transparent: true })
    expect((await put({ transparent: false })).json).toEqual({ color: "#FF453A", emoji: "🚀", transparent: false })
  })

  it("invites require membership and an email", async () => {
    expect((await call("POST", "/v1/teams/team-a/invites", await token("alice"), {})).status).toBe(400)
    expect((await call("POST", "/v1/teams/team-a/invites", await token("mallory"), { email: "x@example.com" })).status).toBe(403)
    const r = await call("POST", "/v1/teams/team-a/invites", await token("alice"), { email: "x@example.com" })
    expect(r).toMatchObject({ status: 200, json: { sent: true } })
  })

  it("personal space: owner only, no Stack membership, invites refused", async () => {
    // "solo" is in no Stack team at all.
    const solo = await token("solo")
    const team = "personal-solo"
    const deviceId = crypto.randomUUID()
    expect((await call("POST", "/v1/devices", solo, { deviceId, kind: "mac", name: "Solo Mac", teamId: team })).status).toBe(200)
    const macs = await call("GET", `/v1/teams/${team}/macs`, solo)
    expect(macs.json.macs.map((m: any) => m.deviceId)).toEqual([deviceId])
    expect((await call("PUT", `/v1/teams/${team}/prefs`, solo, { color: "#123456" })).json).toEqual({ color: "#123456", emoji: null, transparent: false })
    const inv = await call("POST", `/v1/teams/${team}/invites`, solo, { email: "x@example.com" })
    expect(inv).toMatchObject({ status: 400, json: { error: { code: "bad_request", message: "personal space has no members" } } })
    const alice = await token("alice")
    expect((await call("GET", `/v1/teams/${team}/macs`, alice)).json).toMatchObject({ error: { code: "not_member" } })
    expect((await call("GET", `/v1/teams/${team}/prefs`, alice)).status).toBe(403)
    expect((await call("POST", "/v1/devices", alice, { deviceId: crypto.randomUUID(), kind: "phone", name: "p", teamId: team })).status).toBe(403)
    expect((await call("POST", `/v1/teams/${team}/invites`, alice, { email: "x@example.com" })).status).toBe(403)
  })
})

describe("dev and production Stack projects", () => {
  const prod = (sub: string) => token(sub, { project: PROD_PROJECT })

  it("accepts production tokens and checks iss and aud per project", async () => {
    expect((await call("GET", "/v1/ice", await prod("pat"))).status).toBe(200)
    // Issued by prod but addressed to dev (and the reverse): refused.
    expect((await call("GET", "/v1/ice", await token("pat", { project: PROD_PROJECT, audience: DEV_PROJECT }))).status).toBe(401)
    expect((await call("GET", "/v1/ice", await token("pat", { project: DEV_PROJECT, audience: PROD_PROJECT }))).status).toBe(401)
    // A project the Worker is not configured for.
    const other = "00000000-0000-4000-8000-000000000000"
    expect((await call("GET", "/v1/ice", await token("pat", { project: other }))).status).toBe(401)
    expect((await call("GET", "/v1/ice", await token("pat", { project: PROD_PROJECT, anonymous: true }))).status).toBe(401)
  })

  it("membership comes from the caller's own project", async () => {
    const pat = await prod("pat")
    const mac = await register(pat, "mac", "team-p", "Pat's Mac")
    // Prod alice is a member of team-p (200), but Pat's Mac is Pat's alone.
    const listed = await call("GET", "/v1/teams/team-p/macs", await prod("alice"))
    expect(listed).toEqual({ status: 200, json: { macs: [] } })
    expect((await call("GET", "/v1/teams/team-p/macs", pat)).json.macs).toEqual([{ deviceId: mac, name: "Pat's Mac", online: false, lastSeenAt: null, ownerUserId: "pat" }])
    // Dev alice is in dev team-a, not in prod team-p; prod alice is not in dev team-a.
    expect((await call("GET", "/v1/teams/team-p/macs", await token("alice"))).status).toBe(403)
    expect((await call("GET", "/v1/teams/team-a/macs", await prod("alice"))).status).toBe(403)
    const inv = await call("POST", "/v1/teams/team-p/invites", pat, { email: "x@example.com" })
    expect(inv).toMatchObject({ status: 200, json: { sent: true, url: "https://cmux.com/handler/team-invitation" } })
  })

  it("the same sub in two projects is two users", async () => {
    const devAlice = await token("alice")
    const prodAlice = await prod("alice")
    // Device ownership is (project, sub).
    const deviceId = crypto.randomUUID()
    expect((await call("POST", "/v1/devices", devAlice, { deviceId, kind: "mac", name: "Dev Mac", teamId: "personal-alice" })).status).toBe(200)
    const taken = await call("POST", "/v1/devices", prodAlice, { deviceId, kind: "mac", name: "Mine", teamId: "personal-alice" })
    expect(taken).toMatchObject({ status: 403, json: { error: { code: "not_owner" } } })
    // personal-alice is a separate space per project: Macs and prefs do not cross.
    const prodMac = await register(prodAlice, "mac", "personal-alice", "Prod Mac")
    expect((await call("GET", "/v1/teams/personal-alice/macs", prodAlice)).json.macs.map((m: any) => m.deviceId)).toEqual([prodMac])
    expect((await call("GET", "/v1/teams/personal-alice/macs", devAlice)).json.macs.map((m: any) => m.deviceId)).not.toContain(prodMac)
    expect((await call("PUT", "/v1/teams/personal-alice/prefs", prodAlice, { color: "#0000FF" })).status).toBe(200)
    expect((await call("PUT", "/v1/teams/personal-alice/prefs", devAlice, { color: "#FF0000" })).status).toBe(200)
    expect((await call("GET", "/v1/teams/personal-alice/prefs", prodAlice)).json.color).toBe("#0000FF")
    // The device object keeps its PROTOCOL.md shape (the project is recorded, not returned).
    const r = await call("POST", "/v1/devices", prodAlice, { deviceId: prodMac, kind: "mac", name: "Prod Mac", teamId: "personal-alice" })
    expect(Object.keys(r.json.device).sort()).toEqual(["createdAt", "deviceId", "kind", "lastSeenAt", "name", "ownerUserId", "teamId", "updatedAt", "wgPublicKey"])
  })
})

describe("hub placement", () => {
  it("maps the caller's location to a Durable Object region", async () => {
    const { locationHintFor } = await import("../src/index.ts")
    expect(locationHintFor({ continent: "NA", longitude: "-122.4" })).toBe("wnam")
    expect(locationHintFor({ continent: "NA", longitude: "-74.0" })).toBe("enam")
    expect(locationHintFor({ continent: "EU", longitude: "2.3" })).toBe("weur")
    expect(locationHintFor({ continent: "EU", longitude: "37.6" })).toBe("eeur")
    expect(locationHintFor({ continent: "AS", country: "JP" })).toBe("apac")
    expect(locationHintFor({ continent: "AS", country: "AE" })).toBe("me")
    expect(locationHintFor({ continent: "OC" })).toBe("oc")
    expect(locationHintFor({ continent: "SA" })).toBe("sam")
    expect(locationHintFor({ continent: "AF" })).toBe("afr")
    expect(locationHintFor(undefined)).toBeUndefined()
    expect(locationHintFor({ continent: "AN" })).toBeUndefined()
  })
})
