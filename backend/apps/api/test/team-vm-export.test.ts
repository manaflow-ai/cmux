import { env } from "cloudflare:workers"
import type { Principal } from "@cmux/ownership"
import { afterEach, describe, expect, it, vi } from "vitest"
import { FakeDriver, FreestyleDriver } from "../src/team-vm-driver.ts"
import { api, inDO, mutate, setup, sshLine, worker } from "./team-ssh-support.ts"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * cx-lyvg: a rebuild retires the old team VM with its team files on /srv/team, and the fence
 * (cx-009a) means it never runs again, so nothing can copy the files off over SSH. Owners and
 * admins download them with team_vm.retired.export: the op walks /srv/team through the provider's
 * file API (the VM stays paused and fenced) and answers a single-use download path; the download
 * streams a tar of exactly those files.
 */
const ns = (env as unknown as { TEAM_VM_DO: DurableObjectNamespace }).TEAM_VM_DO
const vmStub = (team: string) => ns.get(ns.idFromName(team)) as any
const files = (team: string, fn: (f: FakeDriver["files"]) => void) => inDO(vmStub(team), async (instance) => fn(new FakeDriver(instance.sqlStore).files))
const fakeState = (team: string, vm: string) =>
  inDO(vmStub(team), async (_i, st) => st.storage.sql.exec<{ state: string }>(`SELECT state FROM fake_vm WHERE id = ?`, vm).toArray()[0]?.state ?? null)
const fenced = (team: string, vm: string) => inDO(vmStub(team), async (_i, st) => st.storage.sql.exec(`SELECT 1 FROM fake_fence WHERE id = ?`, vm).toArray().length === 1)

/** A tar parser for the test: entry name (pax `path` first), type and bytes. */
const untar = (buf: Uint8Array) => {
  const dec = new TextDecoder()
  const str = (b: Uint8Array) => dec.decode(b.subarray(0, b.indexOf(0) < 0 ? b.length : b.indexOf(0)))
  const out: Array<{ name: string; type: string; mode: number; data: Uint8Array }> = []
  let pax: string | null = null
  let o = 0
  while (o + 512 <= buf.length) {
    const h = buf.subarray(o, o + 512)
    if (h.every((b) => b === 0)) break
    let sum = 0
    for (let i = 0; i < 512; i++) sum += i >= 148 && i < 156 ? 32 : h[i]!
    expect(parseInt(str(h.subarray(148, 156)).trim(), 8)).toBe(sum)
    const size = parseInt(str(h.subarray(124, 136)), 8)
    const type = String.fromCharCode(h[156]!)
    const data = buf.subarray(o + 512, o + 512 + size)
    o += 512 + Math.ceil(size / 512) * 512
    if (type === "x") {
      pax = /\d+ path=([^\n]*)\n/.exec(dec.decode(data))?.[1] ?? null
      continue
    }
    out.push({ name: pax ?? str(h.subarray(0, 100)), type, mode: parseInt(str(h.subarray(100, 108)), 8), data: new Uint8Array(data) })
    pax = null
  }
  return out
}

let n = 0
/** A team whose VM a rebuild retired (fenced), with team files written on the old VM first. */
const retired = async (opts: { failPause?: boolean; seed?: (f: FakeDriver["files"], vm: string) => void } = {}) => {
  const t = await setup(`stack-export-${String(++n).padStart(4, "0")}${Date.now() % 1_000_000}`)
  const admin = (p: Principal, op: string, params: unknown) => (t.stub as any).vmAdminOp(t.team, p, { op, params, idempotency_key: crypto.randomUUID() })
  const status = async () => (await api(t.token, "/v1/read", { op: "team_vm.status", params: {} })).value
  const woke = await mutate(t.token, "team_vm.ensure_awake", { reason: "ssh" })
  expect(woke.ok, JSON.stringify(woke)).toBe(true)
  const first = woke.value as { vm: string; epoch: number }
  await files(t.team, (f) => (opts.seed ?? defaultSeed)(f, first.vm))
  expect((await t.op(t.memberP, "team_vm.ssh_cert", { public_key: await sshLine("ed25519"), class: "agent" })).ok).toBe(true)
  const removed = await inDO(t.stub, async (instance) => instance.submitSystem("team.member.remove", { user: t.member }, `remove:${t.member}:${crypto.randomUUID()}`))
  expect(removed.frames.find((f: any) => f.t === "reject")).toBeUndefined()
  await fireAlarm(t.stub)
  await fireAlarm(t.stub)
  if (opts.failPause) await vmStub(t.team).fakeControl({ fail_pause: 1000 })
  expect((await admin(t.ownerP, "team_vm.rebuild", { epoch: first.epoch })).ok).toBe(true)
  const download = (path: string) => worker.fetch(`https://api.test${path}`)
  const audits = () =>
    inDO(t.stub, async (_i, st) =>
      st.storage.sql
        .exec<{ payload: string }>(`SELECT payload FROM own_outbox WHERE kind = 'audit.append' ORDER BY id`)
        .toArray()
        .map((r) => JSON.parse(r.payload) as { op: string; detail: any })
        .filter((a) => a.op === "team_vm.taint_audit" && a.detail?.action === "retired_exported")
    )
  return { ...t, first, admin, status, download, audits }
}

