import { MemoryRows, type ReduceContext } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { codeFromRandom, displayCode, normalizeCode } from "../src/domains/pairing.ts"
import { teamDomain, type TeamState } from "../src/domains/team.ts"
import { userDomain, type UserState } from "../src/domains/user.ts"
import { handlePairWait, pairApprove } from "../src/pair-routes.ts"
import { b64u, beginPairing, call, op, read, sessionToken, testEnv, waitFor } from "./pairing-harness.ts"

const OWNER = "user_00000000000000000001"
const MEMBER = "user_00000000000000000002"
const TEAM = "team_00000000000000000001"
const INSTALL = "inst_00000000000000000009"
const WG = "q".repeat(43) + "="
// Members and hosts are rows ((f)): each test's reductions share one row store.
let rows = new MemoryRows()
const base = (): TeamState => ((rows = new MemoryRows()), {
  team: { id: TEAM, kind: "personal", display_name: "Acme" },
  members: { [OWNER]: { user: OWNER, role: "owner", display_name: "o" }, [MEMBER]: { user: MEMBER, role: "member", display_name: "m" } },
  hosts: {}
})
const reduce: typeof teamDomain.reduce = (st, op, params, c) => {
  const r = teamDomain.reduce(st, op, params, c)
  if (r.ok && r.writes) rows.apply(r.writes)
  return r
}
let txn = 0
const ctx = (user: string | null, extra: Partial<ReduceContext["principal"]> = {}): ReduceContext => ({
  principal: user ? { identity: `user:${user}`, user, team: TEAM, kind: "session", ...extra } : { identity: "system:test", kind: "system" },
  now: 1_000_000 + txn,
  tx: `tx${++txn}`,
  newId: (p) => `${p}_${String(txn).padStart(20, "0")}`,
  rows
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
    const r = reduce(base(), "server.enrolled", enrolled, ctx(null))
    if (!r.ok) throw new Error(r.message)
    expect(r.value).toMatchObject({ kind: "server", tags: ["tag:server"], owner_user: OWNER, enrolled_by: INSTALL, wg_public_key: WG })
    expect(r.outbox?.map((o) => o.kind)).toEqual(["host.upsert", "audit.append"])
    const again = reduce(r.state as TeamState, "server.enrolled", enrolled, ctx(null))
    expect(again).toMatchObject({ ok: true, changed: false })
    expect(reduce(base(), "server.enrolled", enrolled, ctx(OWNER))).toMatchObject({ ok: false, code: "auth.forbidden" })
  })

  it("revokes only for the owner or an admin, never an agent, and only server hosts", () => {
    const r = reduce(base(), "server.enrolled", enrolled, ctx(null))
    if (!r.ok) throw new Error(r.message)
    const state = r.state as TeamState
    const host = (r.value as { id: string }).id
    expect(reduce(state, "server.revoke", { host }, ctx(MEMBER))).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(reduce(state, "server.revoke", { host }, ctx(OWNER, { agent: "agent_x" }))).toMatchObject({ ok: false, code: "auth.forbidden" })
    const gone = reduce(state, "server.revoke", { host }, ctx(OWNER))
    if (!gone.ok) throw new Error(gone.message)
    expect(gone.value).toEqual({ host, install: INSTALL, owner_user: OWNER })
    expect(rows.get("host", host)).toBeUndefined()
    expect((gone.state as TeamState).server_revocations?.[INSTALL]).toMatchObject({ install: INSTALL, owner_user: OWNER, by: OWNER })
    const confirmed = reduce(gone.state as TeamState, "server.install_revoked", { install: INSTALL }, ctx(null))
    if (!confirmed.ok) throw new Error(confirmed.message)
    expect((confirmed.state as TeamState).server_revocations?.[INSTALL]).toBeUndefined()
    expect(gone.outbox?.map((o) => o.kind)).toEqual(["host.delete", "audit.append"])
  })
})

