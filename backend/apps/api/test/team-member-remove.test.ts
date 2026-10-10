import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import type { Principal } from "@cmux/ownership"
import { hostOf, hostUpsert, memberUpsert } from "../src/domains/team-members.ts"
import { ensureSshTables } from "../src/team-ssh-ca.ts"
import { ensureLoginTables } from "../src/team-sso-login.ts"
import { withGrantClasses, withLiveSsoTeam } from "../src/auth.ts"
import { approvalDigest } from "../src/integrations/approval-gate.ts"
import { approvalByRequest, insertApproval, APPROVAL_TTL_MS } from "../src/integrations/approvals.ts"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * cx-44j.47: removing a member from a team revokes that member's installs bound to the team and
 * ends their pending integration approvals there (denied, params deleted). Nothing of another
 * member or another team changes, and a personal team's owner cannot be removed.
 */
const testEnv = env as unknown as Record<string, any>
const worker = (exports as unknown as { default: Fetcher }).default
const inDO = runInDurableObject as unknown as <T>(stub: unknown, cb: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>

const sessionToken = async (stackUser: string) =>
  new SignJWT({ email: `${stackUser}@example.com`, name: stackUser })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(stackUser)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))
const signIn = async (who: string) => {
  const token = await sessionToken(who)
  const res = await worker.fetch("https://api.test/v1/ops", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, body: JSON.stringify({ op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "user" }) })
  const v = ((await res.json()) as any).value
  return { user: v.id as string, team: v.personal_team as string, name: who }
}
const team = (id: string) => testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(id))
const userDO = (id: string) => testEnv.USER_DO.get(testEnv.USER_DO.idFromName(id))
const connections = (id: string) => testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(id))

const join = (teamId: string, user: string) => inDO(team(teamId), async (instance) => instance.boundEngine.rows.apply([memberUpsert({ user, role: "member", display_name: user })]))

/** A server install of `user` bound to `bound` (as pairing creates it); returns its id. */
const boundInstall = (user: string, bound: string | undefined, name: string, ssoTeam?: string) =>
  inDO(userDO(user), async (instance) => {
    const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
    const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
    const principal: Principal = { identity: `system:pairing:${bound ?? "none"}`, kind: "system", user, ...(bound ? { team: bound } : {}), ...(ssoTeam ? { sso_team: ssoTeam } : {}) }
    const frames: Array<any> = []
    instance.boundEngine.submit(principal, { t: "op", op: "install.register_server", params: { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y }, kind: "daemon", name, device_name: name, platform: "linux", op_classes: ["read", "mutate-own"], ...(bound ? { bound_team: bound } : {}) }, idempotency_key: crypto.randomUUID(), origin: "script" }, (_t: unknown, f: any) => frames.push(f))
    const result = frames.find((f) => f.t === "result")
    expect(result, JSON.stringify(frames)).toBeDefined()
    return result.value.id as string
  })
const installOf = (user: string, install: string) => inDO(userDO(user), async (instance) => instance.boundEngine.currentState.installs[install])

const pending = (teamId: string, user: string) =>
  inDO(connections(teamId), async (_i, st) => {
    const request = `apr_${crypto.randomUUID().replace(/-/g, "")}`
    const params = { connection: "conn_team", channel: "C9", text: "member secret text" }
    const digest = approvalDigest("slack.post_as_bot", params)
    const now = Date.now()
    insertApproval(st.storage.sql, { request, identity: `install:agent-${request}`, idempotency_key: `k-${request}`, user, connection: "conn_team", op: "slack.post_as_bot", params, params_hash: digest, digest, principal: { identity: `install:agent-${request}`, kind: "install", user, team: teamId }, target: "C9", summary: "", created_at: now, expires_at: now + APPROVAL_TTL_MS })
    return request
  })
const approval = (teamId: string, request: string) => inDO(connections(teamId), async (_i, st) => approvalByRequest(st.storage.sql, request))

const removeMember = async (teamId: string, user: string) => {
  const r = await inDO(team(teamId), async (instance) => instance.submitSystem("team.member.remove", { user }, `remove:${teamId}:${user}:${crypto.randomUUID()}`))
  // Deliver the outbox (UserDO, ConnectionDO) now.
  await fireAlarm(team(teamId))
  return r
}

