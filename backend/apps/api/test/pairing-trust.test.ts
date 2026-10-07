import { describe, expect, it } from "vitest"
import { op, openHost } from "./host-control-support.ts"
import { account, cert, device, offer, openUser, publish, randomKey, send, subscribeTrust } from "./trust-support.ts"

/**
 * B6 pairing (plans/cmux-next/ios-next/b6-pairing.md): link key certs in `trust:<user>`, QR offers
 * in PairingDO (binding, single use), same-account trust, cross-account request -> accept -> guest
 * admission in TeamDO, decline and revoke.
 */

const trustEvent = (s: Awaited<ReturnType<typeof openUser>>, user: string, opName: string, from = 0) => s.next((f) => f.t === "event" && f.stream === `trust:${user}` && f.op === opName, from)

describe("trust.key.publish", () => {
  it("records a signed direct cert, binds a Mac's host, and rotates", async () => {
    const a = await account("pub")
    const mac = await openUser(a.mac.token)
    const snap0 = await subscribeTrust(mac, a.user)
    expect(snap0.state.devices).toEqual({})
    const first = await publish(mac, a.user, a.mac, a.host)
    expect(first.reply.t).toBe("result")
    expect(first.reply.value).toEqual({ install: a.mac.install, purpose: "direct" })
    const ev = await trustEvent(mac, a.user, "trust.key.set")
    expect(ev.params.host).toBe(a.host)
    const phone = await openUser(a.phone.token)
    expect((await publish(phone, a.user, a.phone)).reply.t).toBe("result")
    const snap = await subscribeTrust(phone, a.user)
    expect(snap.state.devices[a.mac.install].host).toBe(a.host)
    expect(snap.state.devices[a.phone.install].host).toBeUndefined()
    // Rotation: a newer cert replaces the old one; an older one is refused.
    const rotated = await publish(mac, a.user, a.mac, a.host, { issued_at: Date.now() + 1000 })
    expect(rotated.reply.t).toBe("result")
    const old = await publish(mac, a.user, a.mac, a.host, { issued_at: Date.now() - 60_000 })
    expect(old.reply).toMatchObject({ t: "reject", code: "trust.cert_stale" })
    const after = await subscribeTrust(phone, a.user)
    expect(after.state.devices[a.mac.install].certs.direct.key).toBe(rotated.cert.key)
  })

  it("refuses forged, foreign, stale, wrong-environment and over-long certs, and a host the install did not enroll", async () => {
    const a = await account("bad")
    const s = await openUser(a.phone.token)
    const other = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
    const cases: Array<[unknown, string]> = [
      [await cert(a.user, a.phone, { signer: other.privateKey }), "trust.bad_signature"],
      [await cert(a.user, a.phone, { environment: "production" }), "trust.bad_signature"],
      [await cert(a.user, a.mac), "validation.invalid"],
      [await cert(a.user, a.phone, { issued_at: Date.now() - 3_600_000 }), "validation.invalid"],
      [await cert(a.user, a.phone, { lifetime: 91 * 86_400_000 }), "validation.invalid"],
      [await cert(a.user, a.phone, { purpose: "dtls", lifetime: 60_000 }), "validation.invalid"],
      [{ ...(await cert(a.user, a.phone)), key: "short" }, "validation.invalid"]
    ]
    for (const [c, code] of cases) expect((await send(s, "trust.key.publish", { cert: c })).code).toBe(code)
    expect((await send(s, "trust.key.publish", { cert: await cert(a.user, a.phone), host: a.host })).code).toBe("auth.forbidden")
    // A session is not an install; a direct trust.* op is not a pairing op.
    const session = await openUser(a.session)
    expect((await send(session, "trust.key.publish", { cert: await cert(a.user, a.phone) })).code).toBe("auth.forbidden")
    expect((await send(s, "trust.key.set", { cert: await cert(a.user, a.phone) })).code).toBe("auth.forbidden")
  })

  it("drops a revoked install's certs in the same turn", async () => {
    const a = await account("rev")
    const s = await openUser(a.mac.token)
    await publish(s, a.user, a.mac, a.host)
    const phone = await openUser(a.phone.token)
    await publish(phone, a.user, a.phone)
    const at = s.frames.length
    await subscribeTrust(s, a.user)
    expect((await op(a.session, "install.revoke", { install: a.phone.install })).json.ok).toBe(true)
    const ev = await trustEvent(s, a.user, "trust.install.revoked", at)
    expect(ev.params.install).toBe(a.phone.install)
    const snap = await subscribeTrust(s, a.user)
    expect(Object.keys(snap.state.devices)).toEqual([a.mac.install])
  })
})