describe("approver role loss (server.enrolled reducer)", () => {
  it("refuses an approver who lost the role and revokes the install in the same commit; the refusal replays", () => {
    const lost = { ...enrolled, owner_user: MEMBER, approved_by: MEMBER }
    const r = reduce(base(), "server.enrolled", lost, ctx(null))
    if (!r.ok) throw new Error(r.message)
    expect(r.value).toMatchObject({ refused: true, install: INSTALL })
    const state = r.state as TeamState
    expect(rows.get("host_by_install", INSTALL)).toBeUndefined()
    expect(state.server_revocations?.[INSTALL]).toMatchObject({ install: INSTALL, owner_user: MEMBER, by: MEMBER })
    expect(r.outbox?.map((o) => o.kind)).toEqual(["audit.append"])
    expect(r.outbox?.[0]?.payload).toMatchObject({ op: "server.enroll_refused", detail: { install: INSTALL, refused: true } })
    expect(reduce(state, "server.enrolled", lost, ctx(null))).toMatchObject({ ok: true, changed: false, value: { refused: true } })
    // Removed from the team entirely: the same refusal and revocation.
    const gone = "user_00000000000000000077"
    const removed = reduce(base(), "server.enrolled", { ...enrolled, owner_user: gone, approved_by: gone }, ctx(null))
    if (!removed.ok) throw new Error(removed.message)
    expect((removed.state as TeamState).server_revocations?.[INSTALL]).toMatchObject({ owner_user: gone })
  })

  it("keeps a host committed while the approver had the role; a later refusal changes nothing", () => {
    const r = reduce(base(), "server.enrolled", enrolled, ctx(null))
    if (!r.ok) throw new Error(r.message)
    const state = r.state as TeamState
    rows.apply([{ table: "member", op: "upsert", key: OWNER, n: null, row: { user: OWNER, role: "member", display_name: "o" } }])
    expect(reduce(state, "server.enrolled", enrolled, ctx(null))).toMatchObject({ ok: false, code: "auth.forbidden" })
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
  it("checks the approver's role before it claims the code or writes any owner (claimedBy only reads)", async () => {
    const calls: Array<string> = []
    const fakeEnv = {
      TEAM_DO: { idFromName: (n: string) => n, get: () => ({ canEnrollServer: async () => (calls.push("role"), false), enrollServer: async () => (calls.push("enroll"), { ok: true, host: "host_x" }) }) },
      PAIRING_DO: { idFromName: (n: string) => n, get: () => ({ claimedBy: async () => (calls.push("claimedBy"), false), claim: async () => (calls.push("claim"), { ok: false, reason: "unknown" }), complete: async () => (calls.push("complete"), { ok: true }) }) }
    } as never
    const member = { identity: `user:${MEMBER}`, user: MEMBER, team: TEAM, kind: "session" as const }
    const r = await pairApprove(fakeEnv, member, { op: "server.pair.approve", params: { code: "76KJ982X", team: TEAM, name: "x" }, idempotency_key: "k" }, async () => {
      calls.push("submit")
      return { frames: [] }
    })
    expect(r).toMatchObject({ ok: false, error: { code: "auth.forbidden" } })
    expect(calls).toEqual(["role", "claimedBy"])
  })
})

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


  it("refuses a forged code or collect secret on wait before any PairingDO wakes; the issued secret works", async () => {
    const { res } = await beginPairing(Date.now(), false, "203.0.113.15")
    const code = res.json.code as string
    const secret = res.json.collect_secret as string
    expect(secret).toMatch(/^[A-Za-z0-9_-]{22}\.[0-9a-f]{64}$/)
    let gets = 0
    const counting = {
      ENVIRONMENT: testEnv.ENVIRONMENT,
      JWT_PRIVATE_JWK: testEnv.JWT_PRIVATE_JWK,
      PAIRING_DO: { idFromName: (n: string) => testEnv.PAIRING_DO.idFromName(n), get: (id: DurableObjectId) => ((gets += 1), testEnv.PAIRING_DO.get(id)) }
    } as never
    const wait = (c: string, s: string) =>
      handlePairWait(new Request(`https://api.test/v1/pair/wait?code=${c}`, { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": `cmux.pair.v1, collect.${s}` } }), counting)
    const [nonce, mac] = secret.split(".") as [string, string]
    const otherCode = code === "00000000" ? "11111111" : "00000000"
    const forged = [
      [otherCode, secret], // another code with a real secret
      [code, "forged"],
      [code, `${nonce}.${"0".repeat(64)}`],
      [code, `${"A".repeat(22)}.${mac}`], // the MAC under another nonce
      [code, `${nonce}.${mac}.x`]
    ]
    for (const [c, s] of forged) expect((await wait(c!, s!)).status).toBe(404)
    expect(gets).toBe(0)
    const ok = await wait(code, secret)
    expect(ok.status).toBe(101)
    expect(gets).toBe(1)
    ok.webSocket?.accept()
    ok.webSocket?.close()
  })
})
