import { describe, expect, it } from "vitest"
import vectors from "../../../catalog/cloud-vectors.json"
import { bindFile, cloudStub, DAEMON, post, SIZE, signedInWithInstall, vmKey, WG_KEY, worker } from "./cloud-bind-support.ts"

/**
 * The VM install made at bind (coordinator + a9, 2026-10-05): the bind request carries the VM's
 * install_public_jwk; the server registers a kind "vm" install for the machine's creator, bound to the
 * team and the machine, with the narrow "vm-self" grant; the VM gets its tokens through the normal
 * challenge. cloud.vm.self.get, cloud.vm.status.report (coalesced, 1 per 10 s applied) and
 * cloud.vm.event.emit (v1 kinds, data <= 4 KB, 10/s burst 50, ephemeral team event).
 */

const b64u = (b: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const read = (token: string, op: string, params: unknown) => post("/v1/read", token, { op, params })
const op = (token: string, name: string, params: unknown) => post("/v1/ops", token, { op: name, params, origin: "cli" })

/** A bound machine of a signed-in creator, and the VM's own token. */
const vmSetup = async (sub: string) => {
  const a = await signedInWithInstall(sub, "mac")
  const created = await post("/v1/ops", a.session, { op: "cloud.machine.create", params: { size: SIZE }, idempotency_key: crypto.randomUUID(), origin: "user" })
  const machine = created.body.value.machine.id as string
  const { json } = await bindFile(cloudStub(a.team), machine)
  const key = await vmKey()
  const bound = await post("/v1/cloud/bind", undefined, { team: a.team, machine, bind_token: json.bind_token, wg_public_key: WG_KEY, daemon: DAEMON, install_public_jwk: key.jwk })
  const install = bound.body.value?.install as { id: string; user: string; grant: string }
  const ch = await post("/v1/auth/challenge", undefined, { user: install.user, install: install.id })
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key.pair.privateKey, new TextEncoder().encode(`${ch.body.message_prefix}${ch.body.nonce}`))
  const tok = await post("/v1/auth/token", undefined, { user: install.user, install: install.id, nonce: ch.body.nonce, signature: b64u(sig) })
  return { a, machine, bound, install, vmToken: tok.body.access_token as string, tokStatus: tok.status }
}

