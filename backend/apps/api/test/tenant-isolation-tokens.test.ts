import { SignJWT, importJWK, type JWK } from "jose"
import { env } from "cloudflare:workers"
import { beforeAll, describe, expect, it } from "vitest"
import { bindFile, cloudStub, DAEMON, vmKey, WG_KEY } from "./cloud-bind-support.ts"
import { callOp, callRead, makeTenant, mintInstallToken, post, stackSession, succeeded, worker, type Tenant } from "./setup/tenant.ts"

/**
 * Tenant isolation, credentials (plans/cmux-next/tenant-isolation-DESIGN.md sections 5.2 to 5.5): forged,
 * tampered and replayed tokens, a challenge signed with the wrong key, a revoked install, a team named by a
 * stranger, WebSockets on another tenant's ids, a VM's token against another tenant's machine, a bind token used
 * twice or by the wrong team, and a snapshot of one tenant used by another.
 */
let a: Tenant
let b: Tenant
let machine: string
let snapshot: string
let conversation: string
const SIZE = { cpu: 2, memory_mb: 4096, disk_mb: 16384 }
const b64u = (buf: ArrayBuffer | Uint8Array) => btoa(String.fromCharCode(...new Uint8Array(buf as ArrayBuffer))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const wireOpen = (path: string, token: string, extra: Array<string> = []) =>
  worker.fetch(`https://api.test${path}`, { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": ["cmux.wire.v1", ...extra].join(", "), authorization: `Bearer ${token}` } })

/** A machine of `t`, bound, so it is running: the VM's install and key, to mint VM tokens. */
const bound = async (t: Tenant, name: string) => {
  const created = await callOp(t.session, "cloud.machine.create", { size: SIZE, name: `${t.canary} ${name}` })
  const id = created.body.value.machine.id as string
  const { json } = await bindFile(cloudStub(t.team), id)
  const key = await vmKey()
  const body = { team: t.team, machine: id, bind_token: json.bind_token, wg_public_key: WG_KEY, daemon: DAEMON, install_public_jwk: key.jwk }
  const first = await post("/v1/cloud/bind", undefined, body)
  return { id, bindBody: body, first, key, install: first.body?.value?.install as { id: string; user: string; grant: string } }
}

beforeAll(async () => {
  a = await makeTenant("d")
  b = await makeTenant("e")
  const m = await bound(a, "machine")
  machine = m.id
  const snap = await callOp(a.session, "cloud.snapshot.create", { machine, name: `${a.canary} snap` })
  snapshot = snap.body.value.snapshot.id
  const dm = await callOp(a.session, "dm.open", { peer: { email: `peer-${a.sub}@tenant.test` } })
  conversation = dm.body.value.conversation.id
}, 120_000)

describe("forged and replayed credentials", { timeout: 120_000 }, () => {
  it("rejects a session token with a foreign signature, a wrong audience, a wrong issuer, an expired time and alg none", async () => {
    const stack = (env as unknown as { STACK_PROJECT_ID: string }).STACK_PROJECT_ID
    const rogue = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
    void rogue
    const stackKey = (await importJWK(JSON.parse((env as unknown as { STACK_TEST_PRIVATE_JWK: string }).STACK_TEST_PRIVATE_JWK) as JWK, "ES256")) as CryptoKey
    const claims = { email: a.email, email_verified: true, name: a.name }
    const sign = (key: CryptoKey, over: { iss?: string; aud?: string; exp?: string | number }) =>
      new SignJWT(claims).setProtectedHeader({ alg: "ES256", kid: "stack-test" }).setIssuer(over.iss ?? `https://api.stack-auth.com/api/v1/projects/${stack}`).setAudience(over.aud ?? stack).setSubject(a.sub).setIssuedAt().setExpirationTime(over.exp ?? "10m").sign(key)
    const forged = [
      await sign(rogue.privateKey, {}),
      await sign(rogue.privateKey, { iss: "https://api.stack-auth.com/api/v1/projects/other" }),
      await stackSession(a.sub, a.email, a.name, {}, "-5m"),
      await sign(stackKey, { aud: "someone-else" }),
      await sign(stackKey, { iss: "https://evil.example/api/v1/projects/x" }),
      `${b64u(new TextEncoder().encode(JSON.stringify({ alg: "none", typ: "JWT" })))}.${b64u(new TextEncoder().encode(JSON.stringify({ sub: a.sub, aud: stack })))}.`
    ]
    for (const [i, token] of forged.entries()) {
      const r = await callRead(token, "inbox.list", { limit: 5 })
      expect(r.status, `forged #${i}: ${r.raw.slice(0, 120)}`).toBe(401)
      expect(r.raw).not.toContain(a.canary)
    }
  })

  it("rejects A's token with its payload edited to B's subject or team (signature covers the payload)", async () => {
    for (const token of [a.session, a.installToken]) {
      const [h, p, s] = token.split(".") as [string, string, string]
      const payload = JSON.parse(atob(p.replace(/-/g, "+").replace(/_/g, "/")))
      for (const edit of [{ sub: b.sub }, { sub: b.user }, { team: b.team }, { email: b.email }]) {
        const tampered = `${h}.${b64u(new TextEncoder().encode(JSON.stringify({ ...payload, ...edit })))}.${s}`
        const r = await callRead(tampered, "install.list", {})
        expect(r.status, JSON.stringify(edit)).toBe(401)
      }
    }
  })

  it("an install token is not a session token for another user: B's install cannot act with A's user or install named in the body", async () => {
    // user.ensure / install.list answer for the TOKEN's user, whatever the params say.
    const listed = await callRead(b.installToken, "install.list", { user: a.user, team: a.team })
    expect(listed.raw).not.toContain(a.canary)
    expect(listed.raw).not.toContain(a.install)
    const revoke = await callOp(b.session, "install.revoke", { install: a.install })
    expect(succeeded(revoke) && revoke.body?.value?.revoked_at, revoke.raw).toBeFalsy()
    // A's install still works.
    expect(succeeded(await callRead(a.installToken, "install.list", {}))).toBe(true)
  })

  it("a challenge signed with B's key for A's install, and a replayed nonce, mint nothing", async () => {
    const ch = await post("/v1/auth/challenge", undefined, { user: a.user, install: a.install })
    expect(ch.status).toBe(200)
    const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, b.keyPair.privateKey, new TextEncoder().encode(`${ch.body.message_prefix}${ch.body.nonce}`))
    const wrong = await post("/v1/auth/token", undefined, { user: a.user, install: a.install, nonce: ch.body.nonce, signature: b64u(sig) })
    expect(wrong.status).not.toBe(200)
    expect(wrong.raw).not.toContain("access_token")
    // The right key now, but the nonce was spent by the failed attempt or is used a second time.
    const ch2 = await post("/v1/auth/challenge", undefined, { user: a.user, install: a.install })
    const ok = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, a.keyPair.privateKey, new TextEncoder().encode(`${ch2.body.message_prefix}${ch2.body.nonce}`))
    const body = { user: a.user, install: a.install, nonce: ch2.body.nonce, signature: b64u(ok) }
    expect((await post("/v1/auth/token", undefined, body)).status).toBe(200)
    expect((await post("/v1/auth/token", undefined, body)).status, "a nonce is single use").not.toBe(200)
    // B's challenge for B's own install cannot be redeemed against A's install id.
    const chB = await post("/v1/auth/challenge", undefined, { user: b.user, install: b.install })
    const sigB = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, b.keyPair.privateKey, new TextEncoder().encode(`${chB.body.message_prefix}${chB.body.nonce}`))
    expect((await post("/v1/auth/token", undefined, { user: a.user, install: a.install, nonce: chB.body.nonce, signature: b64u(sigB) })).status).not.toBe(200)
    expect((await post("/v1/auth/challenge", undefined, { user: b.user, install: a.install })).status, "a challenge for a mismatched user/install pair").not.toBe(200)
  })

  it("a revoked install's token stops working at once (not at its 10 minute expiry)", async () => {
    const t = await makeTenant("f")
    expect(succeeded(await callRead(t.installToken, "install.list", {}))).toBe(true)
    const revoked = await callOp(t.session, "install.revoke", { install: t.install })
    expect(succeeded(revoked), revoked.raw).toBe(true)
    const after = await callRead(t.installToken, "install.list", {})
    expect(after.status, after.raw).not.toBe(200)
    expect(await mintInstallToken({ user: t.user, install: t.install, keyPair: t.keyPair }), "a revoked install mints no new token").toBeUndefined()
  })

  it("a stranger cannot name A's team or conversation on a WebSocket", async () => {
    expect([401, 403, 404]).toContain((await wireOpen(`/v1/wire/conv/${conversation}`, b.session)).status)
    for (const scope of ["team", "feed", "cloud"]) {
      const r = await wireOpen(`/v1/wire/${scope}`, b.session, [`team.${a.team}`])
      expect([401, 403], `${scope}: ${r.status}`).toContain(r.status)
    }
    // A itself still connects to its own conversation (the test would pass if the route were simply dead).
    expect((await wireOpen(`/v1/wire/conv/${conversation}`, a.session)).status).toBe(101)
  })
})

