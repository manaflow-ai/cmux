import { env } from "cloudflare:workers"
import { beforeAll, describe, expect, it } from "vitest"
import { advance, as, call, chatStub, copied, fakeClock, fakeCloud, get, indexStub, lapse, LAPTOP, lease, listed, lookAgain, M, M2, open, person, post, runIn, setMachine, starts, takenOver, VM, vmBearer, type Person } from "./auto-sessions-support.ts"
import { fireAlarm } from "./setup/alarm.ts"
import { deliver, memberRow, stackWorld, teamIdOf, useStack } from "./team-stack-support.ts"

const VM2 = `vm:${M2}`
const other = (letter: string) => `vm_${letter.repeat(20)}`
const machine = (t: string) => call("GET", "/v1/auto-sessions/machine", as(t))
const session = async (a: Person, id: string) => (await get(a.installToken, id)).body.session
/** The chats `id` (a machine) still has to pick up. */
const assigned = async (a: Person, id: string): Promise<Array<string>> =>
  ((await call("GET", "/v1/auto-sessions/assignments?timeoutMs=0", as(await vmBearer(a, id)))).body.assignments as Array<{ session: { id: string } }>).map((x) => x.session.id).sort()

/**
 * The store finds the owner's Auto machine itself (src/auto-sessions/machine-pick.ts, index-do.ts `autoMachine`):
 * no client names one, so a chat that needs a machine goes to one of the owner's own Cloud machines.
 */
