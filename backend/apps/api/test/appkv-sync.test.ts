import { describe, expect, it } from "vitest"
import { env } from "cloudflare:workers"
import { runInDurableObject as runIn } from "cloudflare:test"
import { Schema } from "effect"
import { AppKvList } from "../../../packages/protocol/src/ops-appkv.ts"
import { callOp, callRead, makeTenant, mintInstallToken, succeeded, worker, type Tenant } from "./setup/tenant.ts"

/**
 * Synced app storage (`storage:synced`, cmuxterm-hq#12221) end to end through the Worker: two
 * installs of one person write the UserDO `appkv:<user>` stream over `POST /v1/ops` and each sees
 * the other's writes, as rows over `/v1/wire/user` and through `appkv.list`. Another person can
 * neither read nor write them, a retry with the same idempotency key replays, and the limits
 * answer `app.limit`.
 */

/** A second install of the tenant's account (another device), with its token. */
const secondInstall = async (t: Tenant, kind: string) => {
  const keyPair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
  const jwk = (await crypto.subtle.exportKey("jwk", keyPair.publicKey)) as JsonWebKey
  const reg = await callOp(t.session, "install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x!, y: jwk.y! }, kind, name: `${t.canary} ${kind}`, device_name: `${t.canary} ${kind} device`, platform: kind === "ios" ? "ios" : "macos" })
  expect(succeeded(reg), reg.raw).toBe(true)
  const install = reg.body.value.id as string
  const token = await mintInstallToken({ user: t.user, install, keyPair })
  expect(token).toBeDefined()
  return { install, token: token! }
}

/** The user socket with the appkv stream subscribed: collected frames and a wait. */
const openSocket = async (token: string, user: string) => {
  const res = await worker.fetch("https://api.test/v1/wire/user", { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": "cmux.wire.v1", authorization: `Bearer ${token}` } })
  const ws = res.webSocket!
  const frames: Array<any> = []
  let wake: (() => void) | undefined
  ws.addEventListener("message", (e) => {
    frames.push(JSON.parse(e.data as string))
    wake?.()
  })
  ws.accept()
  const until = async (pred: () => boolean) => {
    while (!pred()) await new Promise<void>((r) => (wake = r))
  }
  ws.send(JSON.stringify({ t: "subscribe", stream: `appkv:${user}`, pending: [] }))
  await until(() => frames.some((f) => (f.t === "snapshot" && f.stream === `appkv:${user}`) || f.t === "error"))
  return { ws, frames, until }
}

const set = (token: string, params: unknown, key: string = crypto.randomUUID()) => callOp(token, "appkv.set", params, key)

describe("synced app storage (appkv) through the Worker", { timeout: 60_000 }, () => {
  it("two installs of one person see each other's writes; the last write wins", async () => {
    const alice = await makeTenant("appkv-alice", "mac")
    const phone = await secondInstall(alice, "ios")
    const mac = await openSocket(alice.installToken, alice.user)
    const ios = await openSocket(phone.token, alice.user)
    expect(mac.frames.find((f) => f.t === "snapshot")).toMatchObject({ stream: `appkv:${alice.user}`, state: { revision: 0, apps: {} } })

    const first = await set(alice.installToken, { app: "cmux/todo", key: "item:1", value: { title: "milk", done: false } })
    expect(succeeded(first), first.raw).toBe(true)
    expect(first.body.value).toMatchObject({ app: "cmux/todo", key: "item:1", value: { title: "milk", done: false }, revision: 1 })
    expect(first.body.stream).toBe(`appkv:${alice.user}`)
    // The phone's socket receives the Mac's write as a row upsert.
    await ios.until(() => ios.frames.some((f) => f.t === "event" && f.op === "appkv.set"))
    const event = ios.frames.find((f) => f.t === "event" && f.op === "appkv.set")
    expect(event.effects.writes[0]).toMatchObject({ table: "item", op: "upsert", row: { app: "cmux/todo", key: "item:1", value: { title: "milk", done: false }, revision: 1 } })

    // The phone checks it off; the Mac sees it, and the newer write wins.
    expect(succeeded(await set(phone.token, { app: "cmux/todo", key: "item:1", value: { title: "milk", done: true } }))).toBe(true)
    await mac.until(() => mac.frames.filter((f) => f.t === "event" && f.op === "appkv.set").length === 2)
    const page = await callRead(alice.installToken, "appkv.list", {})
    expect(succeeded(page), page.raw).toBe(true)
    expect(page.body.value.rows).toEqual([expect.objectContaining({ app: "cmux/todo", key: "item:1", value: { title: "milk", done: true }, revision: 2 })])
    expect(page.body.value.next_after_revision).toBeNull()
    expect(page.body.stream).toBe(`appkv:${alice.user}`)
    expect(page.body.value.revision).toBe(page.body.revision)
    expect(Schema.is(AppKvList.result)(page.body.value)).toBe(true)

    // A delete removes the row on both devices.
    expect(succeeded(await callOp(phone.token, "appkv.delete", { app: "cmux/todo", key: "item:1" }))).toBe(true)
    await mac.until(() => mac.frames.some((f) => f.t === "event" && f.op === "appkv.delete"))
    expect(mac.frames.find((f) => f.t === "event" && f.op === "appkv.delete").effects.writes[0]).toMatchObject({ table: "item", op: "delete" })
    expect((await callRead(alice.session, "appkv.list", {})).body.value.rows).toEqual([])

    // A write over the socket works too (the daemon may send ops on its subscription).
    mac.ws.send(JSON.stringify({ t: "op", op: "appkv.set", params: { app: "cmux/todo", key: "item:2", value: "eggs" }, idempotency_key: "socket-1" }))
    await ios.until(() => ios.frames.some((f) => f.t === "event" && f.op === "appkv.set" && f.effects?.writes?.[0]?.row?.key === "item:2"))
    mac.ws.close()
    ios.ws.close()
  })

  it("another person can neither read, subscribe to nor write someone's synced storage", async () => {
    const owner = await makeTenant("appkv-owner", "mac")
    const other = await makeTenant("appkv-other", "mac")
    expect(succeeded(await set(owner.installToken, { app: "notes", key: "secret", value: owner.canary }))).toBe(true)
    // The other person's calls land on their own UserDO: they see only their own (empty) store.
    const read = await callRead(other.installToken, "appkv.list", {})
    expect(succeeded(read)).toBe(true)
    expect(read.raw).not.toContain(owner.canary)
    expect(read.body.value.rows).toEqual([])
    // Subscribing to the owner's stream from the other person's socket is refused.
    const sock = await openSocket(other.installToken, owner.user)
    expect(sock.frames.some((f) => f.t === "snapshot" && f.stream === `appkv:${owner.user}`)).toBe(false)
    expect(JSON.stringify(sock.frames)).not.toContain(owner.canary)
    sock.ws.close()
    // Their writes never reach the owner's store.
    expect(succeeded(await set(other.installToken, { app: "notes", key: "secret", value: "overwritten" }))).toBe(true)
    expect((await callRead(owner.installToken, "appkv.list", {})).body.value.rows).toEqual([expect.objectContaining({ key: "secret", value: owner.canary })])
  })

  it("an install whose grant has no read class can write but neither read nor subscribe", async () => {
    const t = await makeTenant("appkv-narrow", "mac")
    expect(succeeded(await set(t.installToken, { app: "notes", key: "secret", value: t.canary }))).toBe(true)
    const keyPair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
    const jwk = (await crypto.subtle.exportKey("jwk", keyPair.publicKey)) as JsonWebKey
    const reg = await callOp(t.session, "install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x!, y: jwk.y! }, kind: "cli", name: `${t.canary} narrow`, device_name: `${t.canary} narrow device`, platform: "macos", op_classes: ["mutate-own"] })
    expect(succeeded(reg), reg.raw).toBe(true)
    const narrow = (await mintInstallToken({ user: t.user, install: reg.body.value.id as string, keyPair }))!
    // A refused read answers 403 with the code at the top of the body.
    const read = await callRead(narrow, "appkv.list", {})
    expect(read.status, read.raw).toBe(403)
    expect(read.body.code, read.raw).toBe("auth.forbidden")
    expect(read.raw).not.toContain(t.canary)
    const sock = await openSocket(narrow, t.user)
    expect(sock.frames.some((f) => f.t === "snapshot" && f.stream === `appkv:${t.user}`)).toBe(false)
    expect(JSON.stringify(sock.frames)).not.toContain(t.canary)
    sock.ws.close()
  })

  it.each(["removed", "narrowed"])("an already subscribed install stops reading after its access is %s", async (change) => {
    const t = await makeTenant(`appkv-${change}`, "mac")
    const sock = await openSocket(t.installToken, t.user)
    const userEnv = env as unknown as { USER_DO: DurableObjectNamespace }
    const stub = userEnv.USER_DO.get(userEnv.USER_DO.idFromName(t.user))
    const runInside = runIn as unknown as <T>(stub: unknown, fn: (instance: any) => Promise<T>) => Promise<T>
    await runInside(stub, async (instance) => {
      // Registration eviction drops the install and grant; narrowing keeps the install but drops read.
      const state = instance.boundEngine.currentState
      const grant = state.installs[t.install].grant
      if (change === "removed") {
        delete state.installs[t.install]
        delete state.grants[grant]
      } else state.grants[grant].op_classes = ["mutate-own"]
    })
    expect(succeeded(await set(t.session, { app: "notes", key: "secret", value: t.canary }))).toBe(true)
    sock.ws.send(JSON.stringify({ t: "snapshot.request", stream: `appkv:${t.user}` }))
    // The refusal is a socket-order barrier after the write: no timing-based negative assertion.
    await sock.until(() => sock.frames.some((f) => f.t === "error" && f.code === "auth.forbidden"))
    expect(sock.frames.filter((f) => f.t === "snapshot")).toHaveLength(1)
    expect(sock.frames.some((f) => f.t === "event")).toBe(false)
    expect(JSON.stringify(sock.frames)).not.toContain(t.canary)
    sock.ws.close()
  })

  it("pages rows with the declared stream and revision, and rejects fractional limits", async () => {
    const t = await makeTenant("appkv-pages", "mac")
    for (const key of ["a", "b"]) expect(succeeded(await set(t.session, { app: "notes", key, value: key }))).toBe(true)
    const first = await callRead(t.session, "appkv.list", { limit: 1 })
    expect(first.body.value).toMatchObject({ rows: [expect.objectContaining({ key: "a" })], next_after_revision: 1, revision: "2" })
    const second = await callRead(t.session, "appkv.list", { limit: 1, after_revision: first.body.value.next_after_revision })
    expect(second.body.value).toMatchObject({ rows: [expect.objectContaining({ key: "b" })], next_after_revision: null, revision: "2" })
    expect(succeeded(await callRead(t.session, "appkv.list", { limit: 0.5 }))).toBe(false)
  })

  it("a retry with the same idempotency key replays; limits answer app.limit", async () => {
    const t = await makeTenant("appkv-limits", "mac")
    const first = await set(t.installToken, { app: "a", key: "k", value: 1 }, "retry-key")
    const retry = await set(t.installToken, { app: "a", key: "k", value: 1 }, "retry-key")
    expect(succeeded(retry), retry.raw).toBe(true)
    expect(retry.body.replayed).toBe(true)
    expect(retry.body.value).toEqual(first.body.value)
    // The same key with other params is a conflict, not a second write.
    expect((await set(t.installToken, { app: "a", key: "k", value: 2 }, "retry-key")).code).toBe("idempotency.conflict")
    const big = "x".repeat(64 * 1024)
    const tooBig = await set(t.installToken, { app: "a", key: "big", value: big })
    expect(tooBig.code, tooBig.raw).toBe("app.limit")
    expect((await set(t.installToken, { app: "a", key: "", value: 1 })).code).toBe("validation.invalid")
    expect((await callRead(t.installToken, "appkv.list", {})).body.value.rows).toHaveLength(1)
  })
})
