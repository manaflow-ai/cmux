import { env } from "cloudflare:workers"
import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test"
import { describe, expect, it } from "vitest"
import { bindFile, cloudStub, DAEMON, post, sessionToken, signedInWithInstall, SIZE, vmKey, WG_KEY, worker } from "./cloud-bind-support.ts"

/** Cloud work mode's hand-offs (src/handoffs): owner routes, the machine's reports, the owner's list, the wait. */
const runIn = runInDurableObject as unknown as <T>(stub: unknown, fn: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>
const testEnv = env as unknown as { HANDOFF_DO: DurableObjectNamespace; HANDOFF_INDEX_DO: DurableObjectNamespace }
const call = async (method: string, path: string, headers: Record<string, string> = {}, body?: unknown) => {
  const r = await worker.fetch(`https://api.test${path}`, { method, headers: { "content-type": "application/json", ...headers }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) })
  return { status: r.status, body: (await r.json()) as any }
}
const as = (t: string) => ({ authorization: `Bearer ${t}` })
const handOff = (t: string, body: unknown = { sessionId: "acp_session_1", machine: "vm_aaaaaaaaaaaaaaaaaaaa", size: { vcpus: 4, memoryGb: 16, pick: "4 vCPU · 16 GB", reason: "picked from 3 earlier runs" } }) =>
  call("POST", "/v1/handoffs", as(t), body)
const report = (id: string, cred: Record<string, string>, status: string, summary?: string, turn = 1) => call("POST", `/v1/handoffs/${id}/report`, cred, { turn, status, ...(summary === undefined ? {} : { summary }) })
const begin = (id: string, t: string, after: number) => call("POST", `/v1/handoffs/${id}/turns`, as(t), { after })

