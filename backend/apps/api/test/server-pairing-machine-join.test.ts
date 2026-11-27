import { describe, expect, it } from "vitest"
import { pairApprove } from "../src/pair-routes.ts"
import { beginPairing, call, inDO, op, read, runAlarm, sessionPrincipal, sessionToken, testEnv, userSubmit, waitFor } from "./pairing-harness.ts"

/**
 * A paired box gets the same machine credential as a pasted join line (pair-machine-join.ts): the approval mints a
 * join token for the approver on the platform and pushes it with the result, never in the op's reply.
 */
const TOKEN = `cmj_${"a".repeat(43)}`

const platform = (reply: () => Response) => {
  const calls: Array<{ url: string; auth: string | null; body: any }> = []
  return {
    calls,
    fetch: async (url: string, init: RequestInit) => {
      calls.push({ url, auth: new Headers(init.headers).get("authorization"), body: JSON.parse(String(init.body)) })
      return reply()
    }
  }
}
const minted = () => Response.json({ joinTokenId: "join_1", token: TOKEN, expiresAt: new Date(Date.now() + 600_000).toISOString(), teamId: "t" })

const setup = async (name: string) => {
  const owner = await sessionToken(name)
  await op(owner, "user.ensure", {})
  const team = (await read(owner, "team.directory", {})).json.value.team as string
  const user = (await read(owner, "install.list", {})).json.value.user.id as string
  const { res } = await beginPairing(Date.now(), false, "203.0.113.40")
  const code = res.json.code as string
  const waiter = await waitFor(code, res.json.collect_secret)
  await waiter.until(() => waiter.frames.length >= 1)
  return { owner, team, user, code, waiter }
}

