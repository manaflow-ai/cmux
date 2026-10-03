import { env, exports } from "cloudflare:workers"
import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test"
import type { ReduceContext } from "@cmux/ownership"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { beginProofMessage, codeFromRandom, displayCode, normalizeCode } from "../src/domains/pairing.ts"
import { teamDomain, type TeamState } from "../src/domains/team.ts"
import { userDomain, type UserState } from "../src/domains/user.ts"
import { pairApprove } from "../src/pair-routes.ts"

const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; ENVIRONMENT: string; TEAM_DO: DurableObjectNamespace; USER_DO: DurableObjectNamespace; PAIRING_DO: DurableObjectNamespace }
const inDO = runInDurableObject as unknown as (stub: unknown, cb: (instance: any) => Promise<void>) => Promise<void>
const runAlarm = runDurableObjectAlarm as unknown as (stub: unknown) => Promise<boolean>
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
    expect((gone.state as TeamState).server_revocations?.[INSTALL]).toMatchObject({ install: INSTALL, owner_user: OWNER, by: OWNER })
    const confirmed = teamDomain.reduce(gone.state as TeamState, "server.install_revoked", { install: INSTALL }, ctx(null))
    if (!confirmed.ok) throw new Error(confirmed.message)
    expect((confirmed.state as TeamState).server_revocations?.[INSTALL]).toBeUndefined()
    expect(gone.outbox?.map((o) => o.kind)).toEqual(["host.delete", "audit.append"])
  })
})

describe("approver role loss (server.enrolled reducer)", () => {
  it("refuses an approver who lost the role and revokes the install in the same commit; the refusal replays", () => {
    const lost = { ...enrolled, owner_user: MEMBER, approved_by: MEMBER }
    const r = teamDomain.reduce(base(), "server.enrolled", lost, ctx(null))
    if (!r.ok) throw new Error(r.message)
    expect(r.value).toMatchObject({ refused: true, install: INSTALL })
    const state = r.state as TeamState
    expect(Object.values(state.hosts)).toHaveLength(0)
    expect(state.server_revocations?.[INSTALL]).toMatchObject({ install: INSTALL, owner_user: MEMBER, by: MEMBER })
    expect(r.outbox?.map((o) => o.kind)).toEqual(["audit.append"])
    expect(teamDomain.reduce(state, "server.enrolled", lost, ctx(null))).toMatchObject({ ok: true, changed: false, value: { refused: true } })
    // Removed from the team entirely: the same refusal and revocation.
    const gone = "user_00000000000000000077"
    const removed = teamDomain.reduce(base(), "server.enrolled", { ...enrolled, owner_user: gone, approved_by: gone }, ctx(null))
    if (!removed.ok) throw new Error(removed.message)
    expect((removed.state as TeamState).server_revocations?.[INSTALL]).toMatchObject({ owner_user: gone })
  })

  it("keeps a host committed while the approver had the role; a later refusal changes nothing", () => {
    const r = teamDomain.reduce(base(), "server.enrolled", enrolled, ctx(null))
    if (!r.ok) throw new Error(r.message)
    const state = r.state as TeamState
    const demoted: TeamState = { ...state, members: { ...state.members, [OWNER]: { ...state.members[OWNER]!, role: "member" } } }
    expect(teamDomain.reduce(demoted, "server.enrolled", enrolled, ctx(null))).toMatchObject({ ok: false, code: "auth.forbidden" })
  })
})

describe("install.revoke_by_team (UserDO reducer)", () => {
  const user = (bound?: string): UserState =>
    ({
      user: { id: OWNER, stack_user_id: "s", email: null, display_name: "o", personal_team: TEAM },
      installs: {
        [INSTALL]: {
          id: INSTALL, device: "dev_00000000000000000001", kind: "daemon", name: "Studio", device_name: "Studio", platform: "linux",
          public_jwk: { kty: "EC", crv: "P-256", x: "x".repeat(43), y: "y".repeat(43) }, thumbprint: "t", grant: "grant_00000000000000000001",
          created_at: 1, revoked_at: null, ...(bound ? { bound_team: bound } : {})
        }
      },
      grants: { grant_00000000000000000001: { id: "grant_00000000000000000001", grantee: INSTALL, op_classes: ["read", "mutate-own"], approval: "none", expires_at: null, revoked_at: null, created_from: "install" } }
    }) as unknown as UserState
  const sys = (identity: string): ReduceContext => ({ principal: { identity, kind: "system" }, now: 5, tx: "t", newId: (p) => `${p}_x` })
  it("revokes install and grant only for the bound team's TeamDO", () => {
    const params = { install: INSTALL, team: TEAM, by: OWNER }
    const r = userDomain.reduce(user(TEAM), "install.revoke_by_team", params, sys(`system:team:${TEAM}`))
    if (!r.ok) throw new Error(r.message)
    expect((r.state as UserState).installs[INSTALL]!.revoked_at).toBe(5)
    expect((r.state as UserState).grants["grant_00000000000000000001"]!.revoked_at).toBe(5)
    expect(userDomain.reduce(user(), "install.revoke_by_team", params, sys(`system:team:${TEAM}`))).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(userDomain.reduce(user(TEAM), "install.revoke_by_team", params, sys("system:team:team_00000000000000000099"))).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(userDomain.reduce(user(TEAM), "install.revoke_by_team", params, ctx(OWNER))).toMatchObject({ ok: false, code: "auth.forbidden" })
  })
})