describe("auto sessions: the Auto machine nobody named", { timeout: 60_000 }, () => {
  beforeAll(fakeClock)

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
    expect((await get(a.installToken, "run")).body.session).toMatchObject({ holder: VM2, epoch: 2, state: "resuming", blocked: null, needsRun: true, team: a.team })
    expect(m.lists).toBe(1)
    expect((await machine(a.installToken)).body).toEqual({ team: a.team, machine: M2 })
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
    expect((await get(a.installToken, "next")).body.session).toMatchObject({ holder: VM2, epoch: 2 })
    expect([m.lists, m.reads]).toEqual([1, reads + 1])

    // With none running: the one used or made last.
    const b = await person("pick-recent")
    const mb = await fakeCloud(b.user)
    mb.machines.push(listed(b, M, { created_at: 50, last_active_at: 60 }), listed(b, M2, { created_at: 70 }))
    expect((await machine(b.installToken)).body).toEqual({ team: b.team, machine: M2 })
  })

  it("nothing is picked from a team the owner may not use, nor a machine someone else made", async () => {
    const a = await person("foreign")
    const mate = await person("foreign-mate")
    const team = `team_${"0".repeat(20)}`
    const m = await fakeCloud(a.user)
    m.machines.push(listed(a, M, { team, status: "running" }), listed(a, M2, { status: "running", creator: mate.user }))
    await open(a.installToken, "theirs")
    await lease(a.installToken, "theirs", LAPTOP, 1, { needsRun: true })
    // The chat is of a team its owner has left since.
    await runIn(chatStub(a.user, "theirs"), async (_i, state) => void state.storage.sql.exec(`UPDATE session SET team = ?`, team))
    await lapse(a.user, "theirs")
    expect((await get(a.installToken, "theirs")).body.session).toMatchObject({ holder: "parked", epoch: 2, blocked: "no_machine", needsRun: true, team })
    // That team's machines were never read.
    expect(m.lists).toBe(0)
    // In their own team the only machine is a teammate's.
    const none = await machine(a.installToken)
    expect([none.status, none.body.error.code, m.lists]).toEqual([404, "auto.no_machine", 1])
    // The alarm's look does no better: it asks only for the chat's team, and reads nothing of it.
    advance(15_000)
    await fireAlarm(indexStub(a.user))
    expect((await get(a.installToken, "theirs")).body.session).toMatchObject({ holder: "parked", blocked: "no_machine" })
    expect(m.lists).toBe(1)
  })

  it("no machine: the chat waits, and a machine made later is found at the owner's next read of the chat, at their list, or by the alarm", async () => {
    const a = await person("later")
    const m = await fakeCloud(a.user)
    await takenOver(a, "waits")
    expect((await get(a.installToken, "waits")).body.session).toMatchObject({ holder: "parked", epoch: 2, state: "parked", blocked: "no_machine", needsRun: true })
    // A read straight after does not read the Cloud again.
    expect(m.lists).toBe(1)
    // The person makes a machine. A renewal never looks for one, though a look is due and the renewal is accepted
    // and written: a second laptop stands by on the chat, which is kept in the Cloud and so stays parked.
    expect((await post(a.installToken, "waits", "keep", { keepInCloud: true })).status).toBe(200)
    m.machines.push(listed(a, M, { status: "provisioning" }))
    lookAgain()
    expect((await lease(a.installToken, "waits", "device:mac2", 1, { standby: true })).body).toMatchObject({ role: "standby", session: { holder: "parked", epoch: 2, blocked: "no_machine", standby: ["device:mac2"] } })
    expect(m.lists).toBe(1)
    // Their next read of the chat finds the machine, with nothing else to do.
    expect((await get(a.installToken, "waits")).body.session).toMatchObject({ holder: VM, epoch: 3, state: "resuming", blocked: null })
    expect(m.lists).toBe(2)
    expect((await machine(a.installToken)).body).toEqual({ team: a.team, machine: M })

    // Their list finds it for every chat that waits.
    const b = await person("later-list")
    const mb = await fakeCloud(b.user)
    await takenOver(b, "one")
    await takenOver(b, "two")
    mb.machines.push(listed(b, M2, { status: "running" }))
    lookAgain()
    const page = await call("GET", "/v1/auto-sessions", as(b.installToken))
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
    expect((await get(c.installToken, "left")).body.session).toMatchObject({ holder: VM, epoch: 3, state: "resuming", blocked: null })
    expect(await look()).toBeUndefined()
    await fireAlarm(indexStub(c.user))
    expect(mc.starts).toEqual([`auto-session-start:${c.user}:${M}:rev1`])
  })

  it("a machine the owner names replaces the pick, and no pick replaces it", async () => {
    const a = await person("named")
    const m = await fakeCloud(a.user)
    m.machines.push(listed(a, M2, { status: "running" }))
    await takenOver(a, "moved")
    expect((await get(a.installToken, "moved")).body.session).toMatchObject({ holder: VM2, epoch: 2 })
    expect((await setMachine(a)).body).toEqual({ team: a.team, machine: M })
    // The chat the pick never picked up goes to the named machine.
    expect((await get(a.installToken, "moved")).body.session).toMatchObject({ holder: VM, epoch: 3, state: "resuming" })
    expect((await machine(a.installToken)).body).toEqual({ team: a.team, machine: M })
    // So do later chats, long after, though the owner's machines do not list it: a named machine is not read again.
    advance(120_000)
    const reads = m.reads
    await takenOver(a, "after")
    expect((await get(a.installToken, "after")).body.session).toMatchObject({ holder: VM, epoch: 2 })
    expect((await machine(a.installToken)).body).toEqual({ team: a.team, machine: M })
    expect([m.lists, m.reads]).toEqual([1, reads])
  })

  it("a chat started with no laptop, and a message for a parked chat, find the owner's machine too", async () => {
    const a = await person("phone-pick")
    const m = await fakeCloud(a.user)
    const body = { harness: "claude", repo: { remote: "https://example.com/acme/web.git", branch: "main" }, firstMessage: { id: "first", text: "start on the flaky test" } }
    const none = await call("POST", "/v1/auto-sessions", as(a.installToken), body)
    expect([none.status, none.body.error.code]).toEqual([409, "auto.no_machine"])
    m.machines.push(listed(a, M, { status: "running" }))
    lookAgain()
    const made = await call("POST", "/v1/auto-sessions", as(a.installToken), body)
    expect(made.status).toBe(201)
    expect(made.body.session).toMatchObject({ holder: VM, epoch: 1, state: "resuming", inbox: 1, team: a.team })
    const vm = await vmBearer(a, M)
    expect((await call("GET", "/v1/auto-sessions/assignments?timeoutMs=0", as(vm))).body.assignments).toMatchObject([{ kind: "create", session: { id: made.body.session.id } }])

    const b = await person("parked-message")
    const mb = await fakeCloud(b.user)
    await open(b.installToken, "idle")
    await copied(b.installToken, "idle")
    await lapse(b.user, "idle")
    expect((await get(b.installToken, "idle")).body.session).toMatchObject({ holder: "parked", epoch: 2, blocked: null })
    mb.machines.push(listed(b, M2))
    lookAgain()
    expect((await post(b.installToken, "idle", "inbox", { id: "m1", text: "go on" })).body).toMatchObject({ state: "resuming", session: { holder: VM2, epoch: 3, state: "resuming", inbox: 1 } })
  })

  it("a pick whose machine is gone is replaced by another of the owner's; while the Cloud cannot be read it stays", async () => {
    const a = await person("gone")
    const m = await fakeCloud(a.user)
    m.machines.push(listed(a, M2, { status: "running" }))
    await takenOver(a, "first")
    expect((await get(a.installToken, "first")).body.session).toMatchObject({ holder: VM2, epoch: 2 })
    m.failRead = true
    advance(60_001)
    expect((await machine(a.installToken)).body).toEqual({ team: a.team, machine: M2 })
    // The person deletes that machine and makes another: the next chat goes to the new one, and so does the chat
    // the deleted one never picked up.
    m.failRead = false
    m.machines.splice(0, 1, listed(a, M))
    advance(60_001)
    await takenOver(a, "second")
    expect((await get(a.installToken, "second")).body.session).toMatchObject({ holder: VM, epoch: 2 })
    expect((await machine(a.installToken)).body).toEqual({ team: a.team, machine: M })
    expect((await get(a.installToken, "first")).body.session).toMatchObject({ holder: VM, epoch: 3, state: "resuming" })
    // With none left, the pick is dropped and chats wait as they do for an owner with no machine.
    m.machines.length = 0
    advance(60_001)
    await takenOver(a, "third")
    expect((await get(a.installToken, "third")).body.session).toMatchObject({ holder: "parked", epoch: 2, blocked: "no_machine" })
    expect((await machine(a.installToken)).status).toBe(404)
  })
})