describe("team member removal (cx-44j.47)", { timeout: 60_000 }, () => {
  it("revokes the member's installs bound to the team and ends their pending approvals there; nothing else changes", async () => {
    const owner = await signIn("rm-owner")
    const member = await signIn("rm-member")
    const other = await signIn("rm-other")
    await join(owner.team, member.user)
    await join(owner.team, other.user)
    const bound = await boundInstall(member.user, owner.team, "team box")
    const unbound = await boundInstall(member.user, undefined, "own box")
    const otherBound = await boundInstall(other.user, owner.team, "other box")
    const mine = await pending(owner.team, member.user)
    const theirs = await pending(owner.team, other.user)
    const elsewhere = await pending(member.team, member.user)

    const r = await removeMember(owner.team, member.user)
    expect(r.frames.find((f: any) => f.t === "reject")).toBeUndefined()

    expect((await installOf(member.user, bound)).revoked_at).not.toBeNull()
    expect((await installOf(member.user, unbound)).revoked_at).toBeNull()
    expect((await installOf(other.user, otherBound)).revoked_at).toBeNull()
    expect(await approval(owner.team, mine)).toMatchObject({ state: "denied", params: {} })
    expect((await approval(owner.team, theirs))?.state).toBe("pending")
    expect((await approval(member.team, elsewhere))?.state).toBe("pending")
    // The membership and the user's team index are gone.
    const probe: Principal = { identity: `session:${member.user}`, kind: "session", user: member.user, team: owner.team }
    expect((await team(owner.team).readOp(owner.team, probe, "team.members.list", { limit: 1 })).ok).toBe(false)
    expect(await inDO(userDO(member.user), async (instance) => instance.boundEngine.currentState.team_index?.[owner.team])).toBeUndefined()
  })

  it("refuses to remove a personal team's owner, and a removal from another team's stream ends nothing", async () => {
    const owner = await signIn("rm-owner2")
    const member = await signIn("rm-member2")
    const r = await removeMember(owner.team, owner.user)
    expect(r.frames.find((f: any) => f.t === "reject")?.code).toBe("auth.forbidden")
    const request = await pending(owner.team, member.user)
    // A ConnectionDO honors member_left only from its own team's TeamDO.
    await inDO(connections(owner.team), async (instance) =>
      instance.systemDeliver(owner.team, `team:${member.team}`, [{ id: 7, op: "connections.member_left", key: "forged", params: { team: member.team, user: member.user } }])
    )
    expect((await approval(owner.team, request))?.state).toBe("pending")
  })

  it("revokes every bound install (they can no longer sign in), and a non-member removal changes nothing", async () => {
    const owner = await signIn("rm-owner3")
    const member = await signIn("rm-member3")
    await join(owner.team, member.user)
    const a = await boundInstall(member.user, owner.team, "box a")
    const b = await boundInstall(member.user, owner.team, "box b")
    const challenge = (install: string) => worker.fetch("https://api.test/v1/auth/challenge", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ user: member.user, install }) }).then((r) => r.status)
    expect(await challenge(a)).toBe(200)
    await removeMember(owner.team, member.user)
    expect((await installOf(member.user, a)).revoked_at).not.toBeNull()
    expect((await installOf(member.user, b)).revoked_at).not.toBeNull()
    expect(await challenge(a)).toBe(403)
    expect(await challenge(b)).toBe(403)
    const again = await removeMember(owner.team, member.user)
    expect(again.frames.find((f: any) => f.t === "result")?.value).toMatchObject({ removed: false })
  })

  it("a late delivery after a re-join keeps what was created after the removal", async () => {
    const owner = await signIn("rm-owner4")
    const member = await signIn("rm-member4")
    await join(owner.team, member.user)
    await removeMember(owner.team, member.user)
    const removedAt = Date.now() - 1
    await join(owner.team, member.user)
    const fresh = await boundInstall(member.user, owner.team, "new box")
    const request = await pending(owner.team, member.user)
    // The old removal's items arrive again (backoff, dead-letter replay) with their removal time.
    await inDO(userDO(member.user), async (instance) => instance.systemDeliver(member.user, `team:${owner.team}`, [{ id: 1, op: "user.team_left", key: `late-left:${crypto.randomUUID()}`, params: { team: owner.team, at: removedAt } }]))
    await inDO(connections(owner.team), async (instance) => instance.systemDeliver(owner.team, `team:${owner.team}`, [{ id: 2, op: "connections.member_left", key: `late:${crypto.randomUUID()}`, params: { team: owner.team, user: member.user, at: removedAt } }]))
    expect((await installOf(member.user, fresh)).revoked_at).toBeNull()
    expect((await approval(owner.team, request))?.state).toBe("pending")
  })

  it("UserDO and ConnectionDO accept the removal only from the team's own TeamDO", async () => {
    const owner = await signIn("rm-owner5")
    const member = await signIn("rm-member5")
    await join(owner.team, member.user)
    const bound = await boundInstall(member.user, owner.team, "box")
    const request = await pending(owner.team, member.user)
    // Right team in the params, another team's stream as the source.
    await inDO(userDO(member.user), async (instance) => instance.systemDeliver(member.user, `team:${member.team}`, [{ id: 3, op: "user.team_left", key: `forged-left:${crypto.randomUUID()}`, params: { team: owner.team } }]))
    await inDO(connections(owner.team), async (instance) => instance.systemDeliver(owner.team, `team:${member.team}`, [{ id: 4, op: "connections.member_left", key: `forged:${crypto.randomUUID()}`, params: { team: owner.team, user: member.user } }]))
    expect((await installOf(member.user, bound)).revoked_at).toBeNull()
    expect((await approval(owner.team, request))?.state).toBe("pending")
    // A delivered team.member.remove (not this TeamDO's own submit) is refused.
    const delivered = await inDO(team(owner.team), async (instance) => {
      const frames: Array<any> = []
      instance.boundEngine.submit({ identity: `system:team:${member.team}`, kind: "system" }, { t: "op", op: "team.member.remove", params: { user: member.user }, idempotency_key: crypto.randomUUID(), origin: "script" }, (_t: unknown, f: any) => frames.push(f))
      return frames.find((f) => f.t === "reject")?.code
    })
    expect(delivered).toBe("auth.forbidden")
  })

  it("keeps the member's own installs that the team's SSO authorized but takes the team's authority away at once", async () => {
    const owner = await signIn("rm-owner6")
    const member = await signIn("rm-member6")
    await join(owner.team, member.user)
    const viaSso = await boundInstall(member.user, undefined, "laptop via team sso", owner.team)
    const viaOtherSso = await boundInstall(member.user, undefined, "laptop via other sso", member.team)
    // Bound to another team (that team's VM) while carrying this team's SSO: the other team's authority stays.
    const otherTeamVm = await boundInstall(member.user, member.team, "other team box", owner.team)
    // A token minted before the removal still carries the team's SSO claim.
    const before = await installOf(member.user, viaSso)
    const tokenPrincipal: Principal = { identity: viaSso, kind: "install", user: member.user, team: member.team, install: viaSso, grant: before.grant, sso_team: owner.team }
    expect((await withLiveSsoTeam(testEnv as any, tokenPrincipal)).sso_team).toBe(owner.team)
    await removeMember(owner.team, member.user)
    // Not signed out: the install stays and still signs in for the person's own work.
    const kept = await installOf(member.user, viaSso)
    expect(kept.revoked_at).toBeNull()
    expect(kept.sso_team).toBeUndefined()
    const challenge = await worker.fetch("https://api.test/v1/auth/challenge", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ user: member.user, install: viaSso }) })
    expect(challenge.status).toBe(200)
    // The old token's claim no longer counts anywhere: the SSO gate and every owner see no team SSO.
    expect((await withLiveSsoTeam(testEnv as any, tokenPrincipal)).sso_team).toBeUndefined()
    const resolved = await withGrantClasses(testEnv as any, tokenPrincipal)
    expect(resolved).toBeDefined()
    expect(resolved!.sso_team).toBeUndefined()
    expect(resolved!.grant_classes?.length).toBeGreaterThan(0)
    expect((await installOf(member.user, viaOtherSso))).toMatchObject({ revoked_at: null, sso_team: member.team })
    // Bound to another team: that team's authority stays, this team's SSO goes.
    const otherVm = await installOf(member.user, otherTeamVm)
    expect(otherVm).toMatchObject({ revoked_at: null, bound_team: member.team })
    expect(otherVm.sso_team).toBeUndefined()
  })

  it("puts every live team SSH certificate of the member on the revocation list at once and orphans their hosts", async () => {
    const owner = await signIn("rm-owner7")
    const member = await signIn("rm-member7")
    const other = await signIn("rm-other7")
    await join(owner.team, member.user)
    await join(owner.team, other.user)
    const now = Date.now()
    const hostId = `host_${crypto.randomUUID().replace(/-/g, "").slice(0, 20)}`
    const otherHost = `host_${crypto.randomUUID().replace(/-/g, "").slice(0, 20)}`
    const laterHost = `host_${crypto.randomUUID().replace(/-/g, "").slice(0, 20)}`
    await inDO(team(owner.team), async (instance, st) => {
      ensureSshTables(st.storage.sql)
      // Two live certificates of the member (one from an install not bound to the team), one expired, one of another member.
      for (const [serial, user, install, validBefore] of [[9001, member.user, "inst_mac", now + 3_600_000], [9002, member.user, null, now + 600_000], [9003, member.user, "inst_mac", now - 3_600_000], [9004, other.user, "inst_x", now + 3_600_000]] as const)
        st.storage.sql.exec(`INSERT INTO ssh_certs (serial, identity, user, install, key_id, class, generation, issued_at, valid_before) VALUES (?, ?, ?, ?, ?, 'shell', 1, ?, ?)`, serial, `id-${serial}`, user, install, `${user}/k/${serial}`, now - 60_000, validBefore)
      instance.boundEngine.rows.apply([
        ...hostUpsert({ id: hostId, name: "member box", platform: "linux", owner_user: member.user, enrolled_by: "inst_box", enrolled_at: now, kind: "server" }),
        ...hostUpsert({ id: otherHost, name: "other box", platform: "linux", owner_user: other.user, enrolled_by: "inst_box2", enrolled_at: now, kind: "server" }),
        // Enrolled after the removal time (a clock or race edge): not the removed membership's host.
        ...hostUpsert({ id: laterHost, name: "later box", platform: "linux", owner_user: member.user, enrolled_by: "inst_box3", enrolled_at: now + 3_600_000, kind: "server" })
      ])
    })
    const krlBefore = await inDO(team(owner.team), async (instance) => instance.boundEngine.currentState.ssh_krl?.version ?? 0)
    await removeMember(owner.team, member.user)
    const after = await inDO(team(owner.team), async (instance) => ({ krl: instance.boundEngine.currentState.ssh_krl?.version ?? 0, pending: instance.boundEngine.currentState.member_cleanup ?? {}, revoked: Object.keys(instance.boundEngine.currentState.ssh_revoked ?? {}), host: hostOf(instance.boundEngine.currentState, instance.boundEngine.rows, hostId), other: hostOf(instance.boundEngine.currentState, instance.boundEngine.rows, otherHost), later: hostOf(instance.boundEngine.currentState, instance.boundEngine.rows, laterHost) }))
    expect(after.revoked.sort()).toEqual(["9001", "9002"])
    // A new KRL version is out for the team's hosts, and the cleanup is finished.
    expect(after.krl).toBe(krlBefore + 1)
    expect(after.pending).toEqual({})
    expect(after.later?.orphaned).toBeUndefined()
    expect(after.host?.orphaned?.at).toBeGreaterThanOrEqual(now)
    // The host stays for an owner to reassign; it says whose it was.
    expect(after.host).toMatchObject({ id: hostId, owner_user: member.user, orphaned: { former_owner: member.user } })
    expect(after.other?.orphaned).toBeUndefined()
  })

  it("ends the member's SSO sessions of the team, so no new install gets the team's SSO from them", async () => {
    const owner = await signIn("rm-owner8")
    const member = await signIn("rm-member8")
    const other = await signIn("rm-other8")
    await join(owner.team, member.user)
    await join(owner.team, other.user)
    const sessions = () => inDO(team(owner.team), async (_i, st) => st.storage.sql.exec<{ refresh_token_id: string }>(`SELECT refresh_token_id FROM sso_sessions3 ORDER BY refresh_token_id`).toArray().map((r) => r.refresh_token_id))
    await inDO(team(owner.team), async (_i, st) => {
      ensureLoginTables(st.storage.sql)
      const now = Date.now()
      // Stack subjects as signIn uses them (the user id derives from the Stack project and subject).
      for (const [rt, sub] of [["rt_member_a", "rm-member8"], ["rt_member_b", "rm-member8"], ["rt_other", "rm-other8"]] as const)
        st.storage.sql.exec(`INSERT INTO sso_sessions3 (refresh_token_id, stack_user, connection, signed_in_at, expires_at) VALUES (?, ?, 'ssoc_x', ?, ?)`, rt, sub, now, now + 3_600_000)
    })
    await removeMember(owner.team, member.user)
    expect(await sessions()).toEqual(["rt_other"])
  })

  it("a KRL notice to a team that does not exist creates nothing there", async () => {
    const ghost = `team_${crypto.randomUUID().replace(/-/g, "").slice(0, 20)}`
    expect(await team(ghost).revokeInstallCerts(ghost, "user_x", "inst_x")).toEqual({ ok: true, revoked: [] })
    expect(await inDO(team(ghost), async (instance) => instance.isBound(ghost))).toBe(false)
  })
})
