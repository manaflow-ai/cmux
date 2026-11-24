import { beforeAll, describe, expect, it } from "vitest"
import { advance, as, call, chatStub, copied, fakeClock, fakeCloud, get, indexStub, lapse, LAPTOP, lease, listed, lookAgain, M, M2, open, person, post, runIn, setMachine, starts, takenOver, VM, vmBearer } from "./auto-sessions-support.ts"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * The store finds the owner's Auto machine itself (src/auto-sessions/machine-pick.ts, index-do.ts `autoMachine`):
 * no client names one, so a chat that needs a machine goes to one of the owner's own Cloud machines.
 */
describe("auto sessions: the Auto machine nobody named", { timeout: 60_000 }, () => {
  beforeAll(fakeClock)

  const VM2 = `vm:${M2}`
  const machine = (t: string) => call("GET", "/v1/auto-sessions/machine", as(t))
  const other = (letter: string) => `vm_${letter.repeat(20)}`

  it("a lease that runs out with work waiting goes to the owner's own machine: the one that runs, and the same one for the next chat", async () => {
    const a = await person("pick")
    const mate = await person("pick-mate")
    const m = await fakeCloud(a.user)
    m.machines.push(
      listed(a, M, { last_active_at: 9_000 }),
      listed(a, M2, { status: "running", last_active_at: 5 }),
      // Not the owner's to use: a teammate's, one being deleted, one that failed, one still on cmux Cloud classic.
      listed(a, other("c"), { status: "running", creator: mate.user, last_active_at: 99_999 }),
      listed(a, other("d"), { status: "deleting", last_active_at: 99_999 }),
      listed(a, other("e"), { status: "failed", last_active_at: 99_999 }),
      listed(a, other("f"), { status: "running", classic: true, last_active_at: 99_999 })
    )
    await takenOver(a, "run")
    expect((await get(a.session, "run")).body.session).toMatchObject({ holder: VM2, epoch: 2, state: "resuming", blocked: null, needsRun: true, team: a.team })
    expect(m.lists).toBe(1)
    expect((await machine(a.session)).body).toEqual({ team: a.team, machine: M2 })
    // It is the Auto machine in every way: it reads its assignment, and its start is open.
    const vm2 = await vmBearer(a, M2)
    expect((await call("GET", "/v1/auto-sessions/assignments?timeoutMs=0", as(vm2))).body.assignments).toMatchObject([{ kind: "takeover", session: { id: "run", epoch: 2 } }])
    await fireAlarm(indexStub(a.user))
    expect(await starts(a.user)).toMatchObject([{ machine: M2, team: a.team, owner: a.user }])
    // The pick is kept: another machine runs now and this one is paused, and the next chat still goes to it. The
    // store read the pick again (it is still the owner's) and did not choose anew.
    m.machines[0]!.status = "running"
    m.machines[1]!.status = "paused"
    advance(60_001)
    const reads = m.reads
    await takenOver(a, "next")
    expect((await get(a.session, "next")).body.session).toMatchObject({ holder: VM2, epoch: 2 })
    expect([m.lists, m.reads]).toEqual([1, reads + 1])

    // With none running: the one used or made last.
    const b = await person("pick-recent")
    const mb = await fakeCloud(b.user)
    mb.machines.push(listed(b, M, { created_at: 50, last_active_at: 60 }), listed(b, M2, { created_at: 70 }))
    expect((await machine(b.session)).body).toEqual({ team: b.team, machine: M2 })
  })

  it("nothing is picked from a team the owner may not use, nor a machine someone else made", async () => {
    const a = await person("foreign")
    const mate = await person("foreign-mate")
    const team = `team_${"0".repeat(20)}`
    const m = await fakeCloud(a.user)
    m.machines.push(listed(a, M, { team, status: "running" }), listed(a, M2, { status: "running", creator: mate.user }))
    await open(a.session, "theirs")
    await lease(a.session, "theirs", LAPTOP, 1, { needsRun: true })
    // The chat is of a team its owner has left since.
    await runIn(chatStub(a.user, "theirs"), async (_i, state) => void state.storage.sql.exec(`UPDATE session SET team = ?`, team))
    await lapse(a.user, "theirs")
    expect((await get(a.session, "theirs")).body.session).toMatchObject({ holder: "parked", epoch: 2, blocked: "no_machine", needsRun: true, team })
    // That team's machines were never read.
    expect(m.lists).toBe(0)
    // In their own team the only machine is a teammate's.
    const none = await machine(a.session)
    expect([none.status, none.body.error.code, m.lists]).toEqual([404, "auto.no_machine", 1])
    // The alarm's look does no better: it asks only for the chat's team, and reads nothing of it.
    advance(15_000)
    await fireAlarm(indexStub(a.user))
    expect((await get(a.session, "theirs")).body.session).toMatchObject({ holder: "parked", blocked: "no_machine" })
    expect(m.lists).toBe(1)
  })

  it("no machine: the chat waits, and a machine made later is found at the owner's next read of the chat, at their list, or by the alarm", async () => {
    const a = await person("later")
    const m = await fakeCloud(a.user)
    await takenOver(a, "waits")
    expect((await get(a.session, "waits")).body.session).toMatchObject({ holder: "parked", epoch: 2, state: "parked", blocked: "no_machine", needsRun: true })
    // A read straight after does not read the Cloud again, and a renewal never does.
    expect(m.lists).toBe(1)
    lookAgain()
    expect((await lease(a.session, "waits", "device:mac2", 1)).body.role).toBe("lost")
    expect(m.lists).toBe(1)
    // The person makes a machine. Their next read of the chat finds it, with nothing else to do.
    m.machines.push(listed(a, M, { status: "provisioning" }))
    expect((await get(a.session, "waits")).body.session).toMatchObject({ holder: VM, epoch: 3, state: "resuming", blocked: null })
    expect(m.lists).toBe(2)
    expect((await machine(a.session)).body).toEqual({ team: a.team, machine: M })

    // Their list finds it for every chat that waits.
    const b = await person("later-list")
    const mb = await fakeCloud(b.user)
    await takenOver(b, "one")
    await takenOver(b, "two")
    mb.machines.push(listed(b, M2, { status: "running" }))
    lookAgain()
    const page = await call("GET", "/v1/auto-sessions", as(b.session))
    expect(page.body.sessions.map((s: any) => [s.id, s.holder, s.blocked, s.state])).toEqual([["two", VM2, null, "resuming"], ["one", VM2, null, "resuming"]])

    // Nobody calls: the index's alarm looks again, waiting longer each time it finds nothing, and starts the machine it finds.
    const c = await person("later-alarm")
    const mc = await fakeCloud(c.user)
    await takenOver(c, "left")
    const look = () => runIn(indexStub(c.user), async (_i, state) => state.storage.sql.exec(`SELECT tries, next_at FROM look`).toArray()[0] as { tries: number; next_at: number } | undefined)
    const first = await look()
    expect(first!.tries).toBe(0)
    expect(first!.next_at - Date.now()).toBeGreaterThan(0)
    expect(first!.next_at - Date.now()).toBeLessThanOrEqual(15_000)
    await fireAlarm(indexStub(c.user))
    expect(mc.lists).toBe(1)
    advance(15_000)
    await fireAlarm(indexStub(c.user))
    const second = await look()
    expect([mc.lists, second!.tries]).toEqual([2, 1])
    expect(second!.next_at - Date.now()).toBeGreaterThan(15_000)
    mc.machines.push(listed(c, M))
    advance(30_000)
    await fireAlarm(indexStub(c.user))
    expect((await get(c.session, "left")).body.session).toMatchObject({ holder: VM, epoch: 3, state: "resuming", blocked: null })
    expect(await look()).toBeUndefined()
    await fireAlarm(indexStub(c.user))
    expect(mc.starts).toEqual([`auto-session-start:${c.user}:${M}:rev1`])
  })

  it("a machine the owner names replaces the pick, and no pick replaces it", async () => {
    const a = await person("named")
    const m = await fakeCloud(a.user)
    m.machines.push(listed(a, M2, { status: "running" }))
    await takenOver(a, "moved")
    expect((await get(a.session, "moved")).body.session).toMatchObject({ holder: VM2, epoch: 2 })
    expect((await setMachine(a)).body).toEqual({ team: a.team, machine: M })
    // The chat the pick never picked up goes to the named machine.
    expect((await get(a.session, "moved")).body.session).toMatchObject({ holder: VM, epoch: 3, state: "resuming" })
    expect((await machine(a.session)).body).toEqual({ team: a.team, machine: M })
    // So do later chats, long after, though the owner's machines do not list it: a named machine is not read again.
    advance(120_000)
    const reads = m.reads
    await takenOver(a, "after")
    expect((await get(a.session, "after")).body.session).toMatchObject({ holder: VM, epoch: 2 })
    expect((await machine(a.session)).body).toEqual({ team: a.team, machine: M })
    expect([m.lists, m.reads]).toEqual([1, reads])
  })

  it("a chat started with no laptop, and a message for a parked chat, find the owner's machine too", async () => {
    const a = await person("phone-pick")
    const m = await fakeCloud(a.user)
    const body = { harness: "claude", repo: { remote: "https://example.com/acme/web.git", branch: "main" }, firstMessage: { id: "first", text: "start on the flaky test" } }
    const none = await call("POST", "/v1/auto-sessions", as(a.session), body)
    expect([none.status, none.body.error.code]).toEqual([409, "auto.no_machine"])
    m.machines.push(listed(a, M, { status: "running" }))
    lookAgain()
    const made = await call("POST", "/v1/auto-sessions", as(a.session), body)
    expect(made.status).toBe(201)
    expect(made.body.session).toMatchObject({ holder: VM, epoch: 1, state: "resuming", inbox: 1, team: a.team })
    const vm = await vmBearer(a, M)
    expect((await call("GET", "/v1/auto-sessions/assignments?timeoutMs=0", as(vm))).body.assignments).toMatchObject([{ kind: "create", session: { id: made.body.session.id } }])

    const b = await person("parked-message")
    const mb = await fakeCloud(b.user)
    await open(b.session, "idle")
    await copied(b.session, "idle")
    await lapse(b.user, "idle")
    expect((await get(b.session, "idle")).body.session).toMatchObject({ holder: "parked", epoch: 2, blocked: null })
    mb.machines.push(listed(b, M2))
    lookAgain()
    expect((await post(b.session, "idle", "inbox", { id: "m1", text: "go on" })).body).toMatchObject({ state: "resuming", session: { holder: VM2, epoch: 3, state: "resuming", inbox: 1 } })
  })

  it("a pick whose machine is gone is replaced by another of the owner's; while the Cloud cannot be read it stays", async () => {
    const a = await person("gone")
    const m = await fakeCloud(a.user)
    m.machines.push(listed(a, M2, { status: "running" }))
    await takenOver(a, "first")
    expect((await get(a.session, "first")).body.session).toMatchObject({ holder: VM2, epoch: 2 })
    m.failRead = true
    advance(60_001)
    expect((await machine(a.session)).body).toEqual({ team: a.team, machine: M2 })
    // The person deletes that machine and makes another: the next chat goes to the new one, and so does the chat
    // the deleted one never picked up.
    m.failRead = false
    m.machines.splice(0, 1, listed(a, M))
    advance(60_001)
    await takenOver(a, "second")
    expect((await get(a.session, "second")).body.session).toMatchObject({ holder: VM, epoch: 2 })
    expect((await machine(a.session)).body).toEqual({ team: a.team, machine: M })
    expect((await get(a.session, "first")).body.session).toMatchObject({ holder: VM, epoch: 3, state: "resuming" })
    // With none left, the pick is dropped and chats wait as they do for an owner with no machine.
    m.machines.length = 0
    advance(60_001)
    await takenOver(a, "third")
    expect((await get(a.session, "third")).body.session).toMatchObject({ holder: "parked", epoch: 2, blocked: "no_machine" })
    expect((await machine(a.session)).status).toBe(404)
  })
})
