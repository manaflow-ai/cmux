import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { memberUpsert } from "../src/domains/team-members.ts"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * Participant avatars on the Cloud owner (participant.avatar.set / participant.avatar.get), through
 * the Worker: a person sets their own; the owner sets its Chief's; a Chief token sets none; nobody
 * sets another person's; the type comes from the bytes; one blob per account and content, deleted
 * when no participant references it. A picture is read by the participant, by the owner of a Chief,
 * and by anyone who names a conversation both are in; any other read is selector.not_found.
 */
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; USER_DO: DurableObjectNamespace; TEAM_DO: DurableObjectNamespace; HOME_ATTACHMENTS: R2Bucket }
const worker = (exports as unknown as { default: Fetcher }).default
const sessionToken = async (sub: string) =>
  new SignJWT({ email: `${sub}@example.com`, email_verified: true, name: sub })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))
const call = async (path: string, token: string | undefined, body: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) }, body: JSON.stringify(body) })
  return { status: res.status, json: (await res.json()) as any }
}
const op = (t: string, name: string, params: unknown) => call("/v1/ops", t, { op: name, params, idempotency_key: crypto.randomUUID(), origin: "user" })
const read = (t: string, name: string, params: unknown) => call("/v1/read", t, { op: name, params })
const b64u = (b: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const b64 = (b: Uint8Array) => {
  let s = ""
  for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode(...b.subarray(i, i + 0x8000))
  return btoa(s)
}
const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4, 5])
const GIF = new Uint8Array([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 9, 9, 9])
const sha = async (b: Uint8Array) => [...new Uint8Array(await crypto.subtle.digest("SHA-256", b))].map((x) => x.toString(16).padStart(2, "0")).join("")

const person = async (sub: string) => {
  const session = await sessionToken(sub)
  const ensured = (await op(session, "user.ensure", {})).json.value
  return { session, user: ensured.id as string, team: ensured.personal_team as string }
}
/** Seeds `member` into `owner`'s personal team, so `owner` may put them in a conversation (reach). */
const joinTeam = async (owner: { team: string }, member: { user: string }) => {
  const inDO = runInDurableObject as unknown as (stub: unknown, fn: (instance: any) => Promise<void>) => Promise<void>
  await inDO(testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(owner.team)), async (instance) => {
    instance.boundEngine.rows.apply([memberUpsert({ user: member.user, role: "member", display_name: "Member" })])
  })
}
const hidden = (r: { json: any }) => expect(r.json._tag === "BadRequest" ? r.json.code : JSON.stringify(r.json)).toBe("selector.not_found")

