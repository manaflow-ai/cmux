import { runInDurableObject } from "cloudflare:test"
import { describe, expect, it } from "vitest"
import { decodeBase64, DIR_MAX_BYTES, DIR_MAX_ENTRIES, execCommand, execTimeout, FILE_MAX_BYTES, FS_PROGRAM, fsCommand, OUTPUT_MAX_BYTES, validPath } from "../src/cloud-machine-guest.ts"
import { bindBody, bindFile, cloudStub, createdAndBound, frame, person, post, reply, sessionToken, SIZE, worker } from "./cloud-bind-support.ts"
import { SHARED_TEAM } from "./setup/cloud-teams.ts"
import { DriverError } from "../src/providers/contract.ts"

/** Exec and files on a Cloud machine in classic /api/vm's shapes (cloud-machine-guest.ts, CloudDO.ownerExec). */

type Reply = { ok: boolean; exitCode?: number; stdout?: string; refusal?: string }
type Stub = {
  ownerExec(e: string, user: string, machine: string, command: string, stdin: Uint8Array | null, timeoutMs: number): Promise<Reply>
  fakeControl(cmd: Record<string, unknown>): Promise<any>
}
const stubOf = (team: string) => cloudStub(team) as unknown as Stub
const inDO = runInDurableObject as unknown as <T>(stub: unknown, cb: (instance: any) => Promise<T>) => Promise<T>
const ECHO = "echo cmux-guest-test"

describe("the route's checks", () => {
  it("takes classic's paths, base64 and timeouts", () => {
    for (const p of ["/", "/home/cmux/.cmux/machine-config/status.json", "/a b/c'd", `/${"x".repeat(4095)}`]) expect(validPath(p), p).toBe(true)
    for (const p of ["", "relative", "/a/../b", "/..", "/a\0b", `/${"x".repeat(4096)}`, null, 5]) expect(validPath(p), String(p)).toBe(false)
    expect(decodeBase64("aGk=")).toEqual(new TextEncoder().encode("hi"))
    expect(decodeBase64("")).toEqual(new Uint8Array(0))
    for (const b of ["aGk", "aG k=", "aGk=\n", "aGk-", 5]) expect(decodeBase64(b), String(b)).toBeNull()
    expect(execTimeout(undefined)).toBe(30_000)
    expect(execTimeout(-1)).toBe(30_000)
    expect(execTimeout("5")).toBe(30_000)
    expect(execTimeout(5_000)).toBe(5_000)
    // The provider answers inline for at most 5 minutes: a longer ask is cut there, never a provider refusal.
    expect(execTimeout(99 * 60_000)).toBe(5 * 60_000)
  })

  it("quotes the path as one argument of the file program", () => {
    const cmd = fsCommand("write", "/tmp/it's here", 0o600)
    expect(cmd.startsWith("python3 -c '")).toBe(true)
    expect(cmd.endsWith(` write '/tmp/it'"'"'s here' 384`) || cmd.endsWith(` write '/tmp/it'\\''s here' 384`)).toBe(true)
    expect(FS_PROGRAM).toContain(`M=${FILE_MAX_BYTES}`)
    // A listing stops at its entry count and at its JSON's size (the provider answer's bound, freestyle-exec-errors.test.ts).
    expect(FS_PROGRAM).toContain(`DN,DB=${DIR_MAX_ENTRIES},${DIR_MAX_BYTES}`)
    expect(FS_PROGRAM).toContain("if n>DB:sys.exit(46)")
    // A new file without a mode is the owner's only (classic's 0600), never readable by the work user.
    expect(FS_PROGRAM).toContain("else 0o600)")
    expect(FS_PROGRAM).not.toContain("0o644")
  })
})

