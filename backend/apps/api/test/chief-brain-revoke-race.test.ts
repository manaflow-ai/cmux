import { describe, expect, it } from "vitest"
import { b64u, beginPairing, call, inDO, op, read, sessionToken, testEnv, waitFor } from "./pairing-harness.ts"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * The placed Chief's server loses the chief's rights as soon as TeamDO commits `server.revoke`,
 * also while TeamDO's push of the install revocation to UserDO is still pending (the revoke race,
 * review P3): TeamDO is the authority for a server, so a mutate-shared answer as the chief asks it.
 */
const runAlarm = fireAlarm as unknown as (stub: unknown) => Promise<boolean>

describe("placed chief and a server revoked in TeamDO only", { timeout: 60_000 }, () => {
  it("refuses the placed server's send while UserDO has not yet heard of the revoke", async () => {
    const owner = await sessionToken("brain-revoke-race")
    const user = (await op(owner, "user.ensure", {})).json.value.id as string
    const { res, pair } = await beginPairing()
    const code = res.json.code as string
    const waiter = await waitFor(code, res.json.collect_secret)
    const team = (await read(owner, "team.directory", {})).json.value.team as string
    const server = (await op(owner, "server.pair.approve", { code, team, name: "Brain" })).json.value as { host: string; install: string; user: string }
    await waiter.until(() => waiter.frames.some((f) => f.t === "paired"))
    const chief = (await op(owner, "chief.create", { brain_place: { host: server.host, install: server.install } }, "chief-default")).json.value
    const userDO = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))
    for (let i = 0; i < 20 && (await read(owner, "conversation.history", { conversation: chief.main_conversation, limit: 1 })).status !== 200; i++) await runAlarm(userDO)

    const ch = await call("/v1/auth/challenge", undefined, { user: server.user, install: server.install })
    const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`))
    const token = (await call("/v1/auth/token", undefined, { user: server.user, install: server.install, nonce: ch.json.nonce, signature: b64u(sig), agent: chief.id })).json.access_token as string
    // The owner speaks first each time: a chief answers, it does not post twice in a row (agent_rate).
    const ask = (id: string) => op(owner, "message.send", { conversation: chief.main_conversation, client_msg_id: id, parts: [{ type: "text", text: id }] }, id)
    const send = (id: string) => op(token, "message.send", { conversation: chief.main_conversation, client_msg_id: id, parts: [{ type: "text", text: id }] }, id)
    expect((await ask("ask-1")).json.ok).toBe(true)
    expect((await send("before")).json.ok).toBe(true)
    expect((await ask("ask-2")).json.ok).toBe(true)

    // TeamDO's push to UserDO fails (delayed): the revoke commits in TeamDO only.
    await inDO(userDO, async (instance) => {
      instance.revokeByTeam = async () => {
        throw new Error("push delayed")
      }
    })
    expect((await op(owner, "server.revoke", { host: server.host })).json.ok).toBe(true)
    const installs = (await read(owner, "install.list", {})).json.value.installs as Array<{ id: string; revoked_at: number | null }>
    expect(installs.find((i) => i.id === server.install)?.revoked_at, "UserDO has not applied the revoke yet").toBeNull()

    // Past the 2 s gap between two agent messages (MIN_AGENT_GAP_MS), so only the revoke can refuse.
    await new Promise((r) => setTimeout(r, 2_100))
    const after = (await send("after-revoke")).json
    expect(after.ok, JSON.stringify(after)).toBe(false)
    expect(after.error.code).toBe("auth.forbidden")
  })
})