/** A shared team `a` (whose Stack subject is `sub`) is a member of, mirrored from a fake Stack as the webhook does it. */
const sharedTeam = async (a: Person, sub: string): Promise<string> => {
  const w = stackWorld()
  const stackTeam = crypto.randomUUID()
  await useStack(stackTeam, w)
  w.teams.set(stackTeam, "Acme")
  w.members.set(`${stackTeam}:${sub}`, "Ann")
  expect((await deliver("team.created", { id: stackTeam, display_name: "Acme", profile_image_url: null, created_at_millis: Date.now() })).status).toBe(200)
  expect((await deliver("team_membership.created", { team_id: stackTeam, user_id: sub })).status).toBe(200)
  const team = teamIdOf(stackTeam)
  expect(await memberRow(team, a.user)).toMatchObject({ role: "member" })
  return team
}

/** A chat of `team` its laptop left with a turn running. The Auto routes act in the session's own team, so the chat is put in `team` where it is stored. */
const leftIn = async (a: Person, id: string, team: string): Promise<void> => {
  await open(a.installToken, id)
  await lease(a.installToken, id, LAPTOP, 1, { needsRun: true })
  await runIn(chatStub(a.user, id), async (_i, state) => void state.storage.sql.exec(`UPDATE session SET team = ?`, team))
  await lapse(a.user, id)
}

/** The owner's index object opens again on its storage as `reshape` left it: its constructor runs, as at a cold start. */
const reopened = (owner: string, reshape: (sql: SqlStorage) => void): Promise<void> =>
  runIn(indexStub(owner), async (index, state) => {
    reshape(state.storage.sql)
    void new index.constructor(state, env)
  })