const LONG = `${"deep/".repeat(30)}notes-日本語.md`
const BINARY = Uint8Array.from({ length: 1500 }, (_, i) => (i * 7) % 256)
const defaultSeed = (f: FakeDriver["files"], vm: string) => {
  f.put(vm, "/srv/team/README.md", "team readme\n")
  f.put(vm, "/srv/team/src/app.ts", "export const x = 1\n", { mode: 0o755 })
  f.put(vm, "/srv/team/bin/blob.dat", BINARY)
  f.put(vm, `/srv/team/${LONG}`, "long path\n")
  f.put(vm, "/srv/team/link", "/etc/passwd", { kind: "symlink" })
  f.mkdir(vm, "/srv/team/empty")
  // Outside /srv/team: never exported.
  f.put(vm, "/home/alice/secret.txt", "not team files")
}

describe("team_vm.retired.export (cx-lyvg)", { timeout: 60_000 }, () => {
  it("an owner downloads /srv/team of the fenced retired VM as a tar; the VM stays paused and fenced", async () => {
    const t = await retired()
    expect((await t.status()).retired).toEqual([expect.objectContaining({ vm: t.first.vm, state: "paused" })])
    const starts = (await vmStub(t.team).fakeControl({})).starts
    const r = await t.admin(t.ownerP, "team_vm.retired.export", { vm: t.first.vm })
    expect(r.ok, JSON.stringify(r)).toBe(true)
    expect(r.value).toMatchObject({ vm: t.first.vm, files: 4, bytes: 12 + 19 + 1500 + 10, skipped: ["link"], skipped_count: 1 })
    expect(r.value.path).toMatch(new RegExp(`^/v1/team-vm/export/${t.team}/[0-9a-f]{64}$`))
    const res = await t.download(r.value.path)
    expect(res.status).toBe(200)
    expect(res.headers.get("content-type")).toBe("application/x-tar")
    expect(res.headers.get("content-disposition")).toMatch(/^attachment; filename="cmux-team-files-.+\.tar"$/)
    const body = new Uint8Array(await res.arrayBuffer())
    expect(body.length).toBe(r.value.archive_bytes)
    expect(Number(res.headers.get("content-length") ?? body.length)).toBe(body.length)
    const entries = untar(body)
    const text = (name: string) => new TextDecoder().decode(entries.find((e) => e.name === name)?.data)
    expect(entries.map((e) => e.name).sort()).toEqual(
      ["team/", "team/README.md", "team/bin/", "team/bin/blob.dat", "team/empty/", "team/src/", "team/src/app.ts", ...LONG.split("/").slice(0, -1).map((_, i, a) => `team/${a.slice(0, i + 1).join("/")}/`), `team/${LONG}`].sort()
    )
    expect(text("team/README.md")).toBe("team readme\n")
    expect(entries.find((e) => e.name === "team/src/app.ts")?.mode).toBe(0o755)
    expect([...entries.find((e) => e.name === "team/bin/blob.dat")!.data]).toEqual([...BINARY])
    expect(text(`team/${LONG}`)).toBe("long path\n")
    // Never started, never unfenced: still paused, still with its budget spent.
    expect(await fakeState(t.team, t.first.vm)).toBe("paused")
    expect(await fenced(t.team, t.first.vm)).toBe(true)
    expect((await vmStub(t.team).fakeControl({})).starts).toBe(starts)
    // Audited in the team's chain, with the VM.
    expect(await t.audits()).toEqual([expect.objectContaining({ detail: expect.objectContaining({ action: "retired_exported", by: t.owner, vm: t.first.vm }) })])
    // The ticket is single use.
    const again = await t.download(r.value.path)
    expect(again.status).toBe(404)
    expect(((await again.json()) as any).error.code).toBe("team_vm.export_ticket_invalid")
  })

  it("members, agents and other teams' owners cannot export; refusals are not audited", async () => {
    const t = await retired()
    const agent: Principal = { ...t.ownerP, agent: "agent_x" } as Principal
    for (const p of [t.memberP, agent, { ...t.ownerP, kind: "install", install: "inst_00000000000000000081" } as Principal]) {
      expect((await t.admin(p, "team_vm.retired.export", { vm: t.first.vm })).error?.code).toBe("auth.forbidden")
    }
    expect((await t.admin(t.ownerP, "team_vm.retired.export", { vm: "vm_not_retired" })).error?.code).toBe("selector.not_found")
    expect((await t.admin(t.ownerP, "team_vm.retired.export", {})).error?.code).toBe("validation.invalid")
    expect(await t.audits()).toEqual([])
    // A ticket names its team: the same ticket under another team's path opens nothing.
    const r = await t.admin(t.ownerP, "team_vm.retired.export", { vm: t.first.vm })
    expect(r.ok, JSON.stringify(r)).toBe(true)
    const other = await t.download(r.value.path.replace(t.team, "team_00000000000000000000"))
    expect(other.status).toBe(404)
    const own = await t.download(r.value.path)
    expect(own.status).toBe(200)
    expect((await own.arrayBuffer()).byteLength).toBe(r.value.archive_bytes)
  })

  it("a retired VM that is not fenced yet is refused, and its download too; nothing starts it", async () => {
    const t = await retired({ failPause: true })
    expect((await t.status()).retired).toEqual([expect.objectContaining({ vm: t.first.vm, state: "pausing" })])
    const r = await t.admin(t.ownerP, "team_vm.retired.export", { vm: t.first.vm })
    expect(r.error?.code, JSON.stringify(r)).toBe("team_vm.retired_not_fenced")
    expect(await t.audits()).toEqual([])
    // A ticket minted while fenced is refused at download when the row is no longer a fenced retired VM.
    await vmStub(t.team).fakeControl({ fail_pause: 0 })
    await vmStub(t.team).fakeAlarm(10 * 60_000)
    const ok = await t.admin(t.ownerP, "team_vm.retired.export", { vm: t.first.vm })
    expect(ok.ok, JSON.stringify(ok)).toBe(true)
    expect((await t.admin(t.ownerP, "team_vm.retired.delete", { vm: t.first.vm, files_copied: true })).ok).toBe(true)
    const gone = await t.download(ok.value.path)
    expect(gone.status).toBe(409)
    expect(((await gone.json()) as any).error.code).toBe("selector.not_found")
  })

  it("over the limits (2 GiB of files) or without /srv/team: declared errors, no ticket", async () => {
    const big = await retired({ seed: (f, vm) => (f.put(vm, "/srv/team/a.bin", "x", { stat_size: 2 * 1024 ** 3 }), f.put(vm, "/srv/team/b.bin", "y")) })
    expect((await big.admin(big.ownerP, "team_vm.retired.export", { vm: big.first.vm })).error?.code).toBe("team_vm.export_too_large")
    const none = await retired({ seed: (f, vm) => f.put(vm, "/home/alice/x", "x") })
    expect((await none.admin(none.ownerP, "team_vm.retired.export", { vm: none.first.vm })).error?.code).toBe("team_vm.export_no_files")
    const many = await retired({ seed: (f, vm) => Array.from({ length: 5001 }, (_, i) => f.put(vm, `/srv/team/f${i}`, "")) })
    expect((await many.admin(many.ownerP, "team_vm.retired.export", { vm: many.first.vm })).error?.code).toBe("team_vm.export_too_large")
    expect([...(await big.audits()), ...(await none.audits()), ...(await many.audits())]).toEqual([])
  })

  it("a provider stream that breaks mid-file resumes from the byte it stopped at", async () => {
    const t = await retired({ seed: (f, vm) => f.put(vm, "/srv/team/big.dat", BINARY, { cut_once: 700 }) })
    const r = await t.admin(t.ownerP, "team_vm.retired.export", { vm: t.first.vm })
    expect(r.ok, JSON.stringify(r)).toBe(true)
    const body = new Uint8Array(await (await t.download(r.value.path)).arrayBuffer())
    expect([...untar(body).find((e) => e.name === "team/big.dat")!.data]).toEqual([...BINARY])
  })

  it("an expired ticket opens nothing", async () => {
    const t = await retired()
    const r = await t.admin(t.ownerP, "team_vm.retired.export", { vm: t.first.vm })
    await inDO(vmStub(t.team), async (_i, st) => st.storage.sql.exec(`UPDATE team_vm_export SET expires_at = 1`))
    expect((await t.download(r.value.path)).status).toBe(404)
  })
})