describe("CloudDO.ownerExec", { timeout: 60_000 }, () => {
  it("runs on a running machine of the team, audits without the command, and refuses one still binding", async () => {
    const alice = person()
    const created = reply(await alice.stub.submit(alice.team, alice.p, frame("cloud.machine.create", { size: SIZE })))
    const pending = created.value.machine.id as string
    const stub = stubOf(alice.team)
    expect(await stub.ownerExec(alice.team, alice.user, pending, "true", null, 1000)).toEqual({ ok: false, refusal: "not_running" })
    const { machine } = await createdAndBound(alice)
    await stub.fakeControl({ guest_reply: { exitCode: 0, stdout: "hi\n", stderr: "" } })
    expect(await stub.ownerExec(alice.team, alice.user, machine, ECHO, new Uint8Array([104, 105]), 1000)).toEqual({ ok: true, exitCode: 0, stdout: "hi\n", stderr: "" })
    const ctl = await stub.fakeControl({})
    expect(ctl.guest_calls.at(-1)).toEqual({ command: ECHO, stdin: "hi" })
    expect(ctl.audit.at(-1)).toMatchObject({ action: "owner.exec", machine, who: `platform:${alice.user}`, outcome: "exit 0" })
    expect(JSON.stringify(ctl.audit)).not.toContain("cmux-guest-test")
    // A provider that does not answer: provider_failed, never its error.
    await stub.fakeControl({ guest_reply: null })
    expect(await stub.ownerExec(alice.team, alice.user, machine, ECHO, null, 1000)).toEqual({ ok: false, refusal: "provider_failed" })
  })

  it("a teammate may, another team finds nothing, a member who left is refused", async () => {
    const creator = person(SHARED_TEAM)
    const teammate = person(SHARED_TEAM)
    const stub = stubOf(SHARED_TEAM)
    await inDO(stub, async (instance) => {
      instance.creatorIsMember = async () => true
    })
    const { machine } = await createdAndBound(creator)
    await stub.fakeControl({ guest_reply: { exitCode: 0, stdout: "", stderr: "" } })
    expect((await stub.ownerExec(SHARED_TEAM, creator.user, machine, ECHO, null, 1000)).ok).toBe(true)
    expect((await stub.ownerExec(SHARED_TEAM, teammate.user, machine, ECHO, null, 1000)).ok).toBe(true)
    // Another team's caller asks its own team's object: the machine is not there.
    const outsider = person()
    expect(await stubOf(outsider.team).ownerExec(outsider.team, outsider.user, machine, ECHO, null, 1000)).toEqual({ ok: false, refusal: "not_found" })
    await inDO(stub, async (instance) => {
      instance.creatorIsMember = async () => false
    })
    expect(await stub.ownerExec(SHARED_TEAM, teammate.user, machine, ECHO, null, 1000)).toEqual({ ok: false, refusal: "forbidden" })
    expect(await stub.ownerExec(SHARED_TEAM, creator.user, machine, ECHO, null, 1000)).toEqual({ ok: false, refusal: "forbidden" })
    const who = (await stub.fakeControl({})).audit.filter((e: { action: string }) => e.action === "owner.exec").map((e: { who: string }) => e.who)
    expect(who.sort()).toEqual([`platform:${creator.user}`, `platform:${teammate.user}`].sort())
  })

  it("automationExec stays creator-only", async () => {
    const creator = person(SHARED_TEAM)
    const teammate = person(SHARED_TEAM)
    const stub = cloudStub(SHARED_TEAM) as unknown as Stub & { automationExec(e: string, u: string | null, m: string, c: string, s: Uint8Array | null, t: number): Promise<Reply> }
    await inDO(stub, async (instance) => {
      instance.creatorIsMember = async () => true
    })
    const { machine } = await createdAndBound(creator)
    expect(await stub.automationExec(SHARED_TEAM, teammate.user, machine, ECHO, null, 1000)).toEqual({ ok: false, refusal: "forbidden" })
    expect(await stub.automationExec(SHARED_TEAM, null, machine, ECHO, null, 1000)).toEqual({ ok: false, refusal: "forbidden" })
  })
})

/** A signed-in Stack subject with a bound machine on its personal team. */
const signedInWithMachine = async (sub: string) => {
  const t = await sessionToken(sub)
  const ensured = await post("/v1/ops", t, { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "user" })
  const team = ensured.body.value.personal_team as string
  const user = ensured.body.value.id as string
  const created = await post("/v1/ops", t, { op: "cloud.machine.create", params: { size: SIZE }, idempotency_key: crypto.randomUUID(), origin: "user" })
  const machine = created.body.value.machine.id as string
  const file = await bindFile(cloudStub(team), machine)
  const { body } = await bindBody({ user, team }, machine, file.json.bind_token)
  expect((await cloudStub(team).bindMachine(team, body)).ok).toBe(true)
  return { t, team, user, machine }
}