describe("QR offers", () => {
  it("same account: the claim is trusted at once and the code is single use and bound to the host key", async () => {
    const a = await account("same")
    const mac = await openUser(a.mac.token)
    expect((await send(mac, "pairing.offer", { host: a.host, team: a.team })).code).toBe("pairing.no_host_key")
    const hostCert = (await publish(mac, a.user, a.mac, a.host)).cert
    const o = await offer(mac, a)
    expect(o.reply.t).toBe("result")
    expect(o.key).toBe(hostCert.key)
    expect(o.url!.pathname).toBe("/pair/1")
    expect(o.url!.searchParams.get("h")).toBe(a.host)
    expect(Number(o.url!.searchParams.get("e")) * 1000).toBeLessThanOrEqual(Date.now() + 5 * 60_000)
    const phone = await openUser(a.phone.token)
    expect((await send(phone, "pairing.claim", { offer: o.code, host: a.host, host_key: o.key })).code).toBe("pairing.no_device_key")
    await publish(phone, a.user, a.phone)
    expect((await send(phone, "pairing.claim", { offer: o.code, host: a.host, host_key: randomKey() })).code).toBe("pairing.key_mismatch")
    const claimed = await send(phone, "pairing.claim", { offer: o.code, host: a.host, host_key: o.key })
    expect(claimed.value).toMatchObject({ status: "trusted", host: a.host, host_install: a.mac.install })
    expect(claimed.value.host_cert.key).toBe(hostCert.key)
    // A retry by the same device answers the same; another device is refused.
    expect((await send(phone, "pairing.claim", { offer: o.code, host: a.host, host_key: o.key })).value.status).toBe("trusted")
    const tablet = await device(a.session, a.user, "ios", "ios")
    const ts = await openUser(tablet.token)
    await publish(ts, a.user, tablet)
    expect((await send(ts, "pairing.claim", { offer: o.code, host: a.host, host_key: o.key })).code).toBe("pairing.offer_used")
    expect((await send(ts, "pairing.claim", { offer: "0".repeat(26), host: a.host, host_key: o.key })).code).toBe("pairing.offer_unknown")
  })

  it("only the enrolling Mac offers its host", async () => {
    const a = await account("offerer")
    const phone = await openUser(a.phone.token)
    await publish(phone, a.user, a.phone)
    expect((await send(phone, "pairing.offer", { host: a.host, team: a.team })).code).toBe("auth.forbidden")
  })

  it("another account: pending until the owner accepts, then guest admission, and revoke undoes it", async () => {
    const a = await account("owner")
    const b = await account("guest")
    const mac = await openUser(a.mac.token)
    await publish(mac, a.user, a.mac, a.host)
    await subscribeTrust(mac, a.user)
    const o = await offer(mac, a)
    const phone = await openUser(b.phone.token)
    const phoneCert = (await publish(phone, b.user, b.phone)).cert
    await subscribeTrust(phone, b.user)
    // Before acceptance the guest cannot reach the host's control socket.
    expect((await openHost(a.host, b.phone.token, `?team=${a.team}`)).status).toBe(403)
    const at = mac.frames.length
    const claimed = await send(phone, "pairing.claim", { offer: o.code, host: a.host, host_key: o.key })
    expect(claimed.value).toMatchObject({ status: "pending", host: a.host })
    const req = await trustEvent(mac, a.user, "trust.request.add", at)
    expect(req.params).toMatchObject({ install: b.phone.install, user: b.user, host: a.host })
    expect(JSON.stringify(req.params)).not.toContain(o.code)
    const offerId = claimed.value.offer_id as string
    // The guest's own store has no such request; only the owner accepts.
    expect((await send(phone, "trust.request.accept", { offer_id: offerId })).code).toBe("pairing.offer_unknown")
    const pAt = phone.frames.length
    const accepted = await send(mac, "trust.request.accept", { offer_id: offerId })
    expect(accepted.value).toEqual({ host: a.host, install: b.phone.install })
    const remote = await trustEvent(phone, b.user, "trust.remote.add", pAt)
    expect(remote.params).toMatchObject({ host: a.host, host_install: a.mac.install, install: b.phone.install })
    expect(remote.params.cert.key).toBe(o.key)
    const owner = await subscribeTrust(mac, a.user)
    expect(owner.state.requests).toEqual({})
    expect(owner.state.guests[`${a.host}/${b.phone.install}`].cert.key).toBe(phoneCert.key)
    // Accept is idempotent.
    expect((await send(mac, "trust.request.accept", { offer_id: offerId })).t).toBe("result")
    const guestSocket = await openHost(a.host, b.phone.token, `?team=${a.team}`)
    expect(guestSocket.status).toBe(101)
    expect((await guestSocket.hello()).t).toBe("hello.ok")
    // pairing.hosts lists the remote host for the guest.
    const hosts = await new Promise<any>((resolve) => {
      const at2 = phone.frames.length
      phone.send({ t: "read", id: 9, op: "pairing.hosts", params: {} })
      void phone.next((f) => f.t === "read.result" && f.id === 9, at2).then(resolve)
    })
    expect(hosts.value.hosts).toContainEqual(expect.objectContaining({ host: a.host, owner: a.user, key: o.key }))
    // The guest's account revokes its own access: admission and both stores.
    const revoked = await send(phone, "pairing.revoke", { host: a.host, install: b.phone.install })
    expect(revoked.t).toBe("result")
    expect((await subscribeTrust(mac, a.user)).state.guests).toEqual({})
    expect((await subscribeTrust(phone, b.user)).state.remote).toEqual({})
    expect((await openHost(a.host, b.phone.token, `?team=${a.team}`)).status).toBe(403)
  })

  it("decline spends the offer", async () => {
    const a = await account("dec-owner")
    const b = await account("dec-guest")
    const mac = await openUser(a.mac.token)
    await publish(mac, a.user, a.mac, a.host)
    const o = await offer(mac, a)
    const phone = await openUser(b.phone.token)
    await publish(phone, b.user, b.phone)
    const claimed = await send(phone, "pairing.claim", { offer: o.code, host: a.host, host_key: o.key })
    expect((await send(mac, "trust.request.decline", { offer_id: claimed.value.offer_id })).t).toBe("result")
    expect((await subscribeTrust(mac, a.user)).state.requests).toEqual({})
    expect((await send(phone, "pairing.claim", { offer: o.code, host: a.host, host_key: o.key })).code).toBe("pairing.declined")
    expect((await send(mac, "trust.request.accept", { offer_id: claimed.value.offer_id })).code).toBe("pairing.offer_unknown")
  })

  it("the owner revokes a guest", async () => {
    const a = await account("rv-owner")
    const b = await account("rv-guest")
    const mac = await openUser(a.mac.token)
    await publish(mac, a.user, a.mac, a.host)
    const o = await offer(mac, a)
    const phone = await openUser(b.phone.token)
    await publish(phone, b.user, b.phone)
    const claimed = await send(phone, "pairing.claim", { offer: o.code, host: a.host, host_key: o.key })
    await send(mac, "trust.request.accept", { offer_id: claimed.value.offer_id })
    expect((await openHost(a.host, b.phone.token, `?team=${a.team}`)).status).toBe(101)
    expect((await send(mac, "pairing.revoke", { host: a.host, install: b.phone.install })).t).toBe("result")
    expect((await subscribeTrust(phone, b.user)).state.remote).toEqual({})
    expect((await openHost(a.host, b.phone.token, `?team=${a.team}`)).status).toBe(403)
    expect((await send(mac, "pairing.revoke", { host: a.host, install: b.phone.install })).code).toBe("selector.not_found")
  })

  it("a revoke after re-pairing revokes again (keys carry the pairing), and a client key never blocks system writes", async () => {
    const a = await account("rp-owner")
    const b = await account("rp-guest")
    const mac = await openUser(a.mac.token)
    await publish(mac, a.user, a.mac, a.host)
    const phone = await openUser(b.phone.token)
    // A publish whose key names a system write is namespaced and cannot block the later revocation of this install.
    const c = await cert(b.user, b.phone)
    expect((await send(phone, "trust.key.publish", { cert: c }, `trust-revoked:${b.phone.install}`)).idempotency_key).toBe(`trust-revoked:${b.phone.install}`)
    for (let round = 0; round < 2; round++) {
      const o = await offer(mac, a)
      const claimed = await send(phone, "pairing.claim", { offer: o.code, host: a.host, host_key: o.key })
      expect((await send(mac, "trust.request.accept", { offer_id: claimed.value.offer_id })).t).toBe("result")
      expect((await openHost(a.host, b.phone.token, `?team=${a.team}`)).status).toBe(101)
      expect((await send(mac, "pairing.revoke", { host: a.host, install: b.phone.install })).t).toBe("result")
      expect((await openHost(a.host, b.phone.token, `?team=${a.team}`)).status).toBe(403)
    }
  })

  it("revoking a guest's install in its own account removes it from the owner's host", async () => {
    const a = await account("fan-owner")
    const b = await account("fan-guest")
    const mac = await openUser(a.mac.token)
    await publish(mac, a.user, a.mac, a.host)
    const o = await offer(mac, a)
    const phone = await openUser(b.phone.token)
    await publish(phone, b.user, b.phone)
    const claimed = await send(phone, "pairing.claim", { offer: o.code, host: a.host, host_key: o.key })
    await send(mac, "trust.request.accept", { offer_id: claimed.value.offer_id })
    await subscribeTrust(mac, a.user)
    const at = mac.frames.length
    expect((await op(b.session, "install.revoke", { install: b.phone.install })).json.ok).toBe(true)
    const removed = await trustEvent(mac, a.user, "trust.guest.remove", at)
    expect(removed.params).toEqual({ host: a.host, install: b.phone.install })
    expect((await subscribeTrust(mac, a.user)).state.guests).toEqual({})
  })

  it("revoking the host Mac removes its guests' remote entries", async () => {
    const a = await account("mac-owner")
    const b = await account("mac-guest")
    const mac = await openUser(a.mac.token)
    await publish(mac, a.user, a.mac, a.host)
    const o = await offer(mac, a)
    const phone = await openUser(b.phone.token)
    await publish(phone, b.user, b.phone)
    await subscribeTrust(phone, b.user)
    const claimed = await send(phone, "pairing.claim", { offer: o.code, host: a.host, host_key: o.key })
    await send(mac, "trust.request.accept", { offer_id: claimed.value.offer_id })
    const at = phone.frames.length
    expect((await op(a.session, "install.revoke", { install: a.mac.install })).json.ok).toBe(true)
    const removed = await trustEvent(phone, b.user, "trust.remote.remove", at)
    expect(removed.params).toEqual({ host: a.host, install: b.phone.install })
  })
})
