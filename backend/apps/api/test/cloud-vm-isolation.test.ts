import { describe, expect, it } from "vitest"
import { bindFile, cloudStub, DAEMON, post, SIZE, signedInWithInstall, vmKey, WG_KEY, worker } from "./cloud-bind-support.ts"

/**
 * Security review of the VM install (2026-10-05): a VM install reaches only the cloud.vm.* ops for
 * its own machine (P1), stops with its machine (P2), works in SSO teams (P2), and its event times and
 * URLs are clamped and stripped (P3).
 */

const b64u = (b: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const read = (token: string, op: string, params: unknown) => post("/v1/read", token, { op, params })

const vmSetup = async (sub: string) => {
  const a = await signedInWithInstall(sub, "mac")
  const created = await post("/v1/ops", a.session, { op: "cloud.machine.create", params: { size: SIZE }, idempotency_key: crypto.randomUUID(), origin: "user" })
  const machine = created.body.value.machine.id as string
  const { json } = await bindFile(cloudStub(a.team), machine)
  const key = await vmKey()
  const bound = await post("/v1/cloud/bind", undefined, { team: a.team, machine, bind_token: json.bind_token, wg_public_key: WG_KEY, daemon: DAEMON, install_public_jwk: key.jwk })
  const install = bound.body.value.install as { id: string; user: string; grant: string }
  const mint = async () => {
    const ch = await post("/v1/auth/challenge", undefined, { user: install.user, install: install.id })
    if (ch.status !== 200) return { status: ch.status, token: "" }
    const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key.pair.privateKey, new TextEncoder().encode(`${ch.body.message_prefix}${ch.body.nonce}`))
    const tok = await post("/v1/auth/token", undefined, { user: install.user, install: install.id, nonce: ch.body.nonce, signature: b64u(sig) })
    return { status: tok.status, token: tok.body.access_token as string }
  }
  return { a, machine, host: bound.body.value.host as string, install, mint, vmToken: (await mint()).token }
}

describe("VM install isolation", { timeout: 60_000 }, () => {
  it("admits the VM install as the host of its bound machine and members as devices", async () => {
    const s = await vmSetup("cloud-bind-4")
    const host = s.host
    const open = async (token: string) => {
      const res = await worker.fetch(`https://api.test/v1/wire/host/${host}`, {
        headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": `cmux.wire.v1, bearer.${token}` }
      })
      expect(res.status).toBe(101)
      const socket = res.webSocket!
      const frame = new Promise<any>((resolve) => socket.addEventListener("message", (e) => resolve(JSON.parse(e.data as string)), { once: true }))
      socket.accept()
      return { socket, first: await frame }
    }

    const vm = await open(s.vmToken)
    expect(vm.first).toMatchObject({ t: "welcome", role: "host" })
    vm.socket.close()

    const member = await open(s.a.session)
    expect(member.first).toMatchObject({ t: "welcome", role: "device" })
    member.socket.close()
  })

  it("a VM token reaches no user, team or wire surface (review P1)", async () => {
    const s = await vmSetup("cloud-bind-5")
    expect((await read(s.vmToken, "cloud.vm.self.get", { machine: s.machine })).status).toBe(200)
    for (const op of ["install.list", "team.directory", "team.members.list"]) expect((await read(s.vmToken, op, {})).status, op).toBe(403)
    expect((await post("/v1/ops", s.vmToken, { op: "install.rename", params: { install: s.install.id, name: "x" }, idempotency_key: crypto.randomUUID(), origin: "cli" })).status).toBe(403)
    // General sockets and an unrelated HostDO remain closed to VM installs.
    // The bound machine's own HostDO exception is covered by the admission
    // test above, so this matrix catches a route refactor that broadens it.
    for (const scope of ["user", "team", "feed", "cloud", "host/host_h0000000000000000009"]) {
      const res = await worker.fetch(`https://api.test/v1/wire/${scope}`, { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": `cmux.wire.v1, bearer.${s.vmToken}` } })
      expect(res.status, scope).toBe(403)
    }
    const pk = await worker.fetch("https://api.test/v1/presence-key", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${s.vmToken}` }, body: "{}" })
    expect(pk.status).toBe(403)
  })

  it("the VM install is SSO-vouched by its team, so it works in an SSO team (review P2)", async () => {
    const s = await vmSetup("cloud-bind-6")
    const list = (await read(s.a.session, "install.list", {})).body.value
    expect(list.installs.find((i: any) => i.id === s.install.id)).toMatchObject({ kind: "vm", sso_team: s.a.team })
  })

  it("deleting the machine revokes its VM install (review P2)", async () => {
    const s = await vmSetup("cloud-bind-1")
    const del = await post("/v1/ops", s.a.session, { op: "cloud.machine.delete", params: { machine: s.machine }, idempotency_key: crypto.randomUUID(), origin: "user" })
    expect(del.body.ok, JSON.stringify(del.body)).toBe(true)
    expect((await s.mint()).status).not.toBe(200)
    const list = (await read(s.a.session, "install.list", {})).body.value
    expect(list.installs.find((i: any) => i.id === s.install.id).revoked_at).not.toBeNull()
  })

  it("event times are clamped to the server clock and URL queries are stripped in any case (review P3)", async () => {
    const s = await vmSetup("cloud-bind-2")
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
    const before = Date.now()
    await post("/v1/ops", s.vmToken, { op: "cloud.vm.event.emit", params: { machine: s.machine, kind: "agent.started", at: before + 10 * 86400_000, data: { title: "See HTTPS://Example.com/a?token=secret" } }, origin: "cli" })
    const ev = await wait((f) => f.t === "ephemeral")
    expect(ev.data.at).toBeLessThanOrEqual(Date.now() + 60_000)
    expect(ev.data.data.title).toBe("See HTTPS://Example.com/a")
    ws.close()
  })
})