describe("FreestyleDriver files (cx-lyvg)", () => {
  afterEach(() => vi.unstubAllGlobals())
  const provider = (answers: Array<[number, unknown]>) => {
    const calls: Array<{ path: string; range: string | null }> = []
    vi.stubGlobal("fetch", async (url: string, init: RequestInit) => {
      const u = new URL(url)
      calls.push({ path: `${u.pathname}${u.search}`, range: new Headers(init.headers).get("range") })
      const [status, body] = answers.shift() ?? [500, {}]
      return body instanceof Uint8Array ? new Response(body, { status }) : new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } })
    })
    return { calls, files: new FreestyleDriver("test-key", "https://provider.test", "snap").files }
  }

  it("lists, stats and reads through /v5/vms/{id}/fs (a resumed read sends Range)", async () => {
    const p = provider([
      [200, { entries: [{ name: "a.txt", kind: "file" }, { name: "d", kind: "directory" }, { name: "l", kind: "symlink" }] }],
      [200, { size: 3, isFile: true, isDirectory: false, isSymlink: false, permissions: "0640", owner: "cmux", group: "cmux", modified: "2026-10-09T00:00:00Z" }],
      [206, new Uint8Array([2, 3])]
    ])
    expect(await p.files.list("vm-1", "/srv/team")).toEqual([
      { name: "a.txt", kind: "file" },
      { name: "d", kind: "directory" },
      { name: "l", kind: "symlink" }
    ])
    expect(await p.files.stat("vm-1", "/srv/team/a.txt")).toEqual({ kind: "file", size: 3, mode: 0o640, mtime: Date.parse("2026-10-09T00:00:00Z") / 1000, owner: "cmux", group: "cmux" })
    const body = await p.files.read("vm-1", "/srv/team/a.txt", 1, AbortSignal.timeout(5000))
    expect([...new Uint8Array(await new Response(body).arrayBuffer())]).toEqual([2, 3])
    expect(p.calls).toEqual([
      { path: "/v5/vms/vm-1/fs/dir?path=%2Fsrv%2Fteam", range: null },
      { path: "/v5/vms/vm-1/fs/stat?path=%2Fsrv%2Fteam%2Fa.txt", range: null },
      { path: "/v5/vms/vm-1/fs/read?path=%2Fsrv%2Fteam%2Fa.txt", range: "bytes=1-" }
    ])
  })

  it("a 404 is a missing path when the VM exists, and vm_missing when it does not", async () => {
    const path = provider([[404, { code: "NOT_FOUND" }], [200, { id: "vm-1", state: "paused" }]])
    expect(await path.files.list("vm-1", "/srv/team")).toBeNull()
    vi.unstubAllGlobals()
    const vm = provider([[404, { code: "NOT_FOUND" }], [404, { code: "NOT_FOUND" }]])
    await expect(vm.files.stat("vm-1", "/srv/team")).rejects.toMatchObject({ code: "team_vm.vm_missing" })
  })
})