describe("approval order (pairApprove)", () => {
  it("checks the approver's role before it claims the code or writes any owner", async () => {
    const calls: Array<string> = []
    const fakeEnv = {
      TEAM_DO: { idFromName: (n: string) => n, get: () => ({ canEnrollServer: async () => (calls.push("role"), false), enrollServer: async () => (calls.push("enroll"), { ok: true, host: "host_x" }) }) },
      PAIRING_DO: { idFromName: (n: string) => n, get: () => ({ claim: async () => (calls.push("claim"), { ok: false, reason: "unknown" }), complete: async () => (calls.push("complete"), { ok: true }) }) }
    } as never
    const member = { identity: `user:${MEMBER}`, user: MEMBER, team: TEAM, kind: "session" as const }
    const r = await pairApprove(fakeEnv, member, { op: "server.pair.approve", params: { code: "76KJ982X", team: TEAM, name: "x" }, idempotency_key: "k" }, async () => {
      calls.push("submit")
      return { frames: [] }
    })
    expect(r).toMatchObject({ ok: false, error: { code: "auth.forbidden" } })
    expect(calls).toEqual(["role"])
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

const call = async (path: string, token: string | undefined, body?: unknown, extra: Record<string, string> = {}) => {
  const res = await worker.fetch(`https://api.test${path}`, {
    method: body === undefined ? "GET" : "POST",
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}), ...extra },
    ...(body === undefined ? {} : { body: JSON.stringify(body) })
  })
  return { status: res.status, json: (await res.json()) as any }
}
const op = (token: string, name: string, params: unknown, key = crypto.randomUUID()) => call("/v1/ops", token, { op: name, params, idempotency_key: key, origin: "user" })
const read = (token: string, name: string, params: unknown) => call("/v1/read", token, { op: name, params })
const b64u = (buf: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")

/** What a fresh `cmux server up` does: make an install key and a WireGuard key, prove possession, begin. */
const beginPairing = async (issuedAt = Date.now(), forge = false, ip?: string) => {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
  const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
  const public_jwk = { kty: "EC", crv: "P-256", x: jwk.x!, y: jwk.y! }
  const wg = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32))))
  const thumb = b64u(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`{"crv":"P-256","kty":"EC","x":"${jwk.x}","y":"${jwk.y}"}`)))
  const signer = forge ? ((await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair).privateKey : pair.privateKey
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, signer, new TextEncoder().encode(beginProofMessage(testEnv.ENVIRONMENT, thumb, wg, issuedAt)))
  const info = { name: "Studio", platform: "linux", os_version: "Ubuntu 24.04", arch: "x86_64", cmux_version: "0.1.0" }
  const res = await call("/v1/pair/begin", undefined, { public_jwk, wg_public_key: wg, info, issued_at: issuedAt, signature: b64u(sig) }, ip ? { "cf-connecting-ip": ip } : {})
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
    expect(inst.bound_team).toBe(teamId)
    expect((await read(tok.json.access_token, "install.list", {})).status).toBe(200)
    expect((await read(tok.json.access_token, "team.directory", {})).status).toBe(200)

    const revoked = await op(owner, "server.revoke", { host: result.host })
    expect(revoked.json).toMatchObject({ ok: true, value: { host: result.host, install_revoked: true } })
    expect((await call("/v1/auth/challenge", undefined, { user: result.user, install: result.install })).status).toBe(403)
    // The token minted before the revoke fails its next request.
    expect((await read(tok.json.access_token, "install.list", {})).status).toBe(403)
    expect((await read(tok.json.access_token, "team.directory", {})).status).toBe(403)
  })

  it("lets exactly one of two concurrent approvers claim a code; the other writes nothing", async () => {
    const a = await sessionToken("stack-pair-race-a")
    const b = await sessionToken("stack-pair-race-b")
    await op(a, "user.ensure", {})
    await op(b, "user.ensure", {})
    const teamA = (await read(a, "team.directory", {})).json.value.team as string
    const teamB = (await read(b, "team.directory", {})).json.value.team as string
    const { res } = await beginPairing()
    const code = res.json.code as string
    const [ra, rb] = await Promise.all([
      op(a, "server.pair.approve", { code, team: teamA, name: "A" }),
      op(b, "server.pair.approve", { code, team: teamB, name: "B" })
    ])
    expect([ra.json.ok, rb.json.ok].filter(Boolean)).toHaveLength(1)
    const loser = ra.json.ok ? b : a
    const loserTeam = ra.json.ok ? teamB : teamA
    const installs = (await read(loser, "install.list", {})).json.value.installs as Array<{ kind: string }>
    expect(installs.filter((i) => i.kind === "daemon")).toHaveLength(0)
    expect(((await read(loser, "team.directory", {})).json.value.hosts as Array<{ kind?: string }>).filter((h) => h.kind === "server")).toHaveLength(0)
    expect(loserTeam).toBeDefined()
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

  it("an approver who loses the role mid-approval leaves no install without a host: TeamDO refuses and revokes in one commit", async () => {
    const owner = await sessionToken("stack-pair-roleloss-owner")
    const approver = await sessionToken("stack-pair-roleloss-admin")
    await op(owner, "user.ensure", {})
    await op(approver, "user.ensure", {})
    const team = (await read(owner, "team.directory", {})).json.value.team as string
    const approverUser = (await read(approver, "install.list", {})).json.value.user.id as string
    const { res, thumb, wg } = await beginPairing(Date.now(), false, "203.0.113.10")
    const code = res.json.code as string
    const waiter = await waitFor(code, res.json.collect_secret)
    await waiter.until(() => waiter.frames.length >= 1)

    // The Worker's role check passed (the approver was an admin then); by server.enrolled TeamDO no longer counts them.
    const teams = testEnv.TEAM_DO
    const teamStub = teams.get(teams.idFromName(team)) as any
    const fakeEnv = {
      PAIRING_DO: testEnv.PAIRING_DO,
      TEAM_DO: { idFromName: (n: string) => teams.idFromName(n), get: () => ({ canEnrollServer: async () => true, enrollServer: (...a: Array<unknown>) => teamStub.enrollServer(...a) }) }
    } as never
    const principal = { kind: "session" as const, identity: `session:${approverUser}`, user: approverUser, team }
    const submit = async (_owner: string, p: typeof principal, f: { op: string; params: unknown; idempotency_key: string; origin: string }) =>
      (testEnv.USER_DO.get(testEnv.USER_DO.idFromName(p.user)) as any).submit(p.user, p, { t: "op", ...f })
    const r = await pairApprove(fakeEnv, principal, { op: "server.pair.approve", params: { code, team, name: "Studio" }, idempotency_key: "roleloss" }, submit as never)
    expect(r).toMatchObject({ ok: false, error: { code: "auth.forbidden" } })

    // No host, and the install UserDO registered is revoked with its grant; TeamDO has nothing left to retry.
    expect(((await read(owner, "team.directory", {})).json.value.hosts as Array<{ kind?: string }>).filter((h) => h.kind === "server")).toHaveLength(0)
    const list = (await read(approver, "install.list", {})).json.value
    const inst = list.installs.find((i: any) => i.kind === "daemon")
    expect(inst.revoked_at).not.toBeNull()
    expect(list.grants.find((g: any) => g.id === inst.grant).revoked_at).not.toBeNull()
    expect((await teamStub.debug(team)).state.server_revocations ?? {}).toEqual({})
    expect((await call("/v1/auth/challenge", undefined, { user: approverUser, install: inst.id })).status).toBe(403)

    // The waiting server hears the refusal and the code is spent.
    await waiter.until(() => waiter.frames.some((f) => f.t === "refused"))
    expect((await read(owner, "server.pair.preview", { code })).status).toBe(400)
    // TeamDO's ledger replays the refusal for the same key: a retry can never add a host for the revoked install.
    const replay = await teamStub.enrollServer(team, principal, { install: inst.id, name: "Studio", platform: "linux", wg_public_key: wg }, `pair:${code}:${thumb}:host`)
    expect(replay).toMatchObject({ ok: false, code: "auth.forbidden", refused: true })
  })

  it("approval retries spend no rate-limit unit; guesses at other codes stay limited", async () => {
    const owner = await sessionToken("stack-pair-retry-limit")
    await op(owner, "user.ensure", {})
    const team = (await read(owner, "team.directory", {})).json.value.team as string
    const user = (await read(owner, "install.list", {})).json.value.user.id as string
    const { res } = await beginPairing(Date.now(), false, "203.0.113.11")
    const code = res.json.code as string
    // Real owners; a counting limiter with the binding's budget (the binding's wall-clock window would make this flaky).
    const keys: Array<string> = []
    const limiter = { limit: async ({ key }: { key: string }) => (keys.push(key), { success: keys.length <= 10 }) }
    const realEnv = { PAIRING_DO: testEnv.PAIRING_DO, TEAM_DO: testEnv.TEAM_DO, PAIR_BEGIN_LIMIT: limiter } as never
    const principal = { kind: "session" as const, identity: `session:${user}`, user, team }
    const submit = async (_owner: string, p: typeof principal, f: { op: string; params: unknown; idempotency_key: string; origin: string }) =>
      (testEnv.USER_DO.get(testEnv.USER_DO.idFromName(p.user)) as any).submit(p.user, p, { t: "op", ...f })
    const approve = (c: string) => pairApprove(realEnv, principal, { op: "server.pair.approve", params: { code: c, team, name: "Studio" }, idempotency_key: crypto.randomUUID() }, submit as never)
    const first = await approve(code)
    expect(first.ok).toBe(true)
    // More retries than the 10-per-minute budget, each with a new request key (a client that lost the replies).
    for (let i = 0; i < 12; i++) expect(await approve(code)).toMatchObject({ ok: true, value: first.value })
    expect(keys).toEqual([`user:${user}`])
    // Guesses at codes this user never claimed spend the same per-user budget: nine remain, the tenth guess is refused.
    const guesses: Array<any> = []
    for (let i = 0; i < 10; i++) guesses.push(await approve(codeFromRandom(crypto.getRandomValues(new Uint8Array(5)))))
    expect(guesses.slice(0, 9).map((g) => g.error.code)).toEqual(Array(9).fill("selector.not_found"))
    expect(guesses[9]).toMatchObject({ ok: false, error: { code: "auth.forbidden", retryable: true } })
    expect(keys).toHaveLength(11)
  })

  it("retries install.revoke_by_team after a thrown RPC until it lands; a second success changes nothing", async () => {
    const owner = await sessionToken("stack-pair-revoke-retry")
    await op(owner, "user.ensure", {})
    const team = (await read(owner, "team.directory", {})).json.value.team as string
    const { res } = await beginPairing(Date.now(), false, "203.0.113.12")
    const approved = await op(owner, "server.pair.approve", { code: res.json.code, team, name: "Studio" })
    const { host, install, user } = approved.json.value as { host: string; install: string; user: string }
    const teamStub = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team)) as any
    const userStub = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user)) as any

    // Call 1 throws before UserDO; call 2 lands in UserDO but its reply is lost; call 3 succeeds.
    const calls: Array<{ pending: boolean }> = []
    await inDO(teamStub, async (instance) => {
      const real = instance.userOwner
      instance.userOwner = (u: string) => ({
        revokeByTeam: async (...a: [string, string, string, string, string]) => {
          calls.push({ pending: Boolean(instance.boundEngine.currentState.server_revocations?.[install]) })
          if (calls.length === 1) throw new Error("connection reset")
          if (calls.length === 2) {
            await real(u).revokeByTeam(...a)
            throw new Error("reply lost")
          }
          return real(u).revokeByTeam(...a)
        }
      })
    })
    const revoked = await op(owner, "server.revoke", { host })
    expect(revoked.json).toMatchObject({ ok: true, value: { host, install_revoked: false } })

    // TeamDO's alarm retries (the backoff is skipped here) until UserDO confirms.
    const pending = async () => Boolean((await teamStub.debug(team)).state.server_revocations?.[install])
    for (let i = 0; i < 20 && (await pending()); i++) {
      await inDO(teamStub, async (instance) => {
        instance.revokeRetryAt = 0
      })
      await runAlarm(teamStub)
    }
    expect(await pending()).toBe(false)
    // Every failed call kept the item pending, and nothing ran after the success.
    expect(calls).toEqual([{ pending: true }, { pending: true }, { pending: true }])
    await inDO(teamStub, async (instance) => {
      expect(instance.revokeAttempts).toBe(0)
      expect(instance.revokeRetryAt).toBeNull()
    })
    expect((await call("/v1/auth/challenge", undefined, { user, install })).status).toBe(403)

    // The landed call and its retry applied once: one event and one ledger entry in UserDO.
    const once = async () => {
      const dump = await userStub.debug(user)
      return {
        events: dump.events.filter((e: any) => e.op === "install.revoke_by_team").length,
        ledger: dump.ledger.filter((l: any) => l.op === "install.revoke_by_team").length,
        revoked_at: dump.state.installs[install].revoked_at as number
      }
    }
    const after = await once()
    expect(after).toMatchObject({ events: 1, ledger: 1 })
    // A further success is a replay: same answer, no new event, nothing left for TeamDO.
    expect(await userStub.revokeByTeam(user, team, install, user, `team-revoke:${team}:${install}`)).toEqual({ ok: true })
    expect(await once()).toEqual(after)
    expect(await teamStub.flushServerRevocations(team)).toEqual({ revoked: [] })
    expect(calls).toHaveLength(3)
  })
})
