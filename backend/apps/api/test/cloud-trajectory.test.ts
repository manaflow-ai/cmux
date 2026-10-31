import { describe, expect, it } from "vitest"
import { TrajectoryStore } from "../src/cloud-trajectory-store.ts"
import { bindFile, cloudStub, DAEMON, post, SIZE, signedInWithInstall, vmKey, WG_KEY, worker } from "./cloud-bind-support.ts"

/**
 * ACP chat trajectories kept outside the VM (#25584, cloud-trajectory.ts): the machine's VM install
 * appends its acpmux sessions' records and the agents' resume files; the VM (or the creator) reads them
 * back while the machine is paused; a machine restored from the creator's snapshot reads the source's
 * chats (read only) to import them. The log is contiguous, retries are no-ops, a different record is a conflict.
 */

const b64u = (b: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const op = (token: string, name: string, params: unknown) => post("/v1/ops", token, { op: name, params, idempotency_key: crypto.randomUUID(), origin: "user" })
const traj = (token: string, machine: string, action: string, body: unknown) => post(`/v1/cloud/machines/${machine}/trajectories/${action}`, token, body)

/** Binds `machine` (its bind file from the fake provider) and answers its VM install's token. */
const bindVm = async (team: string, machine: string) => {
  const { json } = await bindFile(cloudStub(team), machine)
  const key = await vmKey()
  const bound = await post("/v1/cloud/bind", undefined, { team, machine, bind_token: json.bind_token, wg_public_key: WG_KEY, daemon: DAEMON, install_public_jwk: key.jwk })
  const install = bound.body.value.install as { id: string; user: string }
  const ch = await post("/v1/auth/challenge", undefined, { user: install.user, install: install.id })
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key.pair.privateKey, new TextEncoder().encode(`${ch.body.message_prefix}${ch.body.nonce}`))
  const tok = await post("/v1/auth/token", undefined, { user: install.user, install: install.id, nonce: ch.body.nonce, signature: b64u(sig) })
  return tok.body.access_token as string
}

const setup = async (sub: string) => {
  const a = await signedInWithInstall(sub, "mac")
  const machine = (await op(a.session, "cloud.machine.create", { size: SIZE })).body.value.machine.id as string
  return { a, machine, vm: await bindVm(a.team, machine) }
}

const CREATED = 1_761_000_000_000
const meta = (id: string, lastSeq: number, createdAt = CREATED) => ({ schema: "acpmux.session.v1", id, name: "fix-tests", harness: "claude", cwd: "/home/cmux/work", agentSessionId: "0b7c2f4e-1111-4222-8333-944445555666", status: "ready", createdAt, updatedAt: createdAt, lastSeq })
const line = (seq: number, text = `turn ${seq}`) => JSON.stringify({ seq, at: CREATED + seq, dir: "in", kind: "session/update", msg: { text } })
const lines = (from: number, to: number) => Array.from({ length: to - from + 1 }, (_, i) => line(from + i))

