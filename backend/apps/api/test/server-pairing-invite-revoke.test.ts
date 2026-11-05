import { describe, expect, it } from "vitest"
import { b64u, beginPairing, call, op, read, sessionToken, waitFor, worker } from "./pairing-harness.ts"

/**
 * Unpair and revoke for servers paired through an invite (workerd): `server.revoke` (the inviter,
 * who owns the server) and the box's own `install.sign_out` (`cmux server unpair`) both spend the
 * pairing code and void the invite, so the same key cannot be approved, collect or begin again.
 */

let ipSeq = 0
const ip = () => `203.0.113.${++ipSeq}`

const signedIn = async (name: string) => {
  const token = await sessionToken(name)
  await op(token, "user.ensure", {})
  const team = (await read(token, "team.directory", {})).json.value.team as string
  const user = (await read(token, "install.list", {})).json.value.user.id as string
  return { token, team, user }
}

const mint = async (token: string, team: string) =>
  (await call("/v1/ops", token, { op: "server.pair.invite", params: { team }, idempotency_key: crypto.randomUUID(), origin: "user" })).json.value as { invite: string; display: string; watch_secret: string }

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
  return { status: res.status, frames, closes, until }
}

const keyPair = async () => (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair

/** Invite, begin with it, approve as the inviter: a paired server and everything the box holds. */
const pairedThroughInvite = async (name: string) => {
  const owner = await signedIn(name)
  const minted = await mint(owner.token, owner.team)
  const key = await keyPair()
  const begun = await beginPairing(Date.now(), false, ip(), key, {}, minted.display)
  expect(begun.res.status).toBe(200)
  const code = begun.res.json.code as string
  const approveKey = crypto.randomUUID()
  const approved = await op(owner.token, "server.pair.approve", { code, team: owner.team, name: "Studio" }, approveKey)
  expect(approved.json.ok).toBe(true)
  const result = approved.json.value as { host: string; install: string; user: string }
  return { owner, minted, key, code, collect: begun.res.json.collect_secret as string, approveKey, result }
}

const installToken = async (pair: CryptoKeyPair, user: string, install: string) => {
  const ch = await call("/v1/auth/challenge", undefined, { user, install })
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`))
  const tok = await call("/v1/auth/token", undefined, { user, install, nonce: ch.json.nonce, signature: b64u(sig) })
  expect(tok.status).toBe(200)
  return tok.json.access_token as string
}

/** After a revoke: the invite is voided `revoked`, the same key cannot begin, collect or be approved again. */
const expectSpent = async (p: Awaited<ReturnType<typeof pairedThroughInvite>>) => {
  const reconnect = await watch(p.minted.invite, p.minted.watch_secret)
  await reconnect.until(() => reconnect.closes.length > 0)
  expect(reconnect.frames).toEqual([{ t: "voided", reason: "revoked" }])
  expect(reconnect.closes).toEqual([4409])
  // The same key retrying its begin with that invite cannot pair again.
  const again = await beginPairing(Date.now(), false, ip(), p.key, {}, p.minted.invite)
  expect(again.res.status).toBe(409)
  // The box's collect on that code hears refused, not the paired result.
  const box = await waitFor(p.code, p.collect)
  await box.until(() => box.closes.length > 0)
  expect(box.frames).toEqual([{ t: "refused", reason: "revoked" }])
  expect(box.closes).toEqual([4403])
  // Neither a replay of the approval nor a fresh one passes on that record, and preview finds nothing.
  expect((await op(p.owner.token, "server.pair.approve", { code: p.code, team: p.owner.team, name: "Studio" }, p.approveKey)).json).toMatchObject({ ok: false, error: { code: "selector.not_found" } })
  expect((await op(p.owner.token, "server.pair.approve", { code: p.code, team: p.owner.team, name: "Studio" })).json).toMatchObject({ ok: false, error: { code: "selector.not_found" } })
  expect((await read(p.owner.token, "server.pair.preview", { code: p.code })).status).toBe(400)
  const hosts = (await read(p.owner.token, "team.directory", {})).json.value.hosts as Array<{ id: string }>
  expect(hosts.some((h) => h.id === p.result.host)).toBe(false)
}

describe("server.revoke of a server paired through an invite", { timeout: 60_000 }, () => {
  it("the inviter revokes it: the invite is voided revoked, and that key cannot begin, collect or be approved again", async () => {
    const p = await pairedThroughInvite("stack-invite-revoke-owner")
    // A signed-in stranger (another team) cannot revoke it.
    const stranger = await signedIn("stack-invite-revoke-stranger")
    expect((await op(stranger.token, "server.revoke", { host: p.result.host })).json.ok).toBe(false)
    // Before the revoke the box's collect still answers paired (a lost reply recovers).
    const before = await waitFor(p.code, p.collect)
    await before.until(() => before.closes.length > 0)
    expect(before.frames.at(-1)).toMatchObject({ t: "paired", host: p.result.host })

    const revoked = await op(p.owner.token, "server.revoke", { host: p.result.host })
    expect(revoked.json).toMatchObject({ ok: true, value: { host: p.result.host, install_revoked: true } })
    expect(revoked.json.value.pairing).toBeUndefined()
    await expectSpent(p)
  })

  it("a revoke watched live: an inviter's watcher still open on an arrived invite hears voided revoked", async () => {
    const owner = await signedIn("stack-invite-revoke-live")
    const minted = await mint(owner.token, owner.team)
    const watcher = await watch(minted.invite, minted.watch_secret)
    await watcher.until(() => watcher.frames.length >= 1)
    const begun = await beginPairing(Date.now(), false, ip(), undefined, {}, minted.invite)
    await watcher.until(() => watcher.frames.some((f) => f.t === "arrived"))
    const approved = await op(owner.token, "server.pair.approve", { code: begun.res.json.code, team: owner.team, name: "Studio" })
    const host = approved.json.value.host as string
    await watcher.until(() => watcher.closes.length > 0)
    expect(watcher.frames.at(-1)).toEqual({ t: "paired", host })
    expect((await op(owner.token, "server.revoke", { host })).json.ok).toBe(true)
    const later = await watch(minted.invite, minted.watch_secret)
    await later.until(() => later.closes.length > 0)
    expect(later.frames).toEqual([{ t: "voided", reason: "revoked" }])
  })

  it("spends the code of a plain (no invite) pairing too", async () => {
    const owner = await signedIn("stack-plain-revoke")
    const begun = await beginPairing(Date.now(), false, ip())
    const code = begun.res.json.code as string
    const key = crypto.randomUUID()
    const approved = await op(owner.token, "server.pair.approve", { code, team: owner.team, name: "Studio" }, key)
    expect((await op(owner.token, "server.revoke", { host: approved.json.value.host })).json.ok).toBe(true)
    const box = await waitFor(code, begun.res.json.collect_secret)
    await box.until(() => box.closes.length > 0)
    expect(box.frames).toEqual([{ t: "refused", reason: "revoked" }])
    expect((await op(owner.token, "server.pair.approve", { code, team: owner.team, name: "Studio" }, key)).json.ok).toBe(false)
  })
})

describe("the box unpairs itself (install.sign_out from the server's install)", { timeout: 60_000 }, () => {
  it("removes its host from the directory, voids the invite revoked and spends the code; the install token stops working", async () => {
    const p = await pairedThroughInvite("stack-invite-self-unpair")
    const token = await installToken(p.key, p.result.user, p.result.install)
    const out = await call("/v1/ops", token, { op: "install.sign_out", params: {}, idempotency_key: crypto.randomUUID(), origin: "cli" })
    expect(out.json).toMatchObject({ ok: true, value: { id: p.result.install } })
    expect(typeof out.json.value.revoked_at).toBe("number")
    await expectSpent(p)
    expect((await read(token, "install.list", {})).status).toBe(403)
    expect((await call("/v1/auth/challenge", undefined, { user: p.result.user, install: p.result.install })).status).toBe(403)
  })
})
