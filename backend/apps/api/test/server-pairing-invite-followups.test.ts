import { describe, expect, it } from "vitest"
import { beginPairing, call, inDO, op, read, runAlarm, sessionToken, testEnv, worker } from "./pairing-harness.ts"

/**
 * Invite pairing follow-ups (workerd): a minted invite replays for its idempotency key, one live
 * invite per person survives a failure between the Durable Object calls, and a box whose pairing
 * an invite void aborted hears why even when it connects after the abort.
 */

let ipSeq = 0
const ip = () => `198.51.101.${++ipSeq}`

const signedIn = async (name: string) => {
  const token = await sessionToken(name)
  await op(token, "user.ensure", {})
  const team = (await read(token, "team.directory", {})).json.value.team as string
  const user = (await read(token, "install.list", {})).json.value.user.id as string
  return { token, team, user }
}

const mint = (token: string, team: string, key = crypto.randomUUID()) => call("/v1/ops", token, { op: "server.pair.invite", params: { team }, idempotency_key: key, origin: "user" })

/** A WebSocket to the Worker that records frames and close codes. */
const socket = async (url: string, protocols: string) => {
  const res = await worker.fetch(url, { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": protocols } })
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
const watch = (invite: string, secret: string) => socket(`https://api.test/v1/pair/invite/wait?invite=${invite}`, `cmux.pair-invite.v1, watch.${secret}`)
const waitBox = (code: string, secret: string) => socket(`https://api.test/v1/pair/wait?code=${code}`, `cmux.pair.v1, collect.${secret}`)

const owner = (user: string) => testEnv.PAIRING_DO.get(testEnv.PAIRING_DO.idFromName(`invite-user:${user}`)) as any
const inviteDo = (invite: string) => testEnv.PAIRING_DO.get(testEnv.PAIRING_DO.idFromName(`invite:${invite}`)) as any

describe("server.pair.invite is idempotent per person and key (F1)", () => {
  it("a replay returns the original invite and watch secret and voids nothing; another key mints and voids", async () => {
    const me = await signedIn("stack-invite-idem")
    const key = crypto.randomUUID()
    const first = await mint(me.token, me.team, key)
    expect(first.json.ok).toBe(true)
    const watcher = await watch(first.json.value.invite, first.json.value.watch_secret)
    await watcher.until(() => watcher.frames.length >= 1)

    const replay = await mint(me.token, me.team, key)
    expect(replay.json.ok).toBe(true)
    expect(replay.json.value).toEqual(first.json.value)
    expect(replay.json.replayed).toBe(true)
    // Nothing was voided: the invite still redeems and its watcher hears the arrival.
    const begun = await beginPairing(Date.now(), false, ip(), undefined, {}, first.json.value.invite)
    expect(begun.res.status).toBe(200)
    await watcher.until(() => watcher.frames.some((f) => f.t === "arrived"))
    expect(watcher.frames.map((f) => f.t)).toEqual(["pending", "arrived"])
    expect(watcher.closes).toEqual([])

    // The same key for another person is that person's own key.
    const other = await signedIn("stack-invite-idem-other")
    const theirs = await mint(other.token, other.team, key)
    expect(theirs.json.ok).toBe(true)
    expect(theirs.json.value.invite).not.toBe(first.json.value.invite)

    // A new key mints a new invite and voids the first.
    const second = await mint(me.token, me.team)
    expect(second.json.value.invite).not.toBe(first.json.value.invite)
    await watcher.until(() => watcher.closes.length > 0)
    expect(watcher.frames.at(-1)).toEqual({ t: "voided", reason: "replaced" })
    // Replaying the first key now still answers the first invite and changes nothing.
    const late = await mint(me.token, me.team, key)
    expect(late.json.value).toEqual(first.json.value)
    expect((await beginPairing(Date.now(), false, ip(), undefined, {}, second.json.value.invite)).res.status).toBe(200)
  })
})

describe("one live invite per person survives a failure between the Durable Object calls (F2)", () => {
  it("an invite minted by a request that died before it reached the owner is adopted on the owner's alarm and voids the older one", async () => {
    const me = await signedIn("stack-invite-crash")
    const old = (await mint(me.token, me.team)).json.value
    const watcher = await watch(old.invite, old.watch_secret)
    await watcher.until(() => watcher.frames.length >= 1)

    // A request that recorded its key and minted its invite, then lost the Worker before committing.
    const now = Date.now()
    const invite = "Q0Q0Q0Q0Q0"
    expect(await owner(me.user).inviteOwnerBegin("k".repeat(64), invite, me.team, now)).toEqual({ state: "fresh" })
    expect((await inviteDo(invite).inviteMint({ invite, approver: me.user, team: me.team, inviter: null, watch_hash: "h".repeat(64), now })).ok).toBe(true)

    await runAlarm(owner(me.user))
    await watcher.until(() => watcher.closes.length > 0)
    expect(watcher.frames.at(-1)).toEqual({ t: "voided", reason: "replaced" })
    expect((await beginPairing(Date.now(), false, ip(), undefined, {}, old.invite)).res.status).toBe(409)
  })

  it("a request that died before it minted leaves the live invite alone, and the owner's alarm forgets it", async () => {
    const me = await signedIn("stack-invite-crash-early")
    const live = (await mint(me.token, me.team)).json.value
    const key = "j".repeat(64)
    // Recorded a minute ago, so a live request would have minted it by now.
    expect(await owner(me.user).inviteOwnerBegin(key, "R1R1R1R1R1", me.team, Date.now() - 60_000)).toEqual({ state: "fresh" })
    await runAlarm(owner(me.user))
    expect((await beginPairing(Date.now(), false, ip(), undefined, {}, live.invite)).res.status).toBe(200)
    // The forgotten key begins fresh again.
    expect(await owner(me.user).inviteOwnerBegin(key, "S2S2S2S2S2", me.team, Date.now())).toEqual({ state: "fresh" })
  })

  it("a void that failed is retried on the owner's alarm", async () => {
    const me = await signedIn("stack-invite-void-retry")
    const old = (await mint(me.token, me.team)).json.value
    const watcher = await watch(old.invite, old.watch_secret)
    await watcher.until(() => watcher.frames.length >= 1)
    // The owner recorded the replacement, but the void never reached the old invite.
    const now = Date.now()
    const invite = "T3T3T3T3T3"
    await owner(me.user).inviteOwnerBegin("v".repeat(64), invite, me.team, now)
    await inviteDo(invite).inviteMint({ invite, approver: me.user, team: me.team, inviter: null, watch_hash: "h".repeat(64), now })
    await owner(me.user).inviteOwnerCommit("v".repeat(64), invite, now + 600_000, now, { skipVoid: true })
    expect(watcher.closes).toEqual([])
    await runAlarm(owner(me.user))
    await watcher.until(() => watcher.closes.length > 0)
    expect(watcher.frames.at(-1)).toEqual({ t: "voided", reason: "replaced" })
  })
})

describe("review findings on the owner (follow-up review)", () => {
  it("a live invite recorded by the first build's owner table is voided by the next mint", async () => {
    const me = await signedIn("stack-invite-legacy")
    const old = (await mint(me.token, me.team)).json.value
    const watcher = await watch(old.invite, old.watch_secret)
    await watcher.until(() => watcher.frames.length >= 1)
    // The owner object as the first build left it: only the legacy one-row table names the live invite.
    await (inDO as any)(owner(me.user), async (_instance: unknown, state: DurableObjectState) => {
      state.storage.sql.exec(`DELETE FROM pair_invite_live`)
      state.storage.sql.exec(`DELETE FROM pair_invite_mint`)
      state.storage.sql.exec(`CREATE TABLE IF NOT EXISTS pair_invite_owner (id INTEGER PRIMARY KEY CHECK (id = 1), invite TEXT NOT NULL, live_until INTEGER NOT NULL)`)
      state.storage.sql.exec(`INSERT OR REPLACE INTO pair_invite_owner (id, invite, live_until) VALUES (1, ?, ?)`, old.invite, Date.now() + 600_000)
    })
    await mint(me.token, me.team)
    await watcher.until(() => watcher.closes.length > 0)
    expect(watcher.frames.at(-1)).toEqual({ t: "voided", reason: "replaced" })
    expect((await beginPairing(Date.now(), false, ip(), undefined, {}, old.invite)).res.status).toBe(409)
  })

  it("a void that committed but whose abort failed still aborts the bound box on the owner's retry", async () => {
    const me = await signedIn("stack-invite-abort-retry")
    const old = (await mint(me.token, me.team)).json.value
    const begun = await beginPairing(Date.now(), false, ip(), undefined, {}, old.invite)
    expect(begun.res.status).toBe(200)
    const box = await waitBox(begun.res.json.code, begun.res.json.collect_secret)
    await box.until(() => box.frames.length >= 1)
    // The void reached the invite, the abort of its pairing code did not.
    const now = Date.now()
    expect((await inviteDo(old.invite).inviteVoid(old.invite, "replaced", now)).code).toBe(begun.res.json.code)
    expect(box.closes).toEqual([])
    // A newer invite queues the old one's void; the owner's alarm retries it and aborts the box.
    const invite = "W4W4W4W4W4"
    await owner(me.user).inviteOwnerBegin("w".repeat(64), invite, me.team, now)
    await inviteDo(invite).inviteMint({ invite, approver: me.user, team: me.team, inviter: null, watch_hash: "h".repeat(64), now })
    await owner(me.user).inviteOwnerCommit("w".repeat(64), invite, now + 600_000, now, { skipVoid: true })
    await runAlarm(owner(me.user))
    await box.until(() => box.closes.length > 0)
    expect(box.frames.at(-1)).toEqual({ t: "refused", reason: "invite_voided" })
    expect(box.closes).toEqual([4403])
  })
})

describe("an aborted first box hears invite_voided (F3)", () => {
  it("a box that connects after a second redemption voided its invite gets refused with the reason, not a 404", async () => {
    const me = await signedIn("stack-invite-tombstone")
    const invite = (await mint(me.token, me.team)).json.value
    const first = await beginPairing(Date.now(), false, ip(), undefined, {}, invite.invite)
    expect(first.res.status).toBe(200)
    // The first box has not opened its wait yet when another key voids the invite.
    expect((await beginPairing(Date.now(), false, ip(), undefined, {}, invite.invite)).res.status).toBe(409)
    const box = await waitBox(first.res.json.code, first.res.json.collect_secret)
    expect(box.status).toBe(101)
    await box.until(() => box.closes.length > 0)
    expect(box.frames).toEqual([{ t: "refused", reason: "invite_voided" }])
    expect(box.closes).toEqual([4403])
    // The code stays spent: no preview, no approval, no reuse.
    expect((await read(me.token, "server.pair.preview", { code: first.res.json.code })).status).toBe(400)
    expect((await op(me.token, "server.pair.approve", { code: first.res.json.code, team: me.team, name: "Studio" })).json).toMatchObject({ ok: false, error: { code: "selector.not_found" } })
    // A forged collect secret still learns nothing.
    expect((await waitBox(first.res.json.code, "AAAAAAAAAAAAAAAAAAAAAA." + "0".repeat(64))).status).toBe(404)
    // The tombstone ends with the code's alarm.
    await runAlarm(testEnv.PAIRING_DO.get(testEnv.PAIRING_DO.idFromName(first.res.json.code)))
    expect((await waitBox(first.res.json.code, first.res.json.collect_secret)).status).toBe(404)
  })
})
