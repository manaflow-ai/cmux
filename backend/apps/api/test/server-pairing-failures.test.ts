import { describe, expect, it } from "vitest"
import { codeFromRandom } from "../src/domains/pairing.ts"
import { pairApprove } from "../src/pair-routes.ts"
import { beginPairing, call, inDO, op, read, runAlarm, sessionPrincipal, sessionToken, testEnv, userSubmit, waitFor } from "./pairing-harness.ts"

/** Server pairing failure paths (workerd): role loss, approve rate limits, lost replies and revocation retries. */
describe("server pairing failure paths (workerd)", () => {
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
    const principal = sessionPrincipal(approverUser, team)
    const r = await pairApprove(fakeEnv, principal, { op: "server.pair.approve", params: { code, team, name: "Studio" }, idempotency_key: "roleloss" }, userSubmit as never)
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
    await waiter.until(() => waiter.frames.some((f) => f.t === "refused") && waiter.closes.length > 0)
    expect(waiter.closes).toEqual([4403])
    expect((await read(owner, "server.pair.preview", { code })).status).toBe(400)
    // TeamDO's ledger replays the refusal for the same key: a retry can never add a host for the revoked install.
    const replay = await teamStub.enrollServer(team, principal, { install: inst.id, name: "Studio", platform: "linux", wg_public_key: wg }, `pair:${code}:${thumb}:host`)
    expect(replay).toMatchObject({ ok: false, code: "auth.forbidden", refused: true })
  })

  it("approval retries pass on the retry budget after the guessing budget; PairingDO wakes stay bounded", async () => {
    const owner = await sessionToken("stack-pair-retry-limit")
    await op(owner, "user.ensure", {})
    const team = (await read(owner, "team.directory", {})).json.value.team as string
    const user = (await read(owner, "install.list", {})).json.value.user.id as string
    const { res } = await beginPairing(Date.now(), false, "203.0.113.11")
    const code = res.json.code as string
    // Real owners; a per-key counting limiter with the binding's budget (the binding's wall-clock window would make this flaky).
    const spent: Record<string, number> = {}
    const limiter = { limit: async ({ key }: { key: string }) => ((spent[key] = (spent[key] ?? 0) + 1), { success: spent[key]! <= 10 }) }
    let wakes = 0
    const pairing = {
      idFromName: (n: string) => testEnv.PAIRING_DO.idFromName(n),
      get: (id: DurableObjectId) => {
        const real = testEnv.PAIRING_DO.get(id) as any
        const counted = (m: string) => (...a: Array<unknown>) => ((wakes += 1), real[m](...a))
        return { claimedBy: counted("claimedBy"), claim: counted("claim"), complete: counted("complete"), abort: counted("abort") }
      }
    }
    const realEnv = { PAIRING_DO: pairing, TEAM_DO: testEnv.TEAM_DO, PAIR_BEGIN_LIMIT: limiter } as never
    const principal = sessionPrincipal(user, team)
    const approve = (c: string) => pairApprove(realEnv, principal, { op: "server.pair.approve", params: { code: c, team, name: "Studio" }, idempotency_key: crypto.randomUUID() }, userSubmit as never)
    const first = await approve(code)
    expect(first.ok).toBe(true)
    // More retries than the guessing budget (a client that lost the replies): the last three pass on the retry budget.
    for (let i = 0; i < 12; i++) expect(await approve(code)).toMatchObject({ ok: true, value: first.value })
    expect(spent).toEqual({ [`user:${user}`]: 13, [`user-retry:${user}`]: 3 })
    // Guesses with both budgets in play: each refused guess spends a retry unit first, so at most 7 more PairingDO wakes.
    wakes = 0
    const guesses: Array<any> = []
    for (let i = 0; i < 20; i++) guesses.push(await approve(codeFromRandom(crypto.getRandomValues(new Uint8Array(5)))))
    expect(guesses.every((g) => g.error.code === "auth.forbidden" && g.error.retryable)).toBe(true)
    expect(wakes).toBe(7)
    // A fresh user: ten guesses reach PairingDO, then every refused guess wakes it only while the retry budget lasts.
    const other = await sessionToken("stack-pair-guesser")
    await op(other, "user.ensure", {})
    const otherUser = (await read(other, "install.list", {})).json.value.user.id as string
    const otherTeam = (await read(other, "team.directory", {})).json.value.team as string
    const guesser = sessionPrincipal(otherUser, otherTeam)
    wakes = 0
    const results: Array<any> = []
    for (let i = 0; i < 30; i++) {
      results.push(await pairApprove(realEnv, guesser, { op: "server.pair.approve", params: { code: codeFromRandom(crypto.getRandomValues(new Uint8Array(5))), team: otherTeam, name: "x" }, idempotency_key: crypto.randomUUID() }, userSubmit as never))
    }
    expect(results.slice(0, 10).map((g) => g.error.code)).toEqual(Array(10).fill("selector.not_found"))
    expect(results.slice(10).every((g) => g.error.code === "auth.forbidden" && g.error.retryable)).toBe(true)
    expect(wakes).toBe(20)
  })

  it("a demoted approver's retry after a lost enrollment revokes the install; a lost abort is finished by the next retry", async () => {
    const owner = await sessionToken("stack-pair-demoted-owner")
    const approver = await sessionToken("stack-pair-demoted-admin")
    await op(owner, "user.ensure", {})
    await op(approver, "user.ensure", {})
    const team = (await read(owner, "team.directory", {})).json.value.team as string
    const approverUser = (await read(approver, "install.list", {})).json.value.user.id as string
    const { res, pair } = await beginPairing(Date.now(), false, "203.0.113.13")
    const code = res.json.code as string
    const waiter = await waitFor(code, res.json.collect_secret)
    await waiter.until(() => waiter.frames.length >= 1)

    // Attempt 1: still an admin; UserDO registers the install, then the TeamDO call throws (owner unreachable).
    // Attempt 2: demoted, so the early check says no; TeamDO commits the refusal and revocation, then abort is lost.
    // Attempt 3: demoted; the claim is still this approver's, so the retry replays the refusal and spends the code.
    let attempt = 0
    const teams = testEnv.TEAM_DO
    const teamStub = teams.get(teams.idFromName(team)) as any
    const fakeEnv = {
      PAIRING_DO: {
        idFromName: (n: string) => testEnv.PAIRING_DO.idFromName(n),
        get: (id: DurableObjectId) => {
          const real = testEnv.PAIRING_DO.get(id) as any
          return {
            claimedBy: (...a: Array<unknown>) => real.claimedBy(...a),
            claim: (...a: Array<unknown>) => real.claim(...a),
            complete: (...a: Array<unknown>) => real.complete(...a),
            abort: async (...a: Array<unknown>) => {
              if (attempt === 2) throw new Error("abort lost")
              return real.abort(...a)
            }
          }
        }
      },
      TEAM_DO: {
        idFromName: (n: string) => teams.idFromName(n),
        get: () => ({
          canEnrollServer: async () => attempt === 1,
          enrollServer: async (...a: Array<unknown>) => {
            if (attempt === 1) throw new Error("owner unreachable")
            return teamStub.enrollServer(...a)
          }
        })
      }
    } as never
    const principal = sessionPrincipal(approverUser, team)
    const approve = () => pairApprove(fakeEnv, principal, { op: "server.pair.approve", params: { code, team, name: "Studio" }, idempotency_key: "demoted" }, userSubmit as never)

    attempt = 1
    await expect(approve()).rejects.toThrow("owner unreachable")
    const registered = (await read(approver, "install.list", {})).json.value.installs.find((i: any) => i.kind === "daemon")
    expect(registered.revoked_at).toBeNull()

    attempt = 2
    await expect(approve()).rejects.toThrow("abort lost")
    // The window between the refusal commit and the abort: the install is already revoked, the code is still claimed.
    expect((await read(approver, "install.list", {})).json.value.installs.find((i: any) => i.id === registered.id).revoked_at).not.toBeNull()
    expect((await teamStub.debug(team)).state.server_revocations ?? {}).toEqual({})
    expect(waiter.closes).toEqual([])

    attempt = 3
    expect(await approve()).toMatchObject({ ok: false, error: { code: "auth.forbidden" } })
    await waiter.until(() => waiter.closes.length > 0)
    expect(waiter.frames.at(-1)).toEqual({ t: "refused" })
    expect(waiter.closes).toEqual([4403])
    expect(((await read(owner, "team.directory", {})).json.value.hosts as Array<{ kind?: string }>).filter((h) => h.kind === "server")).toHaveLength(0)
    // One install, revoked; the server may pair the same key again (into the approver's own team here).
    const installs = (await read(approver, "install.list", {})).json.value.installs.filter((i: any) => i.kind === "daemon")
    expect(installs).toHaveLength(1)
    const again = await beginPairing(Date.now(), false, "203.0.113.14", pair)
    const ownTeam = (await read(approver, "team.directory", {})).json.value.team as string
    const repaired = await op(approver, "server.pair.approve", { code: again.res.json.code, team: ownTeam, name: "Studio" })
    expect(repaired.json).toMatchObject({ ok: true, value: { team: ownTeam } })
    expect(repaired.json.value.install).not.toBe(registered.id)
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