const call = async (method: string, path: string, token: string | undefined, body?: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, { method, headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(body === undefined ? {} : { "content-type": "application/json" }) }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) })
  return { status: res.status, header: res.headers.get("x-cmux-vm-error"), cache: res.headers.get("cache-control"), body: (await res.json()) as any }
}

describe("/v1/cloud/machines/{machine}/exec and /fs/{op}", { timeout: 60_000 }, () => {
  it("answers classic's shapes for the machine's person, as the work user for exec and as root for files", async () => {
    const { t, team, machine } = await signedInWithMachine("cloud-guest-1")
    const stub = stubOf(team)
    const base = `/v1/cloud/machines/${machine}`
    await stub.fakeControl({ guest_reply: { exitCode: 3, stdout: "out", stderr: "err" } })
    const exec = await call("POST", `${base}/exec`, t, { command: ECHO, timeoutMs: 5_000 })
    expect(exec).toMatchObject({ status: 200, cache: "no-store", body: { exitCode: 3, stdout: "out", stderr: "err" } })
    const sent = (await stub.fakeControl({})).guest_calls.at(-1)
    // As the work user, with its output capped on the machine.
    expect(sent.command).toBe(execCommand(ECHO))
    expect(sent.command).toContain("runuser")
    expect(sent.command).toContain(` ${OUTPUT_MAX_BYTES} `)

    const stat = { path: "/home/cmux/a.json", kind: "file", size: 2, mode: 384, modifiedAt: 1_700_000_000_000 }
    await stub.fakeControl({ guest_reply: { exitCode: 0, stdout: JSON.stringify(stat), stderr: "" } })
    // The path is trimmed first, as classic's.
    expect((await call("GET", `${base}/fs/stat?path=${encodeURIComponent(` ${stat.path} `)}`, t)).body).toEqual(stat)
    const statCall = (await stub.fakeControl({})).guest_calls.at(-1)
    expect(statCall.command).toBe(fsCommand("stat", stat.path))
    expect(statCall.command).not.toContain("runuser")

    await stub.fakeControl({ guest_reply: { exitCode: 0, stdout: JSON.stringify({ ok: true, path: "/home/cmux/a.json" }), stderr: "" } })
    expect((await call("POST", `${base}/fs/write`, t, { path: "/home/cmux/a.json", dataBase64: btoa("secret-value"), mode: 0o600 })).body).toEqual({ ok: true, path: "/home/cmux/a.json" })
    const write = (await stub.fakeControl({})).guest_calls.at(-1)
    expect(write).toEqual({ command: fsCommand("write", "/home/cmux/a.json", 0o600), stdin: "secret-value" })
    // The content is stdin only: never in the command, the audit or any answer.
    expect(JSON.stringify((await stub.fakeControl({})).audit)).not.toContain("secret-value")

    // The file program's exit codes are classic's errors.
    await stub.fakeControl({ guest_reply: { exitCode: 44, stdout: "", stderr: "" } })
    expect(await call("GET", `${base}/fs/read?path=/nope`, t)).toMatchObject({ status: 404, header: "vm_file_not_found", body: { ok: false, error: { code: "vm_file_not_found" } } })
    await stub.fakeControl({ guest_reply: { exitCode: 45, stdout: "", stderr: "" } })
    expect((await call("GET", `${base}/fs/dir?path=/etc/hostname`, t)).header).toBe("vm_invalid_path")
    await stub.fakeControl({ guest_reply: { exitCode: 46, stdout: "", stderr: "" } })
    expect((await call("GET", `${base}/fs/read?path=/big`, t)).status).toBe(413)
    // A remove whose path resolves to the root (a symlink to it) is refused by the program.
    await stub.fakeControl({ guest_reply: { exitCode: 47, stdout: "", stderr: "" } })
    expect(await call("DELETE", `${base}/fs/remove?path=/proc/self/root/.`, t)).toMatchObject({ status: 400, header: "vm_invalid_path", body: { error: { code: "vm_invalid_path", message: "the path is the machine's root" } } })
    await stub.fakeControl({ guest_reply: { exitCode: 1, stdout: "", stderr: "Traceback: boom" } })
    expect(await call("DELETE", `${base}/fs/remove?path=/x`, t)).toMatchObject({ status: 502, body: { error: { code: "vm_file_operation_failed", message: "Traceback: boom" } } })
  })

  it("answers an over-limit answer as a final 413, never a retryable 502, and audits it", async () => {
    const { t, team, machine } = await signedInWithMachine("cloud-guest-1")
    const stub = stubOf(team)
    // On this instance only, and put back in finally: the later tests create machines through the real driver.
    await inDO(stub, async (instance) => {
      instance.driverFor = async () => ({
        execStdin: async () => {
          throw new DriverError("cloud.exec.output_limit", "guest exec: output exceeded the response limit", true)
        }
      })
    })
    try {
      const base = `/v1/cloud/machines/${machine}`
      expect(await call("POST", `${base}/exec`, t, { command: ECHO })).toMatchObject({ status: 413, header: "vm_output_too_large", body: { ok: false, error: { code: "vm_output_too_large" } } })
      expect(await call("GET", `${base}/fs/read?path=/home/cmux/big.bin`, t)).toMatchObject({ status: 413, header: "vm_output_too_large" })
      const audit = (await stub.fakeControl({})).audit as Array<{ action: string; machine: string; outcome: string }>
      expect(audit.filter((e) => e.action === "owner.exec" && e.machine === machine).map((e) => e.outcome)).toEqual(["output_limit", "output_limit"])
    } finally {
      await inDO(stub, async (instance) => {
        delete instance.driverFor
      })
    }
  })

  it("refuses no auth, another person's machine, a wrong method and invalid bodies before any guest call", async () => {
    const { t, team, machine } = await signedInWithMachine("cloud-guest-2")
    const other = await signedInWithMachine("cloud-guest-1")
    const stub = stubOf(team)
    await stub.fakeControl({ guest_reply: { exitCode: 0, stdout: "{}", stderr: "" } })
    const before = (await stub.fakeControl({})).guest_calls.length
    const base = `/v1/cloud/machines/${machine}`
    expect((await call("POST", `${base}/exec`, undefined, { command: ECHO })).status).toBe(401)
    // Another team's person: their own team has no such machine.
    expect(await call("POST", `${base}/exec`, other.t, { command: ECHO })).toMatchObject({ status: 404, header: "vm_not_found" })
    expect((await call("GET", `${base}/exec`, t)).status).toBe(405)
    expect((await call("POST", `${base}/fs/read`, t, { path: "/x" })).status).toBe(405)
    expect((await call("POST", `${base}/exec`, t, { command: "  " })).header).toBe("vm_invalid_command")
    expect((await call("POST", `${base}/exec`, t, { command: "x".repeat(64 * 1024 + 1) })).header).toBe("vm_command_too_large")
    expect((await call("POST", `${base}/exec`, t, [ECHO])).header).toBe("vm_invalid_request")
    expect((await call("GET", `${base}/fs/read?path=relative`, t)).header).toBe("vm_invalid_path")
    expect((await call("GET", `${base}/fs/read?path=/a/../etc/shadow`, t)).header).toBe("vm_invalid_path")
    for (const path of ["/", "///", "/.", "/./", "/.//./", " /. "])
      expect((await call("DELETE", `${base}/fs/remove?path=${encodeURIComponent(path)}`, t)).header, path).toBe("vm_invalid_path")
    expect((await call("POST", `${base}/fs/write`, t, { path: "/x", dataBase64: "not base64!" })).header).toBe("vm_invalid_file_body")
    expect((await call("POST", `${base}/fs/write`, t, { path: "/x", dataBase64: "", mode: 0o10000 })).header).toBe("vm_invalid_file_mode")
    expect((await stub.fakeControl({})).guest_calls.length).toBe(before)
    // A machine that is not running answers 409.
    const created = await post("/v1/ops", t, { op: "cloud.machine.create", params: { size: SIZE }, idempotency_key: crypto.randomUUID(), origin: "user" })
    expect((await call("POST", `/v1/cloud/machines/${created.body.value.machine.id}/exec`, t, { command: ECHO })).header).toBe("vm_not_running")
  })
})