describe("participant avatars (Cloud)", { timeout: 60_000 }, () => {
  it("a person sets their own; the type comes from the bytes; only someone in a conversation with her reads it", async () => {
    const mira = await person("avatar-mira")
    const set = await op(mira.session, "participant.avatar.set", { participant_id: mira.user, bytes: b64(PNG) })
    expect(set.json.ok, JSON.stringify(set.json)).toBe(true)
    expect(set.json.value).toEqual({ participant_id: mira.user, avatar: { sha256: await sha(PNG), media_type: "image/png", bytes: PNG.length } })
    expect((await read(mira.session, "participant.avatar.get", { participant_id: mira.user })).json.value.avatar.sha256).toBe(await sha(PNG))
    // Someone who shares no conversation with her gets the unknown-participant answer, with or without
    // naming a conversation she is not in.
    const other = await person("avatar-reader")
    hidden(await read(other.session, "participant.avatar.get", { participant_id: mira.user }))
    const alone = (await op(other.session, "conversation.create", { title: "alone", participants: [{ id: other.user, kind: "human", display_name: "Reader" }] })).json.value.conversation.id as string
    hidden(await read(other.session, "participant.avatar.get", { participant_id: mira.user, conversation: alone }))
    // In a conversation together, naming it reads her picture.
    await joinTeam(mira, other)
    const together = await op(mira.session, "conversation.create", { title: "together", participants: [{ id: mira.user, kind: "human", display_name: "Mira" }, { id: other.user, kind: "human", display_name: "Reader" }] })
    expect(together.json.ok, JSON.stringify(together.json)).toBe(true)
    const conversation = together.json.value.conversation.id as string
    const got = await read(other.session, "participant.avatar.get", { participant_id: mira.user, conversation })
    expect(got.json.value.avatar).toMatchObject({ sha256: await sha(PNG), media_type: "image/png", data: b64(PNG) })
    // Not an image, or too large: refused, nothing stored.
    expect((await op(mira.session, "participant.avatar.set", { participant_id: mira.user, bytes: b64(new Uint8Array([1, 2, 3])) })).json.error.code).toBe("avatar_invalid")
    const big = new Uint8Array(1024 * 1024 + 1); big.set(PNG)
    expect((await op(mira.session, "participant.avatar.set", { participant_id: mira.user, bytes: b64(big) })).json.error.code).toBe("avatar_too_large")
    expect((await read(other.session, "participant.avatar.get", { participant_id: mira.user, conversation })).json.value.avatar.sha256).toBe(await sha(PNG))
    // A third person naming a conversation they are not in, or one that does not exist: hidden.
    const third = await person("avatar-third")
    hidden(await read(third.session, "participant.avatar.get", { participant_id: mira.user, conversation }))
    hidden(await read(third.session, "participant.avatar.get", { participant_id: mira.user, conversation: "conv_0000000000000000000000000Z" }))
    // After the reader leaves, the conversation no longer shows her picture to them.
    expect((await op(other.session, "participants.remove", { conversation, participant: other.user })).json.ok).toBe(true)
    hidden(await read(other.session, "participant.avatar.get", { participant_id: mira.user, conversation }))
  })

  it("nobody sets another person's avatar", async () => {
    const a = await person("avatar-a")
    const b = await person("avatar-b")
    const r = await op(a.session, "participant.avatar.set", { participant_id: b.user, bytes: b64(PNG) })
    expect(r.json.ok).toBe(false)
    expect(r.json.error.code).toBe("forbidden")
    expect((await read(b.session, "participant.avatar.get", { participant_id: b.user })).json.value.avatar).toBeNull()
  })

  it("the owner sets its Chief's; a Chief token sets none; blobs are shared per account and deleted when unreferenced", async () => {
    const session = await sessionToken("avatar-owner")
    const user = (await op(session, "user.ensure", {})).json.value.id as string
    const chief = (await op(session, "chief.create", { display_name: "Design Chief" })).json.value
    const other = (await op(session, "chief.create", { display_name: "Release Chief" })).json.value
    // The chief's MuxDO learns its owner through the outbox.
    const userDO = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))
    for (let i = 0; i < 5; i++) await fireAlarm(userDO)
    expect((await op(session, "participant.avatar.set", { participant_id: chief.id, bytes: b64(GIF) })).json.value.avatar.media_type).toBe("image/gif")
    expect((await op(session, "participant.avatar.set", { participant_id: user, bytes: b64(GIF) })).json.ok).toBe(true)
    const key = `avatars/${user}/${await sha(GIF)}`
    expect(await testEnv.HOME_ATTACHMENTS.head(key)).not.toBeNull()
    // The owner reads its Chief's with no conversation; a stranger gets the unknown-participant answer.
    expect((await read(session, "participant.avatar.get", { participant_id: chief.id })).json.value.avatar.data).toBe(b64(GIF))
    const reader = await person("avatar-owner-reader")
    hidden(await read(reader.session, "participant.avatar.get", { participant_id: chief.id }))

    // A chief token (install + agt) is refused.
    const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
    const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
    const install = (await op(session, "install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x!, y: jwk.y! }, kind: "mac", name: "mac", device_name: "mac", platform: "macos" })).json.value.id as string
    const ch = await call("/v1/auth/challenge", undefined, { user, install })
    const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`))
    const tok = (await call("/v1/auth/token", undefined, { user, install, nonce: ch.json.nonce, signature: b64u(sig), agent: chief.id })).json.access_token as string
    // A Chief token reads its own picture and its owner's, not another Chief's of the same owner.
    expect((await read(tok, "participant.avatar.get", { participant_id: chief.id })).json.value.avatar.data).toBe(b64(GIF))
    expect((await read(tok, "participant.avatar.get", { participant_id: user })).json.value.avatar.media_type).toBe("image/gif")
    hidden(await read(tok, "participant.avatar.get", { participant_id: other.id }))
    const byChief = await op(tok, "participant.avatar.set", { participant_id: chief.id, bytes: b64(PNG) })
    expect(byChief.json.ok).toBe(false)
    expect(byChief.json.error.code).toBe("forbidden")

    // A revoked install's still-valid token sets nothing (the account's admission runs first).
    const plain = (await call("/v1/auth/token", undefined, await (async () => {
      const c = await call("/v1/auth/challenge", undefined, { user, install })
      const s = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${c.json.message_prefix}${c.json.nonce}`))
      return { user, install, nonce: c.json.nonce, signature: b64u(s) }
    })())).json.access_token as string
    expect((await op(plain, "participant.avatar.set", { participant_id: user, bytes: b64(PNG) })).json.ok).toBe(true)
    expect((await op(session, "install.revoke", { install })).json.ok).toBe(true)
    const revoked = await op(plain, "participant.avatar.set", { participant_id: user, bytes: b64(GIF) })
    expect(revoked.json.ok).toBe(false)
    expect(revoked.json.error.code).toBe("auth.forbidden")
    expect((await read(session, "participant.avatar.get", { participant_id: user })).json.value.avatar.sha256).toBe(await sha(PNG))

    // The user moved to PNG above; the Chief still names the GIF: it stays until the Chief clears it.
    expect(await testEnv.HOME_ATTACHMENTS.head(key)).not.toBeNull()
    expect((await op(session, "participant.avatar.set", { participant_id: chief.id, clear: true })).json.value.avatar).toBeNull()
    expect(await testEnv.HOME_ATTACHMENTS.head(key)).toBeNull()
  })
})