describe("VM install at bind", { timeout: 60_000 }, () => {
  it("bind needs install_public_jwk, and answers the VM install (creator, vm-self grant, bound to team and machine)", async () => {
    const a = await signedInWithInstall("cloud-bind-1", "mac")
    const created = await post("/v1/ops", a.session, { op: "cloud.machine.create", params: { size: SIZE }, idempotency_key: crypto.randomUUID(), origin: "user" })
    const machine = created.body.value.machine.id as string
    const { json } = await bindFile(cloudStub(a.team), machine)
    const without = await post("/v1/cloud/bind", undefined, { team: a.team, machine, bind_token: json.bind_token, wg_public_key: WG_KEY, daemon: DAEMON })
    expect([without.status, without.body.error?.code]).toEqual([400, "validation.invalid"])
    const key = await vmKey()
    const bound = await post("/v1/cloud/bind", undefined, { team: a.team, machine, bind_token: json.bind_token, wg_public_key: WG_KEY, daemon: DAEMON, install_public_jwk: key.jwk })
    expect(bound.body.ok, JSON.stringify(bound.body)).toBe(true)
    expect(bound.body.value.install).toMatchObject({ user: a.user })
    const list = (await read(a.session, "install.list", {})).body.value
    const inst = list.installs.find((i: any) => i.id === bound.body.value.install.id)
    expect(inst).toMatchObject({ kind: "vm", bound_team: a.team, bound_machine: machine })
    expect(list.grants.find((g: any) => g.id === inst.grant).op_classes).toEqual(["vm-self"])
  })

  it("the VM reads only its own machine; it has no team read, no link token, no execute", async () => {
    const s = await vmSetup("cloud-bind-2")
    expect(s.tokStatus).toBe(200)
    const self = await read(s.vmToken, "cloud.vm.self.get", { machine: s.machine })
    expect(self.body, JSON.stringify(self.body)).toMatchObject({ value: { machine: { id: s.machine } } })
    expect((await read(s.vmToken, "cloud.vm.self.get", { machine: "vm_00000000000000000009" })).status).toBe(403)
    expect((await read(s.vmToken, "cloud.machine.list", {})).status).toBe(403)
    expect((await op(s.vmToken, "cloud.machine.link_token", { host: s.bound.body.value.host, services: ["ssh"] })).body.ok).toBe(false)
    // A person's mac install cannot use the VM ops.
    expect((await read(s.a.installToken, "cloud.vm.self.get", { machine: s.machine })).status).toBe(403)
  })

  it("status.report: the first report applies, a second within 10 s is coalesced (latest wins later)", async () => {
    const s = await vmSetup("cloud-bind-3")
    const report = (version: string) => ({ machine: s.machine, state: "running", daemon: { version, capabilities: ["terminal"] }, activity: { active_sessions: 1, last_user_input_at: Date.now() } })
    const first = await op(s.vmToken, "cloud.vm.status.report", report("0.50.0"))
    expect(first.body, JSON.stringify(first.body)).toMatchObject({ ok: true, value: { applied: true } })
    expect((await op(s.vmToken, "cloud.vm.status.report", report("0.50.1"))).body).toMatchObject({ ok: true, value: { applied: false } })
    const self = await read(s.vmToken, "cloud.vm.self.get", { machine: s.machine })
    expect(self.body.value.machine.image.daemon_version).toBe("0.50.0")
  })

  it("event.emit: v1 kinds reach the team's subscribers as an ephemeral event; bad kinds, big data and floods are refused", async () => {
    const s = await vmSetup("cloud-bind-4")
    const res = await worker.fetch("https://api.test/v1/wire/cloud", { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": `cmux.wire.v1, bearer.${s.a.session}` } })
    const ws = res.webSocket!
    const frames: Array<any> = []
    ws.addEventListener("message", (e) => frames.push(JSON.parse(e.data as string)))
    ws.accept()
    ws.send(JSON.stringify({ t: "subscribe" }))
    const wait = async (pred: (f: any) => boolean) => {
      for (let i = 0; i < 200 && !frames.some(pred); i++) await new Promise((r) => setTimeout(r, 10))
      return frames.find(pred)
    }
    await wait((f) => f.t === "snapshot")
    const sent = await op(s.vmToken, "cloud.vm.event.emit", { machine: s.machine, kind: "agent.finished", at: Date.now(), data: { title: "Done: https://example.com/pr/1?token=secret#x", outcome: "success" } })
    expect(sent.body, JSON.stringify(sent.body)).toMatchObject({ ok: true })
    const ev = await wait((f) => f.t === "ephemeral" && f.event === "cloud.machine.event")
    expect(ev).toMatchObject({ stream: `cloud:${s.a.team}`, data: { machine: s.machine, kind: "agent.finished", data: { title: "Done: https://example.com/pr/1", outcome: "success" } } })
    expect((await op(s.vmToken, "cloud.vm.event.emit", { machine: s.machine, kind: "shell.exec", at: Date.now(), data: {} })).body.error?.code).toBe("validation.invalid")
    expect((await op(s.vmToken, "cloud.vm.event.emit", { machine: s.machine, kind: "notification", at: Date.now(), data: { title: "x", body: "y".repeat(5000) } })).body.error?.code).toBe("validation.invalid")
    const codes: Array<string | undefined> = []
    for (let i = 0; i < 60; i++) codes.push((await op(s.vmToken, "cloud.vm.event.emit", { machine: s.machine, kind: "service.port.opened", at: Date.now(), data: { port: 3000, proto: "tcp" } })).body.error?.code)
    expect(codes.filter((c) => c === "cloud.rate_limited").length).toBeGreaterThan(0)
    ws.close()
  })

  it("every VM op and v1 event kind has a shared vector", () => {
    const doc = vectors as unknown as { cases: Array<{ op: string }>; events: Array<{ name: string; data?: { kind?: string } }> }
    for (const name of ["cloud.vm.self.get", "cloud.vm.status.report", "cloud.vm.event.emit"]) expect(doc.cases.some((c) => c.op === name), name).toBe(true)
    const kinds = ["agent.started", "agent.finished", "agent.needs_input", "notification", "browser.lease.changed", "cua.session.started", "cua.session.ended", "service.port.opened", "service.port.closed"]
    for (const k of kinds) expect(doc.events.some((e) => e.data?.kind === k), k).toBe(true)
  })
})