describe("hand-offs", { timeout: 60_000 }, () => {
  it("create answers the hand-off (starting, size and pick kept) and its machine token; one hand-off per session: a retry answers the same one, another machine for the session conflicts", async () => {
    const t = await sessionToken("handoff-create")
    const first = await handOff(t)
    expect(first.status).toBe(201)
    expect(first.body.handoff).toMatchObject({ sessionId: "acp_session_1", machine: "vm_aaaaaaaaaaaaaaaaaaaa", turn: 1, state: "open", status: "starting", summary: null, version: 1, startedAt: null, finishedAt: null, size: { vcpus: 4, memoryGb: 16, pick: "4 vCPU · 16 GB", reason: "picked from 3 earlier runs" } })
    expect(first.body.handoff.id).toMatch(/^ho_[0-9a-f]{20}$/)
    expect(first.body.machineToken).toMatch(/^[0-9a-f]{64}$/)
    const again = await handOff(t)
    expect(again.body).toEqual(first.body)
    expect((await handOff(t, { sessionId: "acp_session_1", machine: "vm_bbbbbbbbbbbbbbbbbbbb" })).body.error.code).toBe("handoff.conflict")
    const other = await handOff(t, { sessionId: "other", machine: "vm_aaaaaaaaaaaaaaaaaaaa" })
    expect([other.status, other.body.handoff.id === first.body.handoff.id]).toEqual([201, false])
    expect((await handOff(t, { sessionId: "s", machine: "bad machine!" })).status).toBe(400)
    expect((await handOff(t, { sessionId: "s", machine: "m", size: { vcpus: -1 } })).status).toBe(400)
    // The token is the machine's only: a read never serves it.
    const got = await call("GET", `/v1/handoffs/${first.body.handoff.id}`, as(t))
    expect(JSON.stringify(got.body)).not.toContain(first.body.machineToken)
    expect((await handOff(t, { sessionId: "s", machine: "m" })).body.handoff.size).toEqual({ vcpus: null, memoryGb: null, pick: null, reason: null })
  })

  it("the machine reports running, needs-you, then done with a summary; the owner's list follows; an ended turn refuses more but a retry of its last report passes", async () => {
    const t = await sessionToken("handoff-report")
    const { body } = await handOff(t)
    const id = body.handoff.id as string
    const machine = { "x-cmux-handoff-token": body.machineToken as string }
    expect((await report(id, machine, "running")).body.handoff).toMatchObject({ status: "running", version: 2 })
    // The same status again changes nothing, so no version moves and no wait wakes.
    expect((await report(id, machine, "running")).body.handoff.version).toBe(2)
    expect((await report(id, machine, "needs-you")).body.handoff.status).toBe("needs-you")
    expect((await report(id, machine, "starting")).status).toBe(400)
    const done = await report(id, machine, "done", "Fixed the flaky test and opened a PR.")
    expect(done.body.handoff).toMatchObject({ status: "done", summary: "Fixed the flaky test and opened a PR." })
    expect(done.body.handoff.startedAt).not.toBeNull()
    expect(done.body.handoff.finishedAt).not.toBeNull()
    const late = await report(id, machine, "failed")
    expect([late.status, late.body.error.code, late.body.handoff.status]).toEqual([409, "handoff.turn_finished", "done"])
    const retry = await report(id, machine, "done", "Fixed the flaky test and opened a PR.")
    expect([retry.status, retry.body.handoff.version]).toEqual([200, done.body.handoff.version])
    // Only an exact repeat passes: the final status without its summary is not one.
    expect((await report(id, machine, "done")).body.error.code).toBe("handoff.turn_finished")
    expect((await report(id, machine, "running", undefined, 0)).status).toBe(400)
    const list = await call("GET", "/v1/handoffs", as(t))
    expect(list.body.handoffs[0]).toMatchObject({ id, sessionId: "acp_session_1", turn: 1, state: "open", status: "done", summary: "Fixed the flaky test and opened a PR." })
    expect(list.body.nextCursor).toBeNull()
  })

  it("a stranger, a wrong token, a person's sign-in and no credential get nothing", async () => {
    const t = await sessionToken("handoff-owner")
    const { body } = await handOff(t)
    const id = body.handoff.id as string
    const stranger = await sessionToken("handoff-stranger")
    expect((await call("GET", `/v1/handoffs/${id}`, as(stranger))).status).toBe(404)
    expect((await call("POST", `/v1/handoffs/${id}/cancel`, as(stranger))).status).toBe(404)
    expect((await call("GET", "/v1/handoffs", as(stranger))).body.handoffs).toEqual([])
    expect((await call("GET", `/v1/handoffs/${id}`)).status).toBe(401)
    expect((await report(id, { "x-cmux-handoff-token": "0".repeat(64) }, "done")).status).toBe(404)
    expect((await report(id, as(t), "done")).status).toBe(401)
    expect((await report(id, {}, "done")).status).toBe(401)
    // An unknown id writes nothing.
    const unknown = "ho_00000000000000000000"
    expect((await call("GET", `/v1/handoffs/${unknown}`, as(t))).status).toBe(404)
    const tables = await runIn(testEnv.HANDOFF_DO.get(testEnv.HANDOFF_DO.idFromName(unknown)), async (_i, state) => state.storage.sql.exec(`SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE '\\_cf\\_%' ESCAPE '\\'`).toArray())
    expect(tables).toEqual([])
  })

  it("wait answers at once past its version, and wakes on the next change; cancel ends the turn and the machine learns", async () => {
    const t = await sessionToken("handoff-wait")
    const { body } = await handOff(t)
    const id = body.handoff.id as string
    const machine = { "x-cmux-handoff-token": body.machineToken as string }
    expect((await call("GET", `/v1/handoffs/${id}/wait?after=0&timeoutMs=10000`, as(t))).body.handoff.version).toBe(1)
    const started = Date.now()
    const waiting = call("GET", `/v1/handoffs/${id}/wait?after=1&timeoutMs=20000`, as(t))
    await new Promise((r) => setTimeout(r, 100))
    await report(id, machine, "running")
    expect((await waiting).body.handoff).toMatchObject({ status: "running", version: 2 })
    expect(Date.now() - started).toBeLessThan(10_000)
    expect((await call("GET", `/v1/handoffs/${id}/wait?after=2&timeoutMs=0`, as(t))).body.handoff.version).toBe(2)
    const cancelled = await call("POST", `/v1/handoffs/${id}/cancel`, as(t))
    expect(cancelled.body.handoff).toMatchObject({ status: "cancelled", state: "open", turn: 1 })
    expect((await call("POST", `/v1/handoffs/${id}/cancel`, as(t))).body.handoff.status).toBe("cancelled")
    const told = await report(id, machine, "done", "late")
    expect([told.status, told.body.error.code, told.body.handoff.status, told.body.handoff.summary]).toEqual([409, "handoff.turn_finished", "cancelled", null])
    // An ended turn does not end the wait: it holds until the next change (or its deadline).
    const held = Date.now()
    expect((await call("GET", `/v1/handoffs/${id}/wait?after=${cancelled.body.handoff.version}&timeoutMs=300`, as(t))).body.handoff.status).toBe("cancelled")
    expect(Date.now() - held).toBeGreaterThanOrEqual(250)
  })

  it("the list pages newest first", async () => {
    const t = await sessionToken("handoff-list")
    const ids: Array<string> = []
    for (let i = 0; i < 3; i++) {
      ids.unshift((await handOff(t, { sessionId: `s${i}`, machine: "m" })).body.handoff.id)
      await new Promise((r) => setTimeout(r, 3))
    }
    const one = await call("GET", "/v1/handoffs?limit=2", as(t))
    expect(one.body.handoffs.map((h: any) => h.id)).toEqual(ids.slice(0, 2))
    const two = await call("GET", `/v1/handoffs?limit=2&cursor=${one.body.nextCursor}`, as(t))
    expect(two.body.handoffs.map((h: any) => h.id)).toEqual(ids.slice(2))
    expect(two.body.nextCursor).toBeNull()
  })

  it("a change cut off before its index write still reaches the owner's list: the change armed the retry itself", async () => {
    const t = await sessionToken("handoff-index-retry")
    const { body } = await handOff(t)
    const id = body.handoff.id as string
    const stub = testEnv.HANDOFF_DO.get(testEnv.HANDOFF_DO.idFromName(id))
    // Once indexed, no retry is left armed.
    expect(await runIn(stub, async (_i, state) => state.storage.getAlarm())).toBeNull()
    // The index write never answers (as if the object were reset right after the change committed).
    let release!: (e: Error) => void
    await runIn(stub, async (instance, state) => {
      const real = instance.env
      instance.env = { ...real, HANDOFF_INDEX_DO: { idFromName: () => "x", get: () => ({ put: () => new Promise((_r, reject) => (release = reject)) }) } }
      const report = instance.report({ token: body.machineToken }, 1, "done", "finished while the index was away").catch(() => null)
      await new Promise((r) => setTimeout(r, 50))
      expect(await state.storage.getAlarm()).not.toBeNull()
      instance.env = real
      release(new Error("reset"))
      await report
    })
    expect((await call("GET", "/v1/handoffs", as(t))).body.handoffs[0].status).toBe("starting")
    await runDurableObjectAlarm(stub as never)
    expect((await call("GET", "/v1/handoffs", as(t))).body.handoffs[0]).toMatchObject({ status: "done", summary: "finished while the index was away" })
    expect(await runIn(stub, async (_i, state) => state.storage.getAlarm())).toBeNull()
  })

  it("a follow-up is a new turn of the same hand-off: turn 2 reports needs-you, a late turn-1 report changes nothing, the list and wait show turn 2", async () => {
    const t = await sessionToken("handoff-turns")
    const { body } = await handOff(t)
    const id = body.handoff.id as string
    const machine = { "x-cmux-handoff-token": body.machineToken as string }
    await report(id, machine, "running")
    // A turn still going takes steering, not a new turn.
    expect((await begin(id, t, 1)).body.error.code).toBe("handoff.turn_running")
    const one = await report(id, machine, "done", "turn one")
    // A watcher waiting past turn 1's end wakes when the owner opens turn 2.
    const waiting = call("GET", `/v1/handoffs/${id}/wait?after=${one.body.handoff.version}&timeoutMs=20000`, as(t))
    await new Promise((r) => setTimeout(r, 100))
    const two = await begin(id, t, 1)
    expect(two.body.handoff).toMatchObject({ id, turn: 2, state: "open", status: "starting", summary: null, startedAt: null, finishedAt: null })
    expect((await waiting).body.handoff).toMatchObject({ turn: 2, status: "starting" })
    // A repeat answers the same turn; a caller that saw an older turn is refused.
    expect((await begin(id, t, 1)).body.handoff).toEqual(two.body.handoff)
    expect((await begin(id, t, 0)).body.error.code).toBe("handoff.turn_conflict")
    // The machine never opens a turn, and a late or retried turn-1 report cannot touch turn 2.
    expect((await report(id, machine, "running", undefined, 3)).body.error.code).toBe("handoff.turn_out_of_order")
    const stale = await report(id, machine, "failed", "late turn one", 1)
    expect([stale.status, stale.body.error.code, stale.body.handoff.turn, stale.body.handoff.status]).toEqual([409, "handoff.stale", 2, "starting"])
    expect((await report(id, machine, "running", undefined, 2)).body.handoff).toMatchObject({ turn: 2, status: "running" })
    const asks = await report(id, machine, "needs-you", undefined, 2)
    expect(asks.body.handoff).toMatchObject({ turn: 2, status: "needs-you" })
    expect(asks.body.handoff.version).toBeGreaterThan(two.body.handoff.version)
    expect((await call("GET", "/v1/handoffs", as(t))).body.handoffs.filter((h: any) => h.sessionId === "acp_session_1")).toEqual([
      expect.objectContaining({ id, turn: 2, state: "open", status: "needs-you" })
    ])
    expect((await call("GET", `/v1/handoffs/${id}/wait?after=0&timeoutMs=0`, as(t))).body.handoff).toMatchObject({ turn: 2, status: "needs-you" })
  })

  it("a cancel or close racing a same-turn report: one wins whole, the other sees it, and the turn is never both", async () => {
    const t = await sessionToken("handoff-race")
    for (const end of ["cancel", "close"] as const) {
      const { body } = await handOff(t, { sessionId: `acp_race_${end}`, machine: "vm_aaaaaaaaaaaaaaaaaaaa" })
      const id = body.handoff.id as string
      const machine = { "x-cmux-handoff-token": body.machineToken as string }
      await report(id, machine, "running")
      const [owner, reported] = await Promise.all([call("POST", `/v1/handoffs/${id}/${end}`, as(t)), report(id, machine, "done", "raced")])
      const final = (await call("GET", `/v1/handoffs/${id}`, as(t))).body.handoff
      if (reported.status === 200) {
        // The report landed first: the turn is done with its summary; the owner's call ended nothing more of it.
        expect(final).toMatchObject({ status: "done", summary: "raced" })
        expect(owner.body.handoff.status).toBe("done")
      } else {
        // The owner landed first: the report is refused with what won, and its summary never lands.
        expect(reported.body.error.code).toBe(end === "cancel" ? "handoff.turn_finished" : "handoff.closed")
        expect(final).toMatchObject({ status: "cancelled", summary: null })
      }
      expect(final.state).toBe(end === "close" ? "closed" : "open")
    }
  })

  it("an exact repeat of a turn's final report answers 200 and changes nothing, so a watcher is not woken to notify twice", async () => {
    const t = await sessionToken("handoff-repeat")
    const { body } = await handOff(t)
    const id = body.handoff.id as string
    const machine = { "x-cmux-handoff-token": body.machineToken as string }
    const done = await report(id, machine, "done", "once")
    const waiting = call("GET", `/v1/handoffs/${id}/wait?after=${done.body.handoff.version}&timeoutMs=1500`, as(t))
    await new Promise((r) => setTimeout(r, 100))
    const repeat = await report(id, machine, "done", "once")
    expect(repeat.status).toBe(200)
    expect(repeat.body.handoff).toEqual(done.body.handoff)
    const started = Date.now()
    const woke = await waiting
    // The wait ran to its deadline: no version moved, so the app has nothing new to notify about.
    expect(woke.body.handoff.version).toBe(done.body.handoff.version)
    expect(Date.now() - started).toBeGreaterThanOrEqual(1_000)
    // A final report with no summary clears the one an earlier report left, so its retry is an exact repeat too.
    await begin(id, t, 1)
    await report(id, machine, "needs-you", "which branch?", 2)
    const ended = await report(id, machine, "failed", undefined, 2)
    expect(ended.body.handoff).toMatchObject({ turn: 2, status: "failed", summary: null })
    const again = await report(id, machine, "failed", undefined, 2)
    expect([again.status, again.body.handoff.version]).toEqual([200, ended.body.handoff.version])
  })

  it("close is the one end: it cancels a turn still going, refuses turns (a retried one too) and reports after, and ends a wait at once", async () => {
    const t = await sessionToken("handoff-close")
    const { body } = await handOff(t)
    const id = body.handoff.id as string
    const machine = { "x-cmux-handoff-token": body.machineToken as string }
    await report(id, machine, "done", "turn one")
    await begin(id, t, 1)
    await report(id, machine, "running", undefined, 2)
    const closed = await call("POST", `/v1/handoffs/${id}/close`, as(t))
    expect(closed.body.handoff).toMatchObject({ state: "closed", status: "cancelled", turn: 2 })
    expect(closed.body.handoff.finishedAt).not.toBeNull()
    expect((await call("POST", `/v1/handoffs/${id}/close`, as(t))).body.handoff).toEqual(closed.body.handoff)
    // A retry of the call that opened turn 2 learns the hand-off is closed, not that its turn opened.
    expect((await begin(id, t, 1)).body.error.code).toBe("handoff.closed")
    expect((await begin(id, t, 2)).body.error.code).toBe("handoff.closed")
    const told = await report(id, machine, "done", "after close", 2)
    expect([told.status, told.body.error.code, told.body.handoff.state]).toEqual([409, "handoff.closed", "closed"])
    const started = Date.now()
    expect((await call("GET", `/v1/handoffs/${id}/wait?after=${closed.body.handoff.version}&timeoutMs=20000`, as(t))).body.handoff.state).toBe("closed")
    expect(Date.now() - started).toBeLessThan(5_000)
    expect((await call("GET", "/v1/handoffs", as(t))).body.handoffs[0]).toMatchObject({ id, state: "closed" })
    const stranger = await sessionToken("handoff-close-stranger")
    expect((await call("POST", `/v1/handoffs/${id}/close`, as(stranger))).status).toBe(404)
    expect((await begin(id, stranger, 1)).status).toBe(404)
  })

  it("the VM install bound to the hand-off's machine may report; one bound to another machine may not", async () => {
    const a = await signedInWithInstall("cloud-handoff-1", "mac")
    const created = await post("/v1/ops", a.session, { op: "cloud.machine.create", params: { size: SIZE }, idempotency_key: crypto.randomUUID(), origin: "user" })
    const machine = created.body.value.machine.id as string
    const { json } = await bindFile(cloudStub(a.team), machine)
    const key = await vmKey()
    const bound = await post("/v1/cloud/bind", undefined, { team: a.team, machine, bind_token: json.bind_token, wg_public_key: WG_KEY, daemon: DAEMON, install_public_jwk: key.jwk })
    const install = bound.body.value.install as { id: string; user: string }
    const ch = await post("/v1/auth/challenge", undefined, { user: install.user, install: install.id })
    const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key.pair.privateKey, new TextEncoder().encode(`${ch.body.message_prefix}${ch.body.nonce}`))
    const b64u = (b: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
    const vmToken = (await post("/v1/auth/token", undefined, { user: install.user, install: install.id, nonce: ch.body.nonce, signature: b64u(sig) })).body.access_token as string
    const mine = (await handOff(a.session, { sessionId: "acp_vm", machine })).body.handoff.id as string
    const other = (await handOff(a.session, { sessionId: "acp_other", machine: "vm_bbbbbbbbbbbbbbbbbbbb" })).body.handoff.id as string
    expect((await report(mine, as(vmToken), "running")).body.handoff.status).toBe("running")
    expect((await report(other, as(vmToken), "running")).status).toBe(404)
    // A person's install is not a machine.
    expect((await report(mine, as(a.installToken), "done")).status).toBe(401)
  })
})