/** The rules the correctness review of the store's own pick added (DESIGN.md "Rules added after the correctness review"). */
describe("auto sessions: a pick is its team's, and a pick that is gone", { timeout: 60_000 }, () => {
  beforeAll(fakeClock)

  it("a pick made for a chat of one team is not used for a chat of another, which gets its own team's machine or waits, and keeps its team", async () => {
    const a = await person("teams")
    const work = await sharedTeam(a, "auto-teams")
    const m = await fakeCloud(a.user)
    m.machines.push(listed(a, M, { status: "running" }))
    // A personal chat needs a machine first: the pick is the personal team's.
    await takenOver(a, "home")
    expect(await session(a, "home")).toMatchObject({ holder: VM, epoch: 2, team: a.team })
    // A chat of the shared team does not go to it: its own team has no machine of the owner's, so it waits there.
    await leftIn(a, "work", work)
    expect(await session(a, "work")).toMatchObject({ holder: "parked", epoch: 2, blocked: "no_machine", needsRun: true, team: work })
    // Each team's machines were read as the owner in that team, the shared team's once and for its own chat.
    expect(m.asked.filter((q) => q.team === work).map((q) => q.op)).toEqual(["cloud.machine.list"])
    expect(m.asked.filter((q) => q.team === a.team).map((q) => q.op)).toEqual(["cloud.machine.list"])
    for (const q of m.asked) expect(q.as).toEqual({ kind: "session", user: a.user, team: q.team })
    expect((await machine(a.installToken)).body).toEqual({ team: a.team, machine: M })
    // A machine made in the shared team gets the shared team's chat, and only that one: the personal chat, which
    // its machine has not picked up either, stays where it is.
    m.machines.push(listed(a, M2, { team: work, status: "running" }))
    lookAgain()
    expect(await session(a, "work")).toMatchObject({ holder: VM2, epoch: 3, state: "resuming", blocked: null, team: work })
    expect(await session(a, "home")).toMatchObject({ holder: VM, epoch: 2, team: a.team })
    expect((await starts(a.user)).map((s) => [s.machine, s.team]).sort()).toEqual([[M, a.team], [M2, work]])
    // Each team keeps its own pick for its next chat, and the caller's team is the one `GET machine` answers for.
    await leftIn(a, "work2", work)
    await takenOver(a, "home2")
    expect([await session(a, "work2"), await session(a, "home2")]).toMatchObject([{ holder: VM2, epoch: 2, team: work }, { holder: VM, epoch: 2, team: a.team }])
    expect((await machine(a.installToken)).body).toEqual({ team: a.team, machine: M })
    expect(m.asked.filter((q) => q.op === "cloud.machine.list")).toHaveLength(3)
    for (const q of m.asked) expect(q.as).toEqual({ kind: "session", user: a.user, team: q.team })
    // A machine the owner names is for every chat of theirs, whatever its team, as before.
    expect((await setMachine(a, other("c"))).body).toEqual({ team: a.team, machine: other("c") })
    for (const id of ["home", "home2", "work", "work2"]) expect((await session(a, id)).holder, id).toBe(`vm:${other("c")}`)
  })

  it("a machine the owner names while a pick is on its way to the waiting chats wins for every chat", async () => {
    const a = await person("crossed")
    const m = await fakeCloud(a.user)
    await takenOver(a, "one")
    await takenOver(a, "two")
    expect([await session(a, "one"), await session(a, "two")]).toMatchObject([{ holder: "parked", blocked: "no_machine" }, { holder: "parked", blocked: "no_machine" }])
    m.machines.push(listed(a, M2, { status: "running" }))
    lookAgain()
    // The owner's `PUT machine` lands in the store (`nameMachine`, what the route calls) after the pick is kept and
    // before its word reaches the first chat, so the pick's word for that chat arrives after the named machine's.
    await runIn(indexStub(a.user), async (index) => {
      const chats = index.env.AUTO_SESSION_DO
      let named = false
      const crossed = (id: unknown) => {
        const chat = chats.get(id)
        return {
          machineSet: async (owner: string, to: unknown, picked?: boolean) => {
            if (!named) {
              named = true
              await index.nameMachine(a.user, { team: a.team, machine: M })
            }
            return chat.machineSet(owner, to, picked)
          },
          machineGone: (owner: string, gone: string) => chat.machineGone(owner, gone)
        }
      }
      index.env = { ...index.env, AUTO_SESSION_DO: { idFromName: (name: string) => chats.idFromName(name), get: crossed } }
    })
    // The look that picked answers what is stored when it ends, and every chat is on the machine the owner named.
    expect((await machine(a.installToken)).body).toEqual({ team: a.team, machine: M })
    expect([await session(a, "one"), await session(a, "two")]).toMatchObject([{ holder: VM, state: "resuming", blocked: null }, { holder: VM, state: "resuming", blocked: null }])
    expect([await assigned(a, M), await assigned(a, M2)]).toEqual([["one", "two"], []])
  })

  it("a picked machine that is gone parks the chat it never picked up to wait for a machine, and a machine made later gets it; a named machine that is gone keeps its chat", async () => {
    // The owner's next call finds the pick gone.
    const a = await person("stranded")
    const m = await fakeCloud(a.user)
    m.machines.push(listed(a, M2, { status: "running" }))
    await takenOver(a, "left")
    expect(await session(a, "left")).toMatchObject({ holder: VM2, epoch: 2, state: "resuming" })
    m.machines.length = 0
    m.gone.push(M2)
    advance(60_001)
    expect((await machine(a.installToken)).status).toBe(404)
    expect(await session(a, "left")).toMatchObject({ holder: "parked", epoch: 3, state: "parked", blocked: "no_machine", needsRun: true, team: a.team })
    expect(await assigned(a, M2)).toEqual([])
    // The person makes a machine: the look the waiting chat opened finds it, with nobody calling.
    m.machines.push(listed(a, M))
    advance(15_000)
    await fireAlarm(indexStub(a.user))
    expect(await session(a, "left")).toMatchObject({ holder: VM, epoch: 4, state: "resuming", blocked: null })
    expect(await assigned(a, M)).toEqual(["left"])

    // Nobody calls: the pick's start is told the machine does not exist, and asks for a look at once.
    const b = await person("stranded-start")
    const mb = await fakeCloud(b.user)
    mb.machines.push(listed(b, M2, { status: "running" }))
    await takenOver(b, "left")
    await fireAlarm(indexStub(b.user))
    mb.machines.length = 0
    mb.gone.push(M2)
    advance(60_000)
    const lists = mb.lists
    await fireAlarm(indexStub(b.user))
    expect(mb.lists).toBe(lists + 1)
    expect(await session(b, "left")).toMatchObject({ holder: "parked", epoch: 3, blocked: "no_machine", needsRun: true })
    mb.machines.push(listed(b, M))
    advance(15_000)
    await fireAlarm(indexStub(b.user))
    expect(await session(b, "left")).toMatchObject({ holder: VM, epoch: 4, state: "resuming", blocked: null })
    expect((await starts(b.user)).map((s) => s.machine)).toEqual([M])

    // A machine the owner named is theirs to name again: gone or not, it keeps the chat and its start goes on.
    const c = await person("named-gone")
    const mc = await fakeCloud(c.user)
    await setMachine(c, M2)
    await takenOver(c, "kept")
    mc.gone.push(M2)
    await fireAlarm(indexStub(c.user))
    advance(60_001)
    expect((await machine(c.installToken)).body).toEqual({ team: c.team, machine: M2 })
    expect(await session(c, "kept")).toMatchObject({ holder: VM2, epoch: 2, state: "resuming" })
    expect([mc.lists, (await starts(c.user)).map((s) => [s.machine, s.tries])]).toEqual([0, [[M2, 1]]])
  })

  it("a team with more machines than the store reads is not a team where the owner has none", async () => {
    const a = await person("paged")
    const m = await fakeCloud(a.user)
    m.machines.push(listed(a, M2, { status: "running" }))
    await takenOver(a, "kept")
    // The pick reads as gone, and the list still goes on after the last page the store reads: it cannot tell
    // that the owner has no machine, so the pick stays and its chat stays with it.
    m.machines.length = 0
    m.gone.push(M2)
    m.endless = true
    advance(60_001)
    const lists = m.lists
    expect((await machine(a.installToken)).body).toEqual({ team: a.team, machine: M2 })
    expect(m.lists).toBe(lists + 5)
    expect(await session(a, "kept")).toMatchObject({ holder: VM2, epoch: 2, state: "resuming", blocked: null })
    // Read whole, the list says so for a fact.
    m.endless = false
    advance(60_001)
    expect((await machine(a.installToken)).status).toBe(404)
    expect(await session(a, "kept")).toMatchObject({ holder: "parked", epoch: 3, blocked: "no_machine" })

    // One of the owner's machines among the pages that were read is still a pick.
    const b = await person("paged-own")
    const mb = await fakeCloud(b.user)
    mb.endless = true
    mb.machines.push(listed(b, M))
    expect((await machine(b.installToken)).body).toEqual({ team: b.team, machine: M })
  })

  it("teams the owner has left do not keep the alarm's look from the teams that can have a machine", async () => {
    const a = await person("left-teams")
    const m = await fakeCloud(a.user)
    const leftTeams = ["1", "2", "3"].map((n) => `team_${n.repeat(20)}`)
    for (const [n, team] of leftTeams.entries()) await leftIn(a, `old${n}`, team)
    await takenOver(a, "mine")
    expect([await session(a, "old0"), await session(a, "mine")]).toMatchObject([{ holder: "parked", blocked: "no_machine", team: leftTeams[0] }, { holder: "parked", blocked: "no_machine", team: a.team }])
    expect(m.lists).toBe(1)
    // Three teams wait with older chats. None is one the owner may use, so the look reads the fourth.
    m.machines.push(listed(a, M))
    advance(15_000)
    await fireAlarm(indexStub(a.user))
    expect(await session(a, "mine")).toMatchObject({ holder: VM, epoch: 3, state: "resuming", blocked: null })
    expect(m.lists).toBe(2)
    for (const [n, team] of leftTeams.entries()) expect(await session(a, `old${n}`)).toMatchObject({ holder: "parked", epoch: 2, blocked: "no_machine", team })
    for (const q of m.asked) expect(q.team).toBe(a.team)
  })

  it("a store made before the store picked machines, and one made while a pick was one per owner, open as they are", async () => {
    // The first store: the machine the owner named with no `picked` beside it, and no team on a chat's row.
    const a = await person("old-store")
    const m = await fakeCloud(a.user)
    await setMachine(a)
    await takenOver(a, "old")
    await reopened(a.user, (sql) => {
      sql.exec(`DROP TABLE picks`)
      sql.exec(`DROP TABLE machine`)
      sql.exec(`CREATE TABLE machine (k INTEGER PRIMARY KEY CHECK (k = 1), team TEXT NOT NULL, machine TEXT NOT NULL)`)
      sql.exec(`INSERT INTO machine (k, team, machine) VALUES (1, ?, ?)`, a.team, M)
      sql.exec(`ALTER TABLE sessions DROP COLUMN team`)
    })
    // What the owner named is still named (it is not read again, gone or not), and each chat's row has its team.
    m.gone.push(M)
    advance(60_001)
    expect((await machine(a.installToken)).body).toEqual({ team: a.team, machine: M })
    expect(await runIn(indexStub(a.user), async (_i, state) => state.storage.sql.exec(`SELECT id, team FROM sessions`).toArray())).toEqual([{ id: "old", team: a.team }])
    await takenOver(a, "new")
    expect([await session(a, "old"), await session(a, "new")]).toMatchObject([{ holder: VM, epoch: 2 }, { holder: VM, epoch: 2 }])
    expect(m.lists).toBe(0)

    // The store as it was while a pick was one per owner: the pick in the machine's row, marked `picked`.
    const b = await person("old-pick")
    const mb = await fakeCloud(b.user)
    mb.machines.push(listed(b, M2, { status: "running" }))
    await takenOver(b, "old")
    await reopened(b.user, (sql) => {
      sql.exec(`DROP TABLE picks`)
      sql.exec(`DROP TABLE machine`)
      sql.exec(`CREATE TABLE machine (k INTEGER PRIMARY KEY CHECK (k = 1), team TEXT NOT NULL, machine TEXT NOT NULL, picked INTEGER NOT NULL DEFAULT 0)`)
      sql.exec(`INSERT INTO machine (k, team, machine, picked) VALUES (1, ?, ?, 1)`, b.team, M2)
    })
    // It is its team's pick: answered with no new look, and, unlike a named machine, dropped once it is gone.
    const lists = mb.lists
    expect((await machine(b.installToken)).body).toEqual({ team: b.team, machine: M2 })
    expect(mb.lists).toBe(lists)
    mb.machines.length = 0
    mb.gone.push(M2)
    advance(60_001)
    expect((await machine(b.installToken)).status).toBe(404)
    expect(await session(b, "old")).toMatchObject({ holder: "parked", epoch: 3, blocked: "no_machine" })
  })
})