describe("server pairing mints the box's machine join token (workerd)", () => {
  it("pushes one join token minted for the approver with the result, and a retry reuses it", async () => {
    const { owner, team, user, code, waiter } = await setup("stack-pair-machine-join")
    const fake = platform(minted)
    const env = { PAIRING_DO: testEnv.PAIRING_DO, TEAM_DO: testEnv.TEAM_DO, PLATFORM: fake, INTERNAL_TOKEN: "internal-test" } as never
    const approve = () => pairApprove(env, sessionPrincipal(user, team), { op: "server.pair.approve", params: { code, team, name: "Studio" }, idempotency_key: "machine-join" }, userSubmit as never)
    const first = await approve()
    expect(first.ok).toBe(true)
    // The approver's reply never carries the token.
    expect(JSON.stringify(first)).not.toContain(TOKEN)
    expect(fake.calls).toHaveLength(1)
    expect(fake.calls[0]).toMatchObject({ url: "https://platform/internal/v1/machines/join-tokens", auth: "Bearer internal-test", body: { teamId: team, userId: user, label: "Studio", ttlSeconds: 600 } })
    await waiter.until(() => waiter.frames.some((f) => f.t === "paired"))
    const paired = waiter.frames.find((f) => f.t === "paired")
    expect(paired.machine_join.token).toBe(TOKEN)
    expect(paired.machine_join.expires_at).toBeGreaterThan(Date.now())
    // Only the token and its expiry reach the box.
    expect(Object.keys(paired.machine_join).sort()).toEqual(["expires_at", "token"])
    expect(paired).toMatchObject({ team, user })
    // A retried approval answers the same result and mints nothing more.
    expect(await approve()).toMatchObject({ ok: true, value: first.value })
    expect(fake.calls).toHaveLength(1)
    // The server row is written as before.
    expect(((await read(owner, "team.directory", {})).json.value.hosts as Array<{ kind?: string }>).filter((h) => h.kind === "server")).toHaveLength(1)
  })

  it("a platform that cannot mint fails the approval before any install or host, and a retry finishes it", async () => {
    const { owner, team, user, code, waiter } = await setup("stack-pair-machine-join-down")
    let down = true
    const fake = platform(() => (down ? new Response("nope", { status: 503 }) : minted()))
    const env = { PAIRING_DO: testEnv.PAIRING_DO, TEAM_DO: testEnv.TEAM_DO, PLATFORM: fake, INTERNAL_TOKEN: "internal-test" } as never
    const approve = () => pairApprove(env, sessionPrincipal(user, team), { op: "server.pair.approve", params: { code, team, name: "Studio" }, idempotency_key: "machine-join-down" }, userSubmit as never)
    expect(await approve()).toMatchObject({ ok: false, error: { code: "owner.unreachable", retryable: true } })
    expect(((await read(owner, "install.list", {})).json.value.installs as Array<{ kind: string }>).filter((i) => i.kind === "daemon")).toHaveLength(0)
    down = false
    expect((await approve()).ok).toBe(true)
    await waiter.until(() => waiter.frames.some((f) => f.t === "paired"))
    expect(waiter.frames.find((f) => f.t === "paired").machine_join.token).toBe(TOKEN)
  })

  for (const status of [404, 403]) {
    it(`a platform that refuses (${status}) pairs as before, with no join token`, async () => {
      const { team, user, code, waiter } = await setup(`stack-pair-machine-join-${status}`)
      const env = { PAIRING_DO: testEnv.PAIRING_DO, TEAM_DO: testEnv.TEAM_DO, PLATFORM: platform(() => new Response("{}", { status })), INTERNAL_TOKEN: "internal-test" } as never
      expect((await pairApprove(env, sessionPrincipal(user, team), { op: "server.pair.approve", params: { code, team, name: "Studio" }, idempotency_key: `platform-${status}` }, userSubmit as never)).ok).toBe(true)
      await waiter.until(() => waiter.frames.some((f) => f.t === "paired"))
      expect(waiter.frames.find((f) => f.t === "paired").machine_join).toBeUndefined()
    })
  }

  it("a retry after a failed host write reuses the pinned token and mints no second one", async () => {
    const { team, user, code, waiter } = await setup("stack-pair-machine-join-retry")
    const fake = platform(minted)
    const teams = testEnv.TEAM_DO
    const realTeam = teams.get(teams.idFromName(team)) as any
    // The host write fails once without a refusal (an owner outage); the install is already registered.
    const flaky = { idFromName: (n: string) => teams.idFromName(n), get: () => ({ canEnrollServer: (...a: Array<unknown>) => realTeam.canEnrollServer(...a), enrollServer: async () => ({ ok: false, code: "owner.unreachable", message: "fixture outage" }) }) }
    const approve = (teamDo: unknown) => pairApprove({ PAIRING_DO: testEnv.PAIRING_DO, TEAM_DO: teamDo, PLATFORM: fake, INTERNAL_TOKEN: "internal-test" } as never, sessionPrincipal(user, team), { op: "server.pair.approve", params: { code, team, name: "Studio" }, idempotency_key: "retry-pinned" }, userSubmit as never)
    expect(await approve(flaky)).toMatchObject({ ok: false })
    expect((await approve(testEnv.TEAM_DO)).ok).toBe(true)
    expect(fake.calls).toHaveLength(1)
    await waiter.until(() => waiter.frames.some((f) => f.t === "paired"))
    expect(waiter.frames.find((f) => f.t === "paired").machine_join.token).toBe(TOKEN)
  })

  it("a retry after the pinned token expired mints a fresh one and pushes only that", async () => {
    const { team, user, code, waiter } = await setup("stack-pair-machine-join-expired")
    const FRESH = `cmj_${"b".repeat(43)}`
    let first = true
    const fake = platform(() => {
      // The first token lives only 200 ms, so it has expired by the retry.
      const reply = first
        ? Response.json({ joinTokenId: "join_1", token: TOKEN, expiresAt: new Date(Date.now() + 200).toISOString(), teamId: "t" })
        : Response.json({ joinTokenId: "join_2", token: FRESH, expiresAt: new Date(Date.now() + 600_000).toISOString(), teamId: "t" })
      first = false
      return reply
    })
    const teams = testEnv.TEAM_DO
    const realTeam = teams.get(teams.idFromName(team)) as any
    const flaky = { idFromName: (n: string) => teams.idFromName(n), get: () => ({ canEnrollServer: (...a: Array<unknown>) => realTeam.canEnrollServer(...a), enrollServer: async () => ({ ok: false, code: "owner.unreachable", message: "fixture outage" }) }) }
    const approve = (teamDo: unknown) => pairApprove({ PAIRING_DO: testEnv.PAIRING_DO, TEAM_DO: teamDo, PLATFORM: fake, INTERNAL_TOKEN: "internal-test" } as never, sessionPrincipal(user, team), { op: "server.pair.approve", params: { code, team, name: "Studio" }, idempotency_key: "retry-expired" }, userSubmit as never)
    expect(await approve(flaky)).toMatchObject({ ok: false })
    await new Promise((r) => setTimeout(r, 300))
    expect((await approve(testEnv.TEAM_DO)).ok).toBe(true)
    expect(fake.calls).toHaveLength(2)
    await waiter.until(() => waiter.frames.some((f) => f.t === "paired"))
    expect(waiter.frames.find((f) => f.t === "paired").machine_join.token).toBe(FRESH)
  })

  // Production pairing e2e (cmuxterm-hq run 42125193131): "server.revoke left the machine live". The server's
  // revoke must also revoke the cmm_ machine its join token made, as `cmux machine revoke` does.
  it("server.revoke revokes the machine its join token made, and retries a platform outage until it lands", async () => {
    const { owner, team, user, code, waiter } = await setup("stack-pair-machine-join-revoke")
    const env = { PAIRING_DO: testEnv.PAIRING_DO, TEAM_DO: testEnv.TEAM_DO, PLATFORM: platform(minted), INTERNAL_TOKEN: "internal-test" } as never
    const approved = await pairApprove(env, sessionPrincipal(user, team), { op: "server.pair.approve", params: { code, team, name: "Studio" }, idempotency_key: "machine-join-revoke" }, userSubmit as never)
    expect(approved.ok).toBe(true)
    await waiter.until(() => waiter.frames.some((f) => f.t === "paired"))
    const { host, install } = (approved as { value: { host: string; install: string } }).value
    const teamStub = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team)) as any
    expect((await teamStub.debug(team)).state.server_machine_joins).toEqual({ [install]: "join_1" })

    // The platform is down until `up`; TeamDO's own alarm may retry meanwhile, and keeps the item while it is down.
    let up = false
    const calls: Array<[string, string]> = []
    await inDO(teamStub, async (instance) => {
      instance.machineJoins = async (t: string, id: string) => (calls.push([t, id]), up ? "done" : "retry")
    })
    const revoked = await op(owner, "server.revoke", { host })
    expect(revoked.json).toMatchObject({ ok: true, value: { host, install_revoked: true } })
    expect(calls.length).toBeGreaterThanOrEqual(1)
    expect(new Set(calls.map((c) => c.join(" ")))).toEqual(new Set([`${team} join_1`]))
    // The install is revoked at once; the machine's revocation stays pending until the platform confirms.
    expect((await call("/v1/auth/challenge", undefined, { user, install })).status).toBe(403)
    const state = async () => (await teamStub.debug(team)).state
    expect((await state()).server_revocations?.[install]).toMatchObject({ machine_join_token: "join_1" })
    expect((await state()).server_machine_joins ?? {}).toEqual({})
    up = true
    const before = calls.length
    await inDO(teamStub, async (instance) => {
      instance.revokeRetryAt = 0
    })
    await runAlarm(teamStub)
    expect(calls.length).toBeGreaterThan(before)
    expect((await state()).server_revocations ?? {}).toEqual({})
  })

  it("without the platform binding the box pairs as before, with no join token", async () => {
    const { team, user, code, waiter } = await setup("stack-pair-machine-join-unbound")
    const env = { PAIRING_DO: testEnv.PAIRING_DO, TEAM_DO: testEnv.TEAM_DO } as never
    expect((await pairApprove(env, sessionPrincipal(user, team), { op: "server.pair.approve", params: { code, team, name: "Studio" }, idempotency_key: "unbound" }, userSubmit as never)).ok).toBe(true)
    await waiter.until(() => waiter.frames.some((f) => f.t === "paired"))
    expect(waiter.frames.find((f) => f.t === "paired").machine_join).toBeUndefined()
  })
})
