import { env, exports } from "cloudflare:workers"
import type { ReduceContext } from "@cmux/ownership"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { beginProofMessage, codeFromRandom, displayCode, normalizeCode } from "../src/domains/pairing.ts"
import { teamDomain, type TeamState } from "../src/domains/team.ts"

const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; ENVIRONMENT: string }
const worker = (exports as unknown as { default: Fetcher }).default

const OWNER = "user_00000000000000000001"
const MEMBER = "user_00000000000000000002"
const TEAM = "team_00000000000000000001"
const INSTALL = "inst_00000000000000000009"
const WG = "q".repeat(43) + "="
const base = (): TeamState => ({
  team: { id: TEAM, kind: "personal", display_name: "Acme" },
  members: { [OWNER]: { user: OWNER, role: "owner", display_name: "o" }, [MEMBER]: { user: MEMBER, role: "member", display_name: "m" } },
  hosts: {}
})
let txn = 0
const ctx = (user: string | null, extra: Partial<ReduceContext["principal"]> = {}): ReduceContext => ({
  principal: user ? { identity: `user:${user}`, user, team: TEAM, kind: "session", ...extra } : { identity: "system:test", kind: "system" },
  now: 1_000_000 + txn,
  tx: `tx${++txn}`,
  newId: (p) => `${p}_${String(txn).padStart(20, "0")}`
})
const enrolled = { install: INSTALL, name: "Studio", platform: "linux", wg_public_key: WG, owner_user: OWNER, approved_by: OWNER }

describe("pairing codes (shared golden with cmux-server-core)", () => {
  it("encodes 5 random bytes as 8 Crockford symbols and normalizes look-alikes", () => {
    expect(codeFromRandom(new Uint8Array([0x39, 0xa7, 0x24, 0xa0, 0x5d]))).toBe("76KJ982X")
    expect(codeFromRandom(new Uint8Array(5))).toBe("00000000")
    expect(codeFromRandom(new Uint8Array(5).fill(0xff))).toBe("ZZZZZZZZ")
    expect(displayCode("76KJ982X")).toBe("76KJ-982X")
    expect(normalizeCode("76kj-982x")).toBe("76KJ982X")
    expect(normalizeCode("7OKJ 98LX")).toBe("70KJ981X")
    expect(normalizeCode("76KJ-982U")).toBeNull()
    expect(normalizeCode("76KJ")).toBeNull()
  })
})

describe("servers in the team directory (TeamDO reducer)", () => {
  it("adds a server host with tag:server once, with an audit record, and only from a system op", () => {
    const r = teamDomain.reduce(base(), "server.enrolled", enrolled, ctx(null))
    if (!r.ok) throw new Error(r.message)
    expect(r.value).toMatchObject({ kind: "server", tags: ["tag:server"], owner_user: OWNER, enrolled_by: INSTALL, wg_public_key: WG })
    expect(r.outbox?.map((o) => o.kind)).toEqual(["host.upsert", "audit.append"])
    const again = teamDomain.reduce(r.state as TeamState, "server.enrolled", enrolled, ctx(null))
    expect(again).toMatchObject({ ok: true, changed: false })
    expect(teamDomain.reduce(base(), "server.enrolled", enrolled, ctx(OWNER))).toMatchObject({ ok: false, code: "auth.forbidden" })
  })

  it("revokes only for the owner or an admin, never an agent, and only server hosts", () => {
    const r = teamDomain.reduce(base(), "server.enrolled", enrolled, ctx(null))
    if (!r.ok) throw new Error(r.message)
    const state = r.state as TeamState
    const host = (r.value as { id: string }).id
    expect(teamDomain.reduce(state, "server.revoke", { host }, ctx(MEMBER))).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(teamDomain.reduce(state, "server.revoke", { host }, ctx(OWNER, { agent: "agent_x" }))).toMatchObject({ ok: false, code: "auth.forbidden" })
    const gone = teamDomain.reduce(state, "server.revoke", { host }, ctx(OWNER))
    if (!gone.ok) throw new Error(gone.message)
    expect(gone.value).toEqual({ host, install: INSTALL, owner_user: OWNER })
    expect((gone.state as TeamState).hosts[host]).toBeUndefined()
    expect(gone.outbox?.map((o) => o.kind)).toEqual(["host.delete", "audit.append"])
  })
})

const sessionToken = async (stackUser: string) => {
  const key = await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256")
  return new SignJWT({ email: `${stackUser}@example.com`, email_verified: true, name: stackUser })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(stackUser)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(key)
}

const call = async (path: string, token: string | undefined, body?: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, {
    method: body === undefined ? "GET" : "POST",
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) })
  })
  return { status: res.status, json: (await res.json()) as any }
}
const op = (token: string, name: string, params: unknown, key = crypto.randomUUID()) => call("/v1/ops", token, { op: name, params, idempotency_key: key, origin: "user" })
const read = (token: string, name: string, params: unknown) => call("/v1/read", token, { op: name, params })
const b64u = (buf: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")

/** What a fresh `cmux server up` does: make an install key and a WireGuard key, prove possession, begin. */
const beginPairing = async (issuedAt = Date.now(), forge = false) => {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
  const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
  const public_jwk = { kty: "EC", crv: "P-256", x: jwk.x!, y: jwk.y! }
  const wg = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32))))
  const thumb = b64u(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`{"crv":"P-256","kty":"EC","x":"${jwk.x}","y":"${jwk.y}"}`)))
  const signer = forge ? ((await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair).privateKey : pair.privateKey
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, signer, new TextEncoder().encode(beginProofMessage(testEnv.ENVIRONMENT, thumb, wg, issuedAt)))
  const info = { name: "Studio", platform: "linux", os_version: "Ubuntu 24.04", arch: "x86_64", cmux_version: "0.1.0" }
  const res = await call("/v1/pair/begin", undefined, { public_jwk, wg_public_key: wg, info, issued_at: issuedAt, signature: b64u(sig) })
  return { res, pair, public_jwk, wg, thumb }
}

