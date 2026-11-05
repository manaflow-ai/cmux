import { describe, expect, it } from "vitest"
import { displayInvite, inviteFromRandom, normalizeCode, normalizeInvite } from "../src/domains/pairing.ts"
import { pairInvite } from "../src/pair-invite-routes.ts"
import { beginPairing, call, op, read, runAlarm, sessionPrincipal, sessionToken, testEnv, worker } from "./pairing-harness.ts"

/**
 * Invite-code pairing (workerd): a signed-in person mints an invite, the new machine begins with
 * it, the inviter's watcher hears every step, and only the inviter may approve.
 */

let ipSeq = 0
const ip = () => `198.51.100.${++ipSeq}`

const signedIn = async (name: string) => {
  const token = await sessionToken(name)
  await op(token, "user.ensure", {})
  const team = (await read(token, "team.directory", {})).json.value.team as string
  const user = (await read(token, "install.list", {})).json.value.user.id as string
  return { token, team, user }
}

const mint = (token: string, team: string, origin = "user") => call("/v1/ops", token, { op: "server.pair.invite", params: { team }, idempotency_key: crypto.randomUUID(), origin })

const watch = async (invite: string, secret: string) => {
  const res = await worker.fetch(`https://api.test/v1/pair/invite/wait?invite=${invite}`, { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": `cmux.pair-invite.v1, watch.${secret}` } })
  const ws = res.webSocket
  const frames: Array<any> = []
  const closes: Array<number> = []
  let wake: (() => void) | null = null
  ws?.addEventListener("message", (e) => {
    frames.push(JSON.parse(e.data as string))
    wake?.()
  })
  ws?.addEventListener("close", (e) => {
    closes.push(e.code)
    wake?.()
  })
  ws?.accept()
  const until = async (pred: () => boolean) => {
    while (!pred()) await new Promise<void>((r) => (wake = r))
  }
  return { status: res.status, protocol: res.headers.get("Sec-WebSocket-Protocol"), frames, closes, until }
}

const waitBox = async (code: string, secret: string) => {
  const res = await worker.fetch(`https://api.test/v1/pair/wait?code=${code}`, { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": `cmux.pair.v1, collect.${secret}` } })
  const ws = res.webSocket
  const frames: Array<any> = []
  const closes: Array<number> = []
  let wake: (() => void) | null = null
  ws?.addEventListener("message", (e) => {
    frames.push(JSON.parse(e.data as string))
    wake?.()
  })
  ws?.addEventListener("close", (e) => {
    closes.push(e.code)
    wake?.()
  })
  ws?.accept()
  const until = async (pred: () => boolean) => {
    while (!pred()) await new Promise<void>((r) => (wake = r))
  }
  return { status: res.status, frames, closes, until }
}

const keyPair = async () => (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair

describe("invite codes (pure)", () => {
  it("are 10 Crockford symbols, shown ABCDE-12345, and never parse as an 8-symbol server code or the other way round", () => {
    const invite = inviteFromRandom(new Uint8Array([0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]))
    expect(invite).toBe("ZZZZZZZZZZ")
    expect(inviteFromRandom(new Uint8Array(7))).toBe("0000000000")
    const random = inviteFromRandom(crypto.getRandomValues(new Uint8Array(7)))
    expect(random).toMatch(/^[0-9A-HJKMNP-TV-Z]{10}$/)
    expect(displayInvite("ABCDE12345")).toBe("ABCDE-12345")
    expect(normalizeInvite("abcde-12345")).toBe("ABCDE12345")
    expect(normalizeInvite("ABCDE 1234O")).toBe("ABCDE12340")
    expect(normalizeInvite("ABCDE-1234L")).toBe("ABCDE12341")
    expect(normalizeInvite("ABCDE-1234U")).toBeNull()
    expect(normalizeInvite("7KQ4-M2XD")).toBeNull()
    expect(normalizeCode("ABCDE-12345")).toBeNull()
    expect(() => inviteFromRandom(new Uint8Array(5))).toThrow()
  })
})

describe("server.pair.invite (mint)", () => {
  it("is for a person's session with origin user, in their own team, with the role to add a server", async () => {
    const owner = await signedIn("stack-invite-mint-owner")
    // An agent acting through the session, an install token, and a non-user origin are refused.
    const frame = { op: "server.pair.invite", params: { team: owner.team }, idempotency_key: "k", origin: "user" }
    const agent = { ...sessionPrincipal(owner.user, owner.team), agent: "agent_x" }
    expect(await pairInvite(testEnv as never, agent as never, frame)).toMatchObject({ ok: false, error: { code: "auth.forbidden" } })
    const install = { kind: "install" as const, identity: "inst_x", user: owner.user, team: owner.team }
    expect(await pairInvite(testEnv as never, install as never, frame)).toMatchObject({ ok: false, error: { code: "auth.forbidden" } })
    expect((await mint(owner.token, owner.team, "cli")).json).toMatchObject({ ok: false, error: { code: "auth.forbidden" } })
    // Another team than the token's.
    expect((await mint(owner.token, "team_00000000000000000099")).json).toMatchObject({ ok: false, error: { code: "auth.forbidden" } })
    // A person who may not add servers (TeamDO says no) gets nothing minted.
    const noRole = { PAIRING_DO: testEnv.PAIRING_DO, ENVIRONMENT: testEnv.ENVIRONMENT, JWT_PRIVATE_JWK: testEnv.JWT_PRIVATE_JWK, TEAM_DO: { idFromName: (n: string) => testEnv.TEAM_DO.idFromName(n), get: () => ({ canEnrollServer: async () => false }) } }
    expect(await pairInvite(noRole as never, sessionPrincipal(owner.user, owner.team) as never, frame)).toMatchObject({ ok: false, error: { code: "auth.forbidden", message: "only team owners and admins may add a server" } })

    const minted = await mint(owner.token, owner.team)
    expect(minted.status).toBe(200)
    expect(minted.json.ok).toBe(true)
    const value = minted.json.value as { invite: string; display: string; expires_at: number; watch_secret: string }
    expect(value.invite).toMatch(/^[0-9A-HJKMNP-TV-Z]{10}$/)
    expect(value.display).toBe(displayInvite(value.invite))
    expect(value.expires_at - Date.now()).toBeGreaterThan(9 * 60_000)
    expect(value.expires_at - Date.now()).toBeLessThanOrEqual(10 * 60_000)
    expect(value.watch_secret).toMatch(/^[A-Za-z0-9_-]{22}\.[0-9a-f]{64}$/)
  })

  it("keeps one live invite per person: a new one voids the old one and its watcher hears it", async () => {
    const owner = await signedIn("stack-invite-one-live")
    const first = (await mint(owner.token, owner.team)).json.value
    const watcher = await watch(first.invite, first.watch_secret)
    expect(watcher.status).toBe(101)
    expect(watcher.protocol).toBe("cmux.pair-invite.v1")
    await watcher.until(() => watcher.frames.length >= 1)
    expect(watcher.frames[0]).toEqual({ t: "pending", expires_at: first.expires_at })
    const second = (await mint(owner.token, owner.team)).json.value
    expect(second.invite).not.toBe(first.invite)
    await watcher.until(() => watcher.closes.length > 0)
    expect(watcher.frames.at(-1)).toEqual({ t: "voided", reason: "replaced" })
    expect(watcher.closes).toEqual([4409])
    // The voided invite is used; the new one still works.
    expect((await beginPairing(Date.now(), false, ip(), undefined, {}, first.invite)).res.status).toBe(409)
    expect((await beginPairing(Date.now(), false, ip(), undefined, {}, second.invite)).res.status).toBe(200)
  })
})

describe("POST /v1/pair/begin with an invite", () => {
  it("refuses a malformed invite 400 and an unknown or expired one 404", async () => {
    for (const bad of ["ABCD", "7KQ4-M2XD", "ABCDE-1234U", "ABCDE-12345-6"]) {
      const { res } = await beginPairing(Date.now(), false, ip(), undefined, {}, bad)
      expect(res.status, bad).toBe(400)
      expect(res.json).toEqual({ error: "invalid invite code" })
    }
    const unknown = await beginPairing(Date.now(), false, ip(), undefined, {}, "ABCDE-12345")
    expect(unknown.res.status).toBe(404)
    expect(unknown.res.json).toEqual({ error: "invite expired or unknown" })

    const owner = await signedIn("stack-invite-expired")
    const minted = (await mint(owner.token, owner.team)).json.value
    const watcher = await watch(minted.invite, minted.watch_secret)
    await watcher.until(() => watcher.frames.length >= 1)
    // The invite's one-shot alarm: the watcher is closed 4408 and the invite is forgotten.
    await runAlarm(testEnv.PAIRING_DO.get(testEnv.PAIRING_DO.idFromName(`invite:${minted.invite}`)))
    await watcher.until(() => watcher.closes.length > 0)
    expect(watcher.closes).toEqual([4408])
    expect((await beginPairing(Date.now(), false, ip(), undefined, {}, minted.invite)).res.status).toBe(404)
    expect((await watch(minted.invite, minted.watch_secret)).status).toBe(404)
  })

  it("redeems once: the inviter's watcher hears arrived (replayed on connect), the same key gets the same code, a different key voids it 409", async () => {
    const owner = await signedIn("stack-invite-redeem")
    const minted = (await mint(owner.token, owner.team)).json.value
    const watcher = await watch(minted.invite, minted.watch_secret)
    await watcher.until(() => watcher.frames.length >= 1)

    const key = await keyPair()
    const first = await beginPairing(Date.now(), false, ip(), key, {}, minted.display.toLowerCase())
    expect(first.res.status).toBe(200)
    expect(first.res.json).toMatchObject({ invited: true, thumbprint: first.thumb })
    expect(["stack-invite-redeem", "stack-invite-redeem@example.com"]).toContain(first.res.json.inviter)
    const code = first.res.json.code as string
    expect(code).toMatch(/^[0-9A-HJKMNP-TV-Z]{8}$/)
    await watcher.until(() => watcher.frames.some((f) => f.t === "arrived"))
    expect(watcher.frames.find((f) => f.t === "arrived")).toEqual({
      t: "arrived", code, info: { name: "Studio", platform: "linux", os_version: "Ubuntu 24.04", arch: "x86_64", cmux_version: "0.1.0" }, thumbprint: first.thumb, country: null, expires_at: first.res.json.expires_at
    })
    // A second watcher connecting late hears pending, then the arrival replayed.
    const late = await watch(minted.invite, minted.watch_secret)
    await late.until(() => late.frames.length >= 2)
    expect(late.frames.map((f) => f.t)).toEqual(["pending", "arrived"])

    // The same box again (a lost reply): the same code, a fresh collect secret that waits.
    const retry = await beginPairing(Date.now(), false, ip(), key, {}, minted.invite)
    expect(retry.res.status).toBe(200)
    expect(retry.res.json.code).toBe(code)
    expect(retry.res.json.collect_secret).not.toBe(first.res.json.collect_secret)
    const box = await waitBox(code, retry.res.json.collect_secret)
    expect(box.status).toBe(101)
    await box.until(() => box.frames.length >= 1)
    expect(box.frames[0]).toMatchObject({ t: "pending" })
    expect((await waitBox(code, first.res.json.collect_secret)).status).toBe(404)

    // A different key: the invite is voided, the first box's pairing is aborted, and the second gets 409.
    const second = await beginPairing(Date.now(), false, ip(), undefined, {}, minted.invite)
    expect(second.res.status).toBe(409)
    expect(second.res.json).toEqual({ error: "invite already used" })
    await watcher.until(() => watcher.closes.length > 0)
    expect(watcher.frames.at(-1)).toEqual({ t: "voided", reason: "second_redemption" })
    expect(watcher.closes).toEqual([4409])
    await box.until(() => box.closes.length > 0)
    expect(box.frames.at(-1)).toEqual({ t: "refused" })
    expect(box.closes).toEqual([4403])
    expect((await read(owner.token, "server.pair.preview", { code })).status).toBe(400)
    // Still used for anyone, the first key included.
    expect((await beginPairing(Date.now(), false, ip(), key, {}, minted.invite)).res.status).toBe(409)
    const reconnect = await watch(minted.invite, minted.watch_secret)
    await reconnect.until(() => reconnect.closes.length > 0)
    expect(reconnect.frames).toEqual([{ t: "voided", reason: "second_redemption" }])
  })

  it("refuses a forged watch secret before any Durable Object wakes, and a collect secret is not a watch secret", async () => {
    const owner = await signedIn("stack-invite-forged-watch")
    const minted = (await mint(owner.token, owner.team)).json.value
    expect((await watch(minted.invite, "AAAAAAAAAAAAAAAAAAAAAA." + "0".repeat(64))).status).toBe(404)
    expect((await watch(minted.invite, "nope")).status).toBe(404)
    const other = (await mint(owner.token, owner.team)).json.value
    expect((await watch(minted.invite, other.watch_secret)).status).toBe(404)
    const plain = await beginPairing(Date.now(), false, ip())
    expect((await watch(other.invite, plain.res.json.collect_secret)).status).toBe(404)
    expect((await worker.fetch(`https://api.test/v1/pair/invite/wait?invite=${other.invite}`)).status).toBe(426)
  })
})

describe("server.pair.approve on an invited record", () => {
  it("only the inviter may approve; the inviter's approval pairs the box and pushes paired to the watcher", async () => {
    const owner = await signedIn("stack-invite-approve-owner")
    const stranger = await signedIn("stack-invite-approve-stranger")
    const minted = (await mint(owner.token, owner.team)).json.value
    const watcher = await watch(minted.invite, minted.watch_secret)
    await watcher.until(() => watcher.frames.length >= 1)
    const begun = await beginPairing(Date.now(), false, ip(), undefined, {}, minted.invite)
    expect(begun.res.status).toBe(200)
    const code = begun.res.json.code as string
    const box = await waitBox(code, begun.res.json.collect_secret)
    await box.until(() => box.frames.length >= 1)
    await watcher.until(() => watcher.frames.some((f) => f.t === "arrived"))

    // Another signed-in person (owner of their own team) is refused and claims nothing.
    const refused = await op(stranger.token, "server.pair.approve", { code, team: stranger.team, name: "Studio" })
    expect(refused.json).toMatchObject({ ok: false, error: { code: "auth.forbidden", message: "only the person who made this invite may approve it" } })

    // The inviter previews (the words come from the thumbprint) and approves.
    const preview = await read(owner.token, "server.pair.preview", { code })
    expect(preview.json.value).toMatchObject({ code, thumbprint: begun.thumb })
    const key = crypto.randomUUID()
    const approved = await op(owner.token, "server.pair.approve", { code, team: owner.team, name: "Studio" }, key)
    expect(approved.json.ok).toBe(true)
    const host = approved.json.value.host as string
    await watcher.until(() => watcher.closes.length > 0)
    expect(watcher.frames.at(-1)).toEqual({ t: "paired", host })
    expect(watcher.closes).toEqual([1000])
    await box.until(() => box.frames.some((f) => f.t === "paired"))
    expect(box.frames.find((f) => f.t === "paired")).toMatchObject({ host, team: owner.team, user: owner.user })

    // A retry of the approval replays, and the paired invite is used.
    expect((await op(owner.token, "server.pair.approve", { code, team: owner.team, name: "Studio" }, key)).json).toMatchObject({ ok: true, value: { host } })
    expect((await beginPairing(Date.now(), false, ip(), undefined, {}, minted.invite)).res.status).toBe(409)
    const reconnect = await watch(minted.invite, minted.watch_secret)
    await reconnect.until(() => reconnect.closes.length > 0)
    expect(reconnect.frames.map((f) => f.t)).toEqual(["pending", "arrived", "paired"])
  })
})
