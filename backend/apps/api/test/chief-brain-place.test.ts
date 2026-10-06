import { describe, expect, it } from "vitest"
import { b64u, beginPairing, call, op, read, sessionToken, testEnv, waitFor } from "./pairing-harness.ts"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * A chief's brain place (brains/DESIGN-cmux-lawrence.md G8): the user places a chief on a paired
 * server (`brain_place: {host, install}`, session only, a live `daemon` install). The placed
 * server's install then acts as that chief with the chief's rights (its chief token covers
 * mutate-shared, so it can answer in the chief's conversation); every other chief token of a
 * server install keeps the narrow server grant.
 */
const runAlarm = fireAlarm as unknown as (stub: unknown) => Promise<boolean>

/** A paired server of `owner`: its install, host and key (what `optchat-chief cloud pair` holds). */
const pairServer = async (owner: string) => {
  const { res, pair } = await beginPairing()
  const code = res.json.code as string
  const waiter = await waitFor(code, res.json.collect_secret)
  const teamId = (await read(owner, "team.directory", {})).json.value.team as string
  const approved = await op(owner, "server.pair.approve", { code, team: teamId, name: "Brain" })
  expect(approved.json.ok, JSON.stringify(approved.json)).toBe(true)
  await waiter.until(() => waiter.frames.some((f) => f.t === "paired"))
  const result = approved.json.value as { host: string; team: string; user: string; install: string }
  const mint = async (agent?: string) => {
    const ch = await call("/v1/auth/challenge", undefined, { user: result.user, install: result.install })
    const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`))
    return call("/v1/auth/token", undefined, { user: result.user, install: result.install, nonce: ch.json.nonce, signature: b64u(sig), ...(agent ? { agent } : {}) })
  }
  return { ...result, mint }
}

/** Drains UserDO's outbox until the chief's main conversation answers a read. */
const mainReady = async (owner: string, user: string, conversation: string) => {
  const userDO = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))
  for (let i = 0; i < 20; i++) {
    if ((await read(owner, "conversation.history", { conversation, limit: 1 })).status === 200) return
    await runAlarm(userDO)
  }
  throw new Error("main conversation never appeared")
}

describe("chief brain place", { timeout: 60_000 }, () => {
  it("is set on create and update by the user's session, validated, listed, and cleared", async () => {
    const owner = await sessionToken("brain-place-owner")
    await op(owner, "user.ensure", {})
    const server = await pairServer(owner)
    const place = { host: server.host, install: server.install }

    const created = (await op(owner, "chief.create", { brain_place: place }, "chief-default")).json
    expect(created.ok, JSON.stringify(created)).toBe(true)
    expect(created.value).toMatchObject({ brain: "cloud", brain_place: place, rev: 1 })
    const plain = (await op(owner, "chief.create", { display_name: "Plain" })).json.value
    expect(plain.brain_place).toBeNull()

    const list = (await read(owner, "chief.list", {})).json.value.chiefs
    expect(list.find((c: { id: string }) => c.id === created.value.id).brain_place).toEqual(place)

    const moved = (await op(owner, "chief.update", { chief: plain.id, expected_rev: 1, brain_place: place })).json
    expect(moved.value).toMatchObject({ brain_place: place, rev: 2 })
    const cleared = (await op(owner, "chief.update", { chief: plain.id, expected_rev: 2, brain_place: null })).json
    expect(cleared.value).toMatchObject({ brain_place: null, rev: 3 })

    // Only a live daemon (paired server) install of this user, and a host id.
    const mac = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair
    const jwk = (await crypto.subtle.exportKey("jwk", mac.publicKey)) as JsonWebKey
    const macInstall = (await op(owner, "install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x!, y: jwk.y! }, kind: "mac", name: "mac", device_name: "mac", platform: "macos" })).json.value.id as string
    const bad = async (brain_place: unknown) => (await op(owner, "chief.update", { chief: plain.id, expected_rev: 3, brain_place })).json
    expect((await bad({ host: server.host, install: macInstall })).error.code).toBe("validation.invalid")
    expect((await bad({ host: server.host, install: "inst_00000000000000000000" })).error.code).toBe("validation.invalid")
    expect((await bad({ host: "nothost", install: server.install })).error.code).toBe("validation.invalid")

    // An install token (even the server's own) may not place a chief.
    const tok = (await server.mint()).json.access_token as string
    const byInstall = (await op(tok, "chief.update", { chief: plain.id, expected_rev: 3, brain_place: place })).json
    expect(byInstall.ok).toBe(false)
    expect(byInstall.error.code).toBe("auth.forbidden")

    // A revoked server install cannot be placed.
    expect((await op(owner, "server.revoke", { host: server.host })).json.ok).toBe(true)
    expect((await bad(place)).error.code).toBe("validation.invalid")
  })

  it("lets only the placed server answer as its chief (mutate-shared); other chief tokens stay narrow", async () => {
    const owner = await sessionToken("brain-place-grant")
    const user = (await op(owner, "user.ensure", {})).json.value.id as string
    const placed = await pairServer(owner)
    const unplaced = await pairServer(owner)
    const chief = (await op(owner, "chief.create", { brain_place: { host: placed.host, install: placed.install } }, "chief-default")).json.value
    await mainReady(owner, user, chief.main_conversation)

    const send = (token: string, id: string) =>
      op(token, "message.send", { conversation: chief.main_conversation, client_msg_id: id, parts: [{ type: "text", text: `from ${id}` }] }, id)

    const placedTok = (await placed.mint(chief.id)).json.access_token as string
    const sent = (await send(placedTok, "placed-reply")).json
    expect(sent.ok, JSON.stringify(sent)).toBe(true)

    const unplacedTok = (await unplaced.mint(chief.id)).json.access_token as string
    const refused = (await send(unplacedTok, "unplaced-reply")).json
    expect(refused.ok).toBe(false)
    expect(refused.error.message).toContain("grant does not cover mutate-shared")

    // The placed server without the chief (its own install token) keeps read + mutate-own.
    const ownTok = (await placed.mint()).json.access_token as string
    const own = (await send(ownTok, "own-reply")).json
    expect(own.ok).toBe(false)

    // Moving the chief away takes the right with it on the next request.
    expect((await op(owner, "chief.update", { chief: chief.id, expected_rev: chief.rev, brain_place: null })).json.ok).toBe(true)
    const after = (await send((await placed.mint(chief.id)).json.access_token as string, "after-move")).json
    expect(after.ok).toBe(false)
  })

  it("review G8: install tokens never set or clear a place; a revoked placed server and a token for another chief stay narrow", async () => {
    const owner = await sessionToken("brain-place-review")
    const user = (await op(owner, "user.ensure", {})).json.value.id as string
    const server = await pairServer(owner)
    const place = { host: server.host, install: server.install }
    const chief = (await op(owner, "chief.create", { brain_place: place }, "chief-default")).json.value
    const other = (await op(owner, "chief.create", { display_name: "Other" })).json.value
    await mainReady(owner, user, chief.main_conversation)
    await mainReady(owner, user, other.main_conversation)

    // (1) The server's own token and its chief token: no create with a place, no clear, no move.
    for (const tok of [(await server.mint()).json.access_token as string, (await server.mint(chief.id)).json.access_token as string]) {
      expect((await op(tok, "chief.create", { display_name: "Sneaky", brain_place: place })).json.error?.code).toBe("auth.forbidden")
      expect((await op(tok, "chief.update", { chief: chief.id, expected_rev: chief.rev, brain_place: null })).json.error?.code).toBe("auth.forbidden")
      expect((await op(tok, "chief.update", { chief: other.id, expected_rev: other.rev, brain_place: place })).json.error?.code).toBe("auth.forbidden")
    }

    const send = (token: string, conversation: string, id: string) =>
      op(token, "message.send", { conversation, client_msg_id: id, parts: [{ type: "text", text: id }] }, id)
    // (4) The placed server's token for another chief (not placed there) stays narrow.
    const otherTok = (await server.mint(other.id)).json.access_token as string
    expect((await send(otherTok, other.main_conversation, "other-chief")).json.ok).toBe(false)

    // (3) A token minted before the server is revoked loses the chief's rights on the next request.
    const early = (await server.mint(chief.id)).json.access_token as string
    expect((await send(early, chief.main_conversation, "before-revoke")).json.ok).toBe(true)
    expect((await op(owner, "server.revoke", { host: server.host })).json.ok).toBe(true)
    // Refused at authentication (the install is revoked), so the body is an auth error, never ok.
    const late = await send(early, chief.main_conversation, "after-revoke")
    expect(late.status).toBe(401)
    expect(late.json.ok).not.toBe(true)
  })
})