const waitFor = async (code: string, secret: string) => {
  const res = await worker.fetch(`https://api.test/v1/pair/wait?code=${code}`, { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": `cmux.pair.v1, collect.${secret}` } })
  const ws = res.webSocket
  const frames: Array<any> = []
  let wake: (() => void) | null = null
  ws?.addEventListener("message", (e) => {
    frames.push(JSON.parse(e.data as string))
    wake?.()
  })
  ws?.accept()
  const until = async (pred: () => boolean) => {
    while (!pred()) await new Promise<void>((r) => (wake = r))
  }
  return { status: res.status, frames, until }
}

describe("server pairing over the API (workerd)", () => {
  it("begins with proof, previews, approves once, pushes the result, lets the server mint a narrow token, and revokes", async () => {
    const owner = await sessionToken("stack-pair-owner")
    await op(owner, "user.ensure", {})
    const { res, pair, thumb, wg } = await beginPairing()
    expect(res.status).toBe(200)
    expect(res.json.code).toMatch(/^[0-9A-HJKMNP-TV-Z]{8}$/)
    expect(res.json.thumbprint).toBe(thumb)
    const code = res.json.code as string

    // Only the begin caller can wait: a wrong collect secret gets nothing.
    expect((await waitFor(code, "wrong-secret")).status).toBe(404)
    const waiter = await waitFor(code, res.json.collect_secret)
    expect(waiter.status).toBe(101)
    await waiter.until(() => waiter.frames.length >= 1)
    expect(waiter.frames[0]).toMatchObject({ t: "pending" })

    const preview = await read(owner, "server.pair.preview", { code: displayCode(code).toLowerCase() })
    expect(preview.status).toBe(200)
    expect(preview.json.value).toMatchObject({ code, thumbprint: thumb, info: { name: "Studio", platform: "linux" } })

    const teamId = (await read(owner, "team.directory", {})).json.value.team as string
    const key = crypto.randomUUID()
    const approved = await op(owner, "server.pair.approve", { code, team: teamId, name: "Studio" }, key)
    expect(approved.json.ok).toBe(true)
    const result = approved.json.value as { host: string; team: string; user: string; install: string }
    expect(result.team).toBe(teamId)

    await waiter.until(() => waiter.frames.some((f) => f.t === "paired"))
    expect(waiter.frames.find((f) => f.t === "paired")).toMatchObject(result)

    // Single use and idempotent: the same approval replays; another user cannot reuse the code.
    expect((await op(owner, "server.pair.approve", { code, team: teamId, name: "Studio" }, key)).json.value).toEqual(result)
    const other = await sessionToken("stack-pair-other")
    await op(other, "user.ensure", {})
    const otherTeam = (await read(other, "team.directory", {})).json.value.team as string
    expect((await op(other, "server.pair.approve", { code, team: otherTeam, name: "x" })).json.ok).toBe(false)

    // The directory lists the server with its WireGuard key and tag.
    const dir = (await read(owner, "team.directory", {})).json.value
    expect(dir.hosts.find((h: any) => h.id === result.host)).toMatchObject({ kind: "server", wg_public_key: wg, tags: ["tag:server"], enrolled_by: result.install })

    // The server mints an install token with its own key; its grant is read + mutate-own only.
    const ch = await call("/v1/auth/challenge", undefined, { user: result.user, install: result.install })
    expect(ch.status).toBe(200)
    const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`))
    const tok = await call("/v1/auth/token", undefined, { user: result.user, install: result.install, nonce: ch.json.nonce, signature: b64u(sig) })
    expect(tok.status).toBe(200)
    const installs = (await read(owner, "install.list", {})).json.value
    const inst = installs.installs.find((i: any) => i.id === result.install)
    expect(inst).toMatchObject({ kind: "daemon" })
    expect(installs.grants.find((g: any) => g.id === inst.grant).op_classes).toEqual(["read", "mutate-own"])

    // A server cannot approve or revoke (install token), and an agent cannot either.
    expect((await op(tok.json.access_token, "server.revoke", { host: result.host })).json.ok).toBe(false)

    const revoked = await op(owner, "server.revoke", { host: result.host })
    expect(revoked.json).toMatchObject({ ok: true, value: { host: result.host, install_revoked: true } })
    expect((await call("/v1/auth/challenge", undefined, { user: result.user, install: result.install })).status).toBe(403)
  })

  it("refuses a begin without proof of possession or with a stale timestamp, and an unknown code", async () => {
    const owner = await sessionToken("stack-pair-refuse")
    await op(owner, "user.ensure", {})
    const stale = await beginPairing(Date.now() - 60 * 60_000)
    expect(stale.res.status).toBe(400)
    // Signed by a key other than the one it asks to pair.
    expect((await beginPairing(Date.now(), true)).res.status).toBe(403)
    expect((await read(owner, "server.pair.preview", { code: "ZZZZ-ZZZZ" })).status).toBe(400)
  })
})
