import { beforeAll, describe, expect, it } from "vitest"
import { as, call, fakeCloud, fakeClock, listed, M, M2, person, setMachine } from "./auto-sessions-support.ts"

/**
 * A named Auto machine is held to the rule the store's own pick follows (machine-pick.ts `candidate`): one of the
 * owner's own machines in that team, not a classic one (security review of cmux#52931, item 2). Before, any machine
 * id in a team the owner could use was taken, so a teammate's machine could be named and be handed the owner's
 * chats, their copies and their messages.
 */
const machineOf = (t: string) => call("GET", "/v1/auto-sessions/machine", as(t))
const forbidden = { status: 403, body: { error: { code: "auth.forbidden" } } }

describe("auto sessions: the Auto machine the owner names", { timeout: 60_000 }, () => {
  beforeAll(fakeClock)

  it("is one of the owner's own machines in the team; a teammate's, a classic or a missing one is refused 403", async () => {
    const a = await person("name-own")
    const m = await fakeCloud(a.user)
    m.machines.push(listed(a, M), listed(a, M2, { creator: "user_someone_else_000000" }), listed(a, "vm_cccccccccccccccccccc", { classic: true }))
    expect(await setMachine(a, M2)).toMatchObject(forbidden)
    expect(await setMachine(a, "vm_cccccccccccccccccccc")).toMatchObject(forbidden)
    expect(await setMachine(a, "vm_dddddddddddddddddddd")).toMatchObject(forbidden)
    // Nothing was named by the refusals: the owner's own machine is still the one the store picks.
    expect((await machineOf(a.installToken)).body).toEqual({ team: a.team, machine: M })
    expect((await setMachine(a, M)).body).toEqual({ team: a.team, machine: M })
  })

  it("is not taken when the Cloud cannot say whose machine it is", async () => {
    const a = await person("name-unread")
    const m = await fakeCloud(a.user)
    m.failRead = true
    const r = await setMachine(a, M)
    expect(r.status).toBe(503)
    m.failRead = false
    expect((await machineOf(a.installToken)).status).toBe(404)
  })
})