describe("cross-VM and snapshot reuse", { timeout: 120_000 }, () => {
  it("a VM token reaches its own machine and no other tenant's machine", async () => {
    const mine = await bound(b, "mine")
    const ch = await post("/v1/auth/challenge", undefined, { user: mine.install.user, install: mine.install.id })
    const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, mine.key.pair.privateKey, new TextEncoder().encode(`${ch.body.message_prefix}${ch.body.nonce}`))
    const tok = await post("/v1/auth/token", undefined, { user: mine.install.user, install: mine.install.id, nonce: ch.body.nonce, signature: b64u(sig) })
    const vm = tok.body.access_token as string
    expect(succeeded(await callRead(vm, "cloud.vm.self.get", { machine: mine.id }))).toBe(true)
    for (const op of ["cloud.vm.self.get"]) {
      const r = await callRead(vm, op, { machine: machine })
      expect(succeeded(r), `${op} on A's machine: ${r.raw}`).toBe(false)
      expect(r.raw).not.toContain(a.canary)
    }
    const emit = await callOp(vm, "cloud.vm.status.report", { machine, state: "idle", daemon: DAEMON, activity: { terminals: 0, agents: 0, last_input_at: 0 } })
    expect(succeeded(emit), emit.raw).toBe(false)
    const evt = await callOp(vm, "cloud.vm.event.emit", { machine, kind: "agent.finished", at: Date.now(), data: {} })
    expect(succeeded(evt), evt.raw).toBe(false)
    // A VM install is not a user: no user surface at all.
    for (const op of ["install.list", "team.members.list", "cloud.machine.list", "cloud.snapshot.list"]) expect((await callRead(vm, op, {})).status, op).toBe(403)
  })

  it("a bind token binds once, only for its own team and machine", async () => {
    const t = await makeTenant("g")
    const created = await callOp(t.session, "cloud.machine.create", { size: SIZE })
    const id = created.body.value.machine.id as string
    const { json } = await bindFile(cloudStub(t.team), id)
    const body = { team: t.team, machine: id, bind_token: json.bind_token, wg_public_key: WG_KEY, daemon: DAEMON, install_public_jwk: (await vmKey()).jwk }
    // B's team presents A's pending bind token: refused, and it does not burn A's token.
    const stolen = await post("/v1/cloud/bind", undefined, { ...body, team: b.team })
    expect(stolen.status, stolen.raw).not.toBe(200)
    // The machine of A's token under another machine id of the same team: refused.
    const other = await post("/v1/cloud/bind", undefined, { ...body, machine: machine })
    expect(other.status, other.raw).not.toBe(200)
    const first = await post("/v1/cloud/bind", undefined, body)
    expect(first.status, first.raw).toBe(200)
    const replay = await post("/v1/cloud/bind", undefined, { ...body, install_public_jwk: (await vmKey()).jwk })
    expect(replay.status, "a bind token is single use; a replay must not install a second VM key").not.toBe(200)
  })

  it("B cannot snapshot, restore, delete, start, connect to or shell into A's machine, nor create from A's snapshot", async () => {
    const calls: Array<[string, unknown]> = [
      ["cloud.snapshot.create", { machine }],
      ["cloud.snapshot.restore", { snapshot }],
      ["cloud.snapshot.delete", { snapshot }],
      ["cloud.machine.create", { size: SIZE, from_snapshot: snapshot }],
      ["cloud.machine.start", { machine }],
      ["cloud.machine.pause", { machine }],
      ["cloud.machine.delete", { machine }],
      ["cloud.machine.rename", { machine, name: "stolen" }],
      ["cloud.machine.upgrade", { machine }],
      ["cloud.shell.open", { machine, cols: 80, rows: 24 }]
    ]
    for (const [op, params] of calls) {
      const mine = await callOp(b.session, op, params)
      const unknown = await callOp(b.session, op, JSON.parse(JSON.stringify(params).replaceAll(machine, "vm_00000000000000000009").replaceAll(snapshot, "snap_00000000000000000009")))
      expect(succeeded(mine), `${op}: ${mine.raw}`).toBe(false)
      expect(mine.code, `${op} must answer like an unknown id`).toBe(unknown.code)
    }
    expect(succeeded(await callRead(b.session, "cloud.machine.get", { machine }))).toBe(false)
    // Nothing of A moved.
    const still = await callRead(a.session, "cloud.machine.get", { machine })
    expect(JSON.stringify(still.body.value), "A machine unchanged").toContain(`${a.canary} machine`)
    expect((await callRead(a.session, "cloud.snapshot.list", {})).body.value.snapshots.map((s: any) => s.id)).toContain(snapshot)
    expect((await callRead(b.session, "cloud.snapshot.list", {})).raw).not.toContain(snapshot)
    expect((await callRead(b.session, "cloud.machine.list", {})).raw).not.toContain(a.canary)
  })
})