describe("ACP trajectories outside the VM", { timeout: 60_000 }, () => {
  it("the VM appends a chat; a retry is a no-op; a gap and a different record are refused; reads page in order", async () => {
    const s = await setup("traj-1")
    const first = await traj(s.vm, s.machine, "append", { session: "chat-a", generation: CREATED, meta: meta("chat-a", 3), lines: lines(1, 3) })
    expect(first.body, JSON.stringify(first.body)).toEqual({ ok: true, value: { last_seq: 3 } })
    // The same batch again (a retry after a lost answer) changes nothing.
    expect((await traj(s.vm, s.machine, "append", { session: "chat-a", generation: CREATED, lines: lines(1, 3) })).body).toEqual({ ok: true, value: { last_seq: 3 } })
    // Overlap plus new records: only the new ones are added.
    expect((await traj(s.vm, s.machine, "append", { session: "chat-a", generation: CREATED, meta: meta("chat-a", 5), lines: lines(2, 5) })).body).toEqual({ ok: true, value: { last_seq: 5 } })
    const gap = await traj(s.vm, s.machine, "append", { session: "chat-a", generation: CREATED, lines: lines(7, 8) })
    expect([gap.status, gap.body.error]).toEqual([409, { code: "cloud.trajectory.gap", message: expect.any(String), details: { last_seq: 5 } }])
    const conflict = await traj(s.vm, s.machine, "append", { session: "chat-a", generation: CREATED, lines: [line(4, "rewritten")] })
    expect([conflict.status, conflict.body.error.code, conflict.body.error.details]).toEqual([409, "cloud.trajectory.conflict", { seq: 4 }])
    // A new session needs its record first.
    expect((await traj(s.vm, s.machine, "append", { session: "chat-b", generation: CREATED, lines: lines(1, 1) })).status).toBe(404)
    const page = await traj(s.vm, s.machine, "read", { session: "chat-a", after_seq: 1, limit: 2 })
    expect(page.body.value).toEqual({ generation: CREATED, last_seq: 5, lines: [line(2), line(3)], has_more: true })
    const rest = await traj(s.vm, s.machine, "read", { session: "chat-a", after_seq: 3 })
    expect(rest.body.value).toMatchObject({ lines: [line(4), line(5)], has_more: false })
  })

  it("a recreated session (newer createdAt) replaces the old copy; an older one is refused", async () => {
    const s = await setup("traj-2")
    await traj(s.vm, s.machine, "append", { session: "chat-a", generation: CREATED, meta: meta("chat-a", 4), lines: lines(1, 4) })
    const newer = CREATED + 1000
    // A replacement that cannot be kept (no session record, or not from seq 1) leaves the old copy.
    expect((await traj(s.vm, s.machine, "append", { session: "chat-a", generation: newer, lines: lines(1, 1) })).status).toBe(404)
    expect((await traj(s.vm, s.machine, "append", { session: "chat-a", generation: newer, meta: meta("chat-a", 3, newer), lines: lines(3, 3) })).body.error.code).toBe("cloud.trajectory.gap")
    expect((await traj(s.vm, s.machine, "read", { session: "chat-a" })).body.value).toMatchObject({ generation: CREATED, last_seq: 4 })
    expect((await traj(s.vm, s.machine, "append", { session: "chat-a", generation: newer, meta: meta("chat-a", 1, newer), lines: lines(1, 1) })).body).toEqual({ ok: true, value: { last_seq: 1 } })
    const stale = await traj(s.vm, s.machine, "append", { session: "chat-a", generation: CREATED, lines: lines(2, 2) })
    expect([stale.status, stale.body.error.code]).toEqual([409, "cloud.trajectory.stale_generation"])
    expect((await traj(s.vm, s.machine, "read", { session: "chat-a" })).body.value).toMatchObject({ generation: newer, last_seq: 1, lines: [line(1)] })
  })

  it("the agent's resume file is kept as appended ranges and read back byte for byte", async () => {
    const s = await setup("traj-3")
    await traj(s.vm, s.machine, "append", { session: "chat-a", generation: CREATED, meta: meta("chat-a", 1), lines: lines(1, 1) })
    const path = ".claude/projects/-home-cmux-work/0b7c2f4e-1111-4222-8333-944445555666.jsonl"
    const part = (t: string) => btoa(t)
    expect((await traj(s.vm, s.machine, "native", { session: "chat-a", generation: CREATED, label: "claude-project", path, offset: 0, data: part('{"a":1}\n') })).body).toEqual({ ok: true, value: { size: 8 } })
    expect((await traj(s.vm, s.machine, "native", { session: "chat-a", generation: CREATED, label: "claude-project", path, offset: 8, data: part('{"b":2}\n') })).body).toEqual({ ok: true, value: { size: 16 } })
    const off = await traj(s.vm, s.machine, "native", { session: "chat-a", generation: CREATED, label: "claude-project", path, offset: 3, data: part("x") })
    expect([off.status, off.body.error.code, off.body.error.details]).toEqual([409, "cloud.trajectory.offset", { size: 16 }])
    // Only the agent's own files, under their own roots.
    for (const bad of [{ label: "claude-project", path: ".ssh/authorized_keys.jsonl" }, { label: "claude-project", path: ".claude/projects/../../x.jsonl" }, { label: "other", path: ".claude/projects/a/b.jsonl" }]) {
      expect((await traj(s.vm, s.machine, "native", { session: "chat-a", generation: CREATED, ...bad, offset: 0, data: part("x") })).status).toBe(400)
    }
    const list = await traj(s.vm, s.machine, "list", {})
    expect(list.body.value.sessions).toEqual([expect.objectContaining({ session: "chat-a", generation: CREATED, last_seq: 1, meta: meta("chat-a", 1), native: [expect.objectContaining({ label: "claude-project", path, size: 16 })] })])
    const a = await traj(s.vm, s.machine, "native-read", { session: "chat-a", label: "claude-project", path, offset: 0 })
    const b = await traj(s.vm, s.machine, "native-read", { session: "chat-a", label: "claude-project", path, offset: 8 })
    expect([atob(a.body.value.data), atob(b.body.value.data), b.body.value.size]).toEqual(['{"a":1}\n', '{"b":2}\n', 16])
  })

  it("the creator reads a paused machine's chats; nobody else reads, and only the machine writes", async () => {
    const s = await setup("traj-4")
    await traj(s.vm, s.machine, "append", { session: "chat-a", generation: CREATED, meta: meta("chat-a", 2), lines: lines(1, 2) })
    expect((await op(s.a.session, "cloud.machine.pause", { machine: s.machine })).body.ok).toBe(true)
    expect((await traj(s.a.session, s.machine, "read", { session: "chat-a" })).body.value).toMatchObject({ last_seq: 2, lines: lines(1, 2) })
    expect((await traj(s.a.installToken, s.machine, "list", {})).body.value.sessions).toHaveLength(1)
    const write = await traj(s.a.session, s.machine, "append", { session: "chat-a", generation: CREATED, lines: lines(3, 3) })
    expect([write.status, write.body.error.code]).toEqual([403, "auth.forbidden"])
    const other = await signedInWithInstall("traj-4-other", "mac")
    expect((await traj(other.session, s.machine, "list", {})).status).toBe(404)
    // Another machine's VM cannot read or write this one's chats.
    const elsewhere = await setup("traj-4-vm")
    expect((await traj(elsewhere.vm, s.machine, "list", {})).status).toBe(403)
    // A team VM's install is the owner's install with the read class, but a machine install: no access.
    const teamVm = { identity: "install:inst_teamvm77777777777777", user: s.a.user, team: s.a.team, kind: "install", install: "inst_teamvm77777777777777", grant_classes: ["read", "mutate-own"], install_kind: "team-vm" }
    const scope = cloudStub(s.a.team) as unknown as { trajectoryScope(e: string, p: unknown, m: string, w: boolean, parent: boolean): Promise<{ ok: boolean; status?: number }> }
    expect(await scope.trajectoryScope(s.a.team, teamVm, s.machine, false, false)).toMatchObject({ ok: false, status: 403 })
    expect((await worker.fetch(`https://api.test/v1/cloud/machines/${s.machine}/trajectories/list`, { method: "POST", headers: { "content-type": "application/json" }, body: "{}" })).status).toBe(401)
  })

  it("a machine restored from its creator's snapshot reads the source's chats (read only) and keeps its own", async () => {
    const s = await setup("traj-5")
    await traj(s.vm, s.machine, "append", { session: "chat-a", generation: CREATED, meta: meta("chat-a", 3), lines: lines(1, 3) })
    const snap = await op(s.a.session, "cloud.snapshot.create", { machine: s.machine })
    expect(snap.body.ok, JSON.stringify(snap.body)).toBe(true)
    const restored = await op(s.a.session, "cloud.snapshot.restore", { snapshot: snap.body.value.snapshot.id })
    expect(restored.body.ok, JSON.stringify(restored.body)).toBe(true)
    const replacement = restored.body.value.machine.id as string
    expect(replacement).not.toBe(s.machine)
    const vm2 = await bindVm(s.a.team, replacement)
    // Its own store starts empty; the source's is readable with from: parent.
    expect((await traj(vm2, replacement, "list", {})).body.value.sessions).toEqual([])
    expect((await traj(vm2, replacement, "list", { from: "parent" })).body.value.sessions).toEqual([expect.objectContaining({ session: "chat-a", last_seq: 3 })])
    expect((await traj(vm2, replacement, "read", { session: "chat-a", from: "parent" })).body.value).toMatchObject({ last_seq: 3, lines: lines(1, 3) })
    // Read only: the replacement never writes the source's log.
    const parentWrite = await traj(vm2, replacement, "append", { session: "chat-a", generation: CREATED, lines: lines(4, 4), from: "parent" })
    expect([parentWrite.status, parentWrite.body.error.code]).toEqual([403, "auth.forbidden"])
    // The imported chat continues in the replacement's own store; the source keeps its own log untouched.
    expect((await traj(vm2, replacement, "append", { session: "chat-a", generation: CREATED, meta: meta("chat-a", 5), lines: lines(1, 5) })).body).toEqual({ ok: true, value: { last_seq: 5 } })
    expect((await traj(s.vm, s.machine, "append", { session: "chat-a", generation: CREATED, lines: [line(4, "the source went on")] })).body).toEqual({ ok: true, value: { last_seq: 4 } })
    expect((await traj(s.a.session, replacement, "read", { session: "chat-a", after_seq: 3 })).body.value.lines).toEqual(lines(4, 5))
    // A restore of the replacement reads the replacement's chats.
    const snap2 = await op(s.a.session, "cloud.snapshot.create", { machine: replacement })
    const third = (await op(s.a.session, "cloud.snapshot.restore", { snapshot: snap2.body.value.snapshot.id })).body.value.machine.id as string
    const vm3 = await bindVm(s.a.team, third)
    expect((await traj(vm3, third, "read", { session: "chat-a", from: "parent" })).body.value).toMatchObject({ last_seq: 5 })
    // A fresh machine has no source: nothing to read there.
    const fresh = (await op(s.a.session, "cloud.machine.create", { size: SIZE })).body.value.machine.id as string
    const vm4 = await bindVm(s.a.team, fresh)
    expect((await traj(vm4, fresh, "list", { from: "parent" })).body.value.sessions).toEqual([])
    expect((await traj(vm4, fresh, "read", { session: "chat-a", from: "parent" })).status).toBe(404)
    // A person reads only the machine itself; the source link stays private.
    expect((await traj(s.a.session, replacement, "list", { from: "parent" })).status).toBe(403)
    expect(JSON.stringify((await post("/v1/read", s.a.session, { op: "cloud.machine.get", params: { machine: replacement } })).body)).not.toContain("trajectory_parent")
  })


  it("lists every one of 501 kept chats through an explicit cursor", async () => {
    const source = await setup("traj-paged-501")
    // Each append is one session, as on a VM; batch requests to avoid a 501-request serial test.
    for (let start = 0; start < 501; start += 25) {
      const answers = await Promise.all(Array.from({ length: Math.min(25, 501 - start) }, (_, n) => {
        const session = `chat-${String(start + n).padStart(3, "0")}`
        return traj(source.vm, source.machine, "append", {
          session, generation: CREATED, meta: meta(session, 1), lines: [line(1)],
        })
      }))
      for (const answer of answers) expect(answer.body.ok, JSON.stringify(answer.body)).toBe(true)
    }
    const oldClient = await traj(source.vm, source.machine, "list", {})
    expect([oldClient.status, oldClient.body.error.code]).toEqual([409, "cloud.trajectory.pagination_required"])
    const first = await traj(source.vm, source.machine, "list", { page_protocol: 2 })
    expect(first.body.value.sessions).toHaveLength(500)
    expect(first.body.value.sessions[0].session).toBe("chat-000")
    expect(first.body.value.sessions[499].session).toBe("chat-499")
    expect(first.body.value).toMatchObject({ has_more: true, next_after_session: "chat-499" })
    const next = await traj(source.vm, source.machine, "list", { page_protocol: 2, after_session: first.body.value.next_after_session })
    expect(next.body.value).toMatchObject({ has_more: false, next_after_session: null })
    expect(next.body.value.sessions.map((s: { session: string }) => s.session)).toEqual(["chat-500"])
    expect((await traj(source.vm, source.machine, "list", { after_session: 1234 })).status).toBe(400)
  })

  it("a list page stops at its byte budget and the cursor reads the rest", async () => {
    const s = await setup("traj-paged-bytes")
    // Five session records near RECORD_MAX_BYTES: over LIST_MAX_BYTES together, so a page holds four.
    const pad = "x".repeat(1000 * 1000)
    for (let i = 0; i < 5; i++) {
      const session = `chat-${i}`
      const answer = await traj(s.vm, s.machine, "append", { session, generation: CREATED, meta: { ...meta(session, 1), pad }, lines: [line(1)] })
      expect(answer.body.ok, JSON.stringify(answer.body).slice(0, 300)).toBe(true)
    }
    const first = await traj(s.vm, s.machine, "list", { page_protocol: 2 })
    expect(first.body.value.sessions.map((r: { session: string }) => r.session)).toEqual(["chat-0", "chat-1", "chat-2", "chat-3"])
    expect(first.body.value).toMatchObject({ has_more: true, next_after_session: "chat-3" })
    const rest = await traj(s.vm, s.machine, "list", { page_protocol: 2, after_session: "chat-3" })
    expect(rest.body.value.sessions.map((r: { session: string }) => r.session)).toEqual(["chat-4"])
    expect(rest.body.value.has_more).toBe(false)
    // A guest that cannot follow a cursor is refused rather than shown four of five.
    expect((await traj(s.vm, s.machine, "list", {})).body.error.code).toBe("cloud.trajectory.pagination_required")
  })

  it("listing consumes only a byte-bounded page and one lookahead row", () => {
    let consumed = 0
    const record = JSON.stringify({ ...meta("chat-a", 1), pad: "x".repeat(1_000_000) })
    // A streaming SQL cursor can contain hundreds of large records. Reading beyond the
    // page plus lookahead models exhausting the Worker's memory before producing a reply.
    function* rows() {
      for (let i = 0; i < 501; i++) {
        if (++consumed > 5) throw new Error("list read beyond its bounded page")
        yield { session: `chat-${i}`, generation: CREATED, meta: record, last_seq: 1, bytes: record.length, updated_at: CREATED }
      }
    }
    const sql = {
      exec(query: string) {
        if (query.startsWith("SELECT * FROM traj_session")) return { [Symbol.iterator]: rows, toArray: () => Array.from(rows()) }
        return { toArray: () => [] }
      }
    } as unknown as SqlStorage
    const page = new TrajectoryStore(sql).list()
    expect(page.sessions.map((s) => s.session)).toEqual(["chat-0", "chat-1", "chat-2", "chat-3"])
    expect(page).toMatchObject({ has_more: true, next_after_session: "chat-3" })
    expect(consumed).toBe(5)
  })

  it("native reads identify the session generation that owns their bytes", async () => {
    const s = await setup("traj-3")
    const path = ".claude/projects/-work/resume.jsonl"
    for (const generation of [CREATED, CREATED + 1]) {
      await traj(s.vm, s.machine, "append", { session: "chat-a", generation, meta: meta("chat-a", 1, generation), lines: [line(1)] })
      await traj(s.vm, s.machine, "native", { session: "chat-a", generation, label: "claude-project", path, offset: 0, data: btoa("{}\n") })
      const read = await traj(s.vm, s.machine, "native-read", { session: "chat-a", label: "claude-project", path, offset: 0 })
      expect(read.body.value).toMatchObject({ generation, size: 3, data: btoa("{}\n") })
    }
  })

  it("a native rewrite changes its revision while appended ranges keep it", async () => {
    const s = await setup("traj-3")
    const path = ".claude/projects/-work/resume.jsonl"
    await traj(s.vm, s.machine, "append", { session: "chat-a", generation: CREATED, meta: meta("chat-a", 1), lines: [line(1)] })
    const write = (offset: number, text: string) => traj(s.vm, s.machine, "native", { session: "chat-a", generation: CREATED, label: "claude-project", path, offset, data: btoa(text) })
    const read = () => traj(s.vm, s.machine, "native-read", { session: "chat-a", label: "claude-project", path, offset: 0 })
    await write(0, "{}\n")
    const first = (await read()).body.value.revision
    expect(first).toEqual(expect.any(String))
    await write(3, "{}\n")
    expect((await read()).body.value.revision).toBe(first)
    await write(0, "[]\n[]\n")
    const rewritten = (await read()).body.value
    expect(rewritten).toMatchObject({ generation: CREATED, size: 6, data: btoa("[]\n[]\n"), revision: expect.any(String) })
    expect(rewritten.revision).not.toBe(first)
    const listed = (await traj(s.vm, s.machine, "list", {})).body.value.sessions[0].native[0]
    expect(listed.revision).toBe(rewritten.revision)
  })

  it("a record must name its own session and generation", async () => {
    const s = await setup("traj-6")
    const wrong = await traj(s.vm, s.machine, "append", { session: "chat-a", generation: CREATED + 1, meta: meta("chat-a", 1), lines: lines(1, 1) })
    expect([wrong.status, wrong.body.error.code]).toEqual([400, "validation.invalid"])
  })
})
