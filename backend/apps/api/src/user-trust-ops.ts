import type { OpFrame, OwnerFrame, Principal } from "@cmux/ownership"
import { verifyInstallSignature } from "./auth.ts"
import { freshAt, linkCertMessage, parseLinkCert, STORED_PURPOSES, type LinkCert } from "./domains/link-cert.ts"
import { pairKey, type TrustPeerDevice, type TrustState } from "./domains/user-trust.ts"
import type { UserState } from "./domains/user.ts"
import type { Env } from "./env.ts"
import { OFFER_CODE, offerCode, offerId, offerLink, type ClaimOutcome, type OfferHost } from "./pairing-offer.ts"
import type { SecondaryStream } from "./secondary-stream.ts"
import type { SubmitResult } from "./owner-do.ts"

/**
 * UserDO's pairing handlers (plans/cmux-next/ios-next/b6-pairing.md sections 2 to 5). Socket ops on
 * `/v1/wire/user` that need async work before a commit (a WebCrypto signature check, TeamDO and
 * PairingDO calls, the other account's UserDO) run here; every trust write is then a system op on
 * the `trust:<user>` stream (domains/user-trust.ts). Multi-owner steps are keyed by the offer id or
 * `revoke:<host>:<install>`, so a retry finishes a partial step and never applies twice.
 */

/** Ops these handlers own on the socket (others on `trust.*` are refused by the stream's authorize). */
export const TRUST_SOCKET_OPS: ReadonlySet<string> = new Set(["trust.key.publish", "pairing.offer", "pairing.claim", "trust.request.accept", "trust.request.decline", "pairing.revoke"])
/** Trust ops another UserDO may commit here over DO RPC (the other side of a cross-account pairing). */
const CROSS_USER_OPS: ReadonlySet<string> = new Set(["trust.request.add", "trust.guest.remove", "trust.remote.add", "trust.remote.remove"])

export interface TrustOpsHost {
  readonly env: Env
  /** The bound user id and state, or undefined before user.ensure. */
  user(): { entity: string; state: UserState } | undefined
  readonly trust: SecondaryStream<TrustState>
  scheduleAlarm(): void
}

type Outcome = { ok: true; value: unknown } | { ok: false; code: string; message: string; retryable?: boolean }

const fail = (code: string, message: string, retryable = false): Outcome => ({ ok: false, code, message, retryable })
const isObj = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v)
const ID = /^[A-Za-z0-9_]{3,80}$/
const KEY = /^[A-Za-z0-9_-]{43}$/

/** Commits one system op on this user's trust stream; returns the frames for the caller. */
export const submitTrust = (host: TrustOpsHost, entity: string, op: string, params: unknown, key: string, identity = "system:user"): ReadonlyArray<OwnerFrame> => {
  host.trust.open(entity)
  const frames: Array<OwnerFrame> = []
  const principal: Principal = { identity, kind: "system" }
  host.trust.submit(principal, { t: "op", op, params, idempotency_key: key, origin: "script" } as OpFrame, (f) => frames.push(f))
  host.scheduleAlarm()
  return frames
}

const outcomeOf = (frames: ReadonlyArray<OwnerFrame>): Outcome => {
  const r = frames.find((f) => f.t === "result" || f.t === "reject")
  if (r?.t === "result") return { ok: true, value: r.value }
  return r?.t === "reject" ? fail(r.code, r.message) : fail("owner.unreachable", "no reply", true)
}

/** RPC entry for another UserDO: one cross-account trust write, keyed by the caller. */
export const crossUserTrust = (host: TrustOpsHost, entity: string, op: string, params: unknown, key: string, from: string): SubmitResult => {
  const bound = host.user()
  if (!bound || bound.entity !== entity || !CROSS_USER_OPS.has(op) || !ID.test(from)) {
    return { frames: [{ t: "reject", tx: "", idempotency_key: key, code: "auth.forbidden", message: "not a cross-account trust op", retryable: false, replayed: false } as OwnerFrame] }
  }
  return { frames: submitTrust(host, entity, op, params, key, `system:user:${from}`) }
}

const userStub = (env: Env, user: string) =>
  env.USER_DO.get(env.USER_DO.idFromName(user)) as unknown as { crossUserTrust(entity: string, op: string, params: unknown, key: string, from: string): Promise<SubmitResult> }
const teamStub = (env: Env, team: string) =>
  env.TEAM_DO.get(env.TEAM_DO.idFromName(team)) as unknown as {
    hostAccess(entity: string, host: string, principal: Principal): Promise<{ role: "host" | "device"; host: { id: string; name: string; owner_user: string; enrolled_by: string } } | null>
    hostGuest(entity: string, op: string, params: unknown, key: string): Promise<SubmitResult>
  }
const offerStub = (env: Env, id: string) =>
  env.PAIRING_DO.get(env.PAIRING_DO.idFromName(`offer:${id}`)) as unknown as {
    offerCreate(host: OfferHost, now: number): Promise<{ ok: boolean; expires_at?: number }>
    offerClaim(claim: { host: string; host_key: string; claimant: TrustPeerDevice }, now: number): Promise<ClaimOutcome>
    offerComplete(owner: string, install: string, now: number): Promise<ClaimOutcome>
    offerDecline(owner: string, now: number): Promise<boolean>
  }

/** A live install of this user, never a chief token or a VM. */
const deviceOf = (state: UserState, p: Principal) => {
  const inst = p.kind === "install" && !p.agent && p.install ? state.installs[p.install] : undefined
  return inst && inst.revoked_at === null && inst.kind !== "vm" && inst.grant === p.grant ? inst : undefined
}

/** This device as the other account sees it: its install key and published direct cert. */
const peerOf = (host: TrustOpsHost, entity: string, state: UserState, p: Principal): TrustPeerDevice | undefined => {
  const inst = deviceOf(state, p)
  const cert = inst ? host.trust.open(entity).currentState.devices[inst.id]?.certs.direct : undefined
  if (!inst || !cert || cert.expires_at <= Date.now()) return undefined
  return { install: inst.id, user: entity, user_name: state.user?.display_name ?? "cmux user", name: inst.name, platform: inst.platform, public_jwk: inst.public_jwk as TrustPeerDevice["public_jwk"], cert }
}

export class TrustOps {
  constructor(readonly host: TrustOpsHost) {}

  /** Handles one socket op from `TRUST_SOCKET_OPS`; replies on the socket. */
  async handle(ws: WebSocket, principal: Principal, frame: Record<string, unknown>): Promise<void> {
    const key = typeof frame.idempotency_key === "string" ? frame.idempotency_key : ""
    const op = String(frame.op)
    const reply = (frames: ReadonlyArray<unknown>) => {
      for (const f of frames) {
        try {
          ws.send(JSON.stringify(f))
        } catch {}
      }
    }
    const bound = this.host.user()
    if (!key || !bound || principal.user !== bound.entity) return reply(this.frames(key, op, fail("auth.forbidden", "not this user's trust store")))
    const params = isObj(frame.params) ? frame.params : {}
    if (op === "trust.key.publish") return reply(await this.publish(bound.entity, principal, params, key))
    let out: Outcome
    try {
      out = await this.run(op, bound.entity, principal, params)
    } catch (e) {
      out = fail("owner.unreachable", String(e).slice(0, 200), true)
    }
    reply(this.frames(key, op, out))
  }

  private frames(key: string, op: string, out: Outcome): ReadonlyArray<unknown> {
    const stream = `trust:${this.host.user()?.entity ?? ""}`
    const first = out.ok
      ? { t: "result", tx: "", idempotency_key: key, value: out.value, revision: "0", replayed: false }
      : { t: "reject", tx: "", idempotency_key: key, code: out.code, message: out.message, retryable: out.retryable ?? false, replayed: false }
    return [first, { t: "request-settled", tx: "", idempotency_key: key, stream, sequence: 0, ok: out.ok, op }]
  }

  private run(op: string, entity: string, p: Principal, params: Record<string, unknown>): Promise<Outcome> {
    switch (op) {
      case "pairing.offer":
        return this.offer(entity, p, params)
      case "pairing.claim":
        return this.claim(entity, p, params)
      case "trust.request.accept":
        return this.accept(entity, p, params)
      case "trust.request.decline":
        return this.decline(entity, p, params)
      default:
        return this.revoke(entity, p, params)
    }
  }

  /** `trust.key.publish {cert, host?}`: verify the install key's signature, then commit `trust.key.set`. */
  private async publish(entity: string, p: Principal, params: Record<string, unknown>, key: string): Promise<ReadonlyArray<unknown>> {
    const refuse = (code: string, message: string) => this.frames(key, "trust.key.publish", fail(code, message))
    const state = this.host.user()!.state
    const inst = deviceOf(state, p)
    if (!inst) return refuse("auth.forbidden", "only an active install publishes its link keys")
    const cert = parseLinkCert(params.cert)
    if (typeof cert === "string") return refuse("validation.invalid", cert)
    if (!STORED_PURPOSES.has(cert.purpose)) return refuse("validation.invalid", "publish direct or wg certs; dtls proofs travel in signals")
    if (cert.user !== entity || cert.install !== inst.id) return refuse("validation.invalid", "a cert names this user and the calling install")
    const stale = freshAt(cert, Date.now())
    if (stale) return refuse("validation.invalid", stale)
    if (!(await verifyInstallSignature(inst.public_jwk, linkCertMessage(this.host.env.ENVIRONMENT, cert), cert.signature))) return refuse("trust.bad_signature", "the install key did not sign this cert")
    let host: string | undefined
    if (params.host !== undefined) {
      if (typeof params.host !== "string" || !ID.test(params.host) || !p.team) return refuse("validation.invalid", "host must be a host id")
      const access = await teamStub(this.host.env, p.team).hostAccess(p.team, params.host, p)
      if (access?.role !== "host") return refuse("auth.forbidden", "this install did not enroll that host")
      host = params.host
    }
    // Re-read after the awaits: a revoke may have committed meanwhile.
    const now = this.host.user()?.state
    if (!now || !deviceOf(now, p)) return refuse("auth.forbidden", "install revoked")
    const frames = submitTrust(this.host, entity, "trust.key.set", { cert, kind: inst.kind, name: inst.name, platform: inst.platform, public_jwk: inst.public_jwk, ...(host ? { host } : {}) }, key)
    return frames.length ? frames : this.frames(key, "trust.key.publish", fail("owner.unreachable", "no reply", true))
  }

  /** `pairing.offer {host, team}` from the Mac that enrolled the host. */
  private async offer(entity: string, p: Principal, params: Record<string, unknown>): Promise<Outcome> {
    const state = this.host.user()!.state
    const inst = deviceOf(state, p)
    const host = params.host
    const team = params.team ?? p.team
    if (!inst || typeof host !== "string" || typeof team !== "string" || !ID.test(host) || !ID.test(team)) return fail("validation.invalid", "an install offers its own host and team")
    const access = await teamStub(this.host.env, team).hostAccess(team, host, p)
    if (access?.role !== "host") return fail("auth.forbidden", "only the Mac that enrolled this host can offer it")
    const device = this.host.trust.open(entity).currentState.devices[inst.id]
    const cert = device?.certs.direct
    if (!cert || device.host !== host || cert.expires_at <= Date.now()) return fail("pairing.no_host_key", "publish this Mac's direct key with its host first")
    const offerHost: OfferHost = { host, team, owner_user: entity, host_install: inst.id, host_name: access.host.name, host_jwk: inst.public_jwk as OfferHost["host_jwk"], host_cert: cert }
    for (let attempt = 0; attempt < 3; attempt++) {
      const code = offerCode()
      const id = await offerId(code)
      const made = await offerStub(this.host.env, id).offerCreate(offerHost, Date.now())
      if (made.ok && made.expires_at) {
        return { ok: true, value: { offer: code, offer_id: id, expires_at: made.expires_at, link: offerLink(code, { host, team, host_key: cert.key, expires_at: made.expires_at, name: access.host.name }) } }
      }
    }
    return fail("owner.unreachable", "no free offer code, try again", true)
  }

  /** `pairing.claim {offer, host, host_key}` from the phone that scanned the QR code. */
  private async claim(entity: string, p: Principal, params: Record<string, unknown>): Promise<Outcome> {
    const { offer, host, host_key } = params
    if (typeof offer !== "string" || !OFFER_CODE.test(offer) || typeof host !== "string" || !ID.test(host) || typeof host_key !== "string" || !KEY.test(host_key)) return fail("validation.invalid", "offer, host and host_key are required")
    const peer = peerOf(this.host, entity, this.host.user()!.state, p)
    if (!peer) return fail("pairing.no_device_key", "publish this device's direct key first")
    const id = await offerId(offer)
    const r = await offerStub(this.host.env, id).offerClaim({ host, host_key, claimant: peer }, Date.now())
    if (!r.ok) return fail(r.code, r.message)
    const o = r.offer
    const hostView = { host: o.host, team: o.team, name: o.host_name, owner_user: o.owner_user, host_install: o.host_install, host_jwk: o.host_jwk, host_cert: o.host_cert }
    // Same account: own devices are already trusted (b6-pairing.md 3); nothing else is written.
    if (r.same_account) return { ok: true, value: { status: "trusted", offer_id: id, ...hostView } }
    const request = { ...peer, offer_id: id, host: o.host, host_name: o.host_name, team: o.team, expires_at: o.expires_at }
    const res = await userStub(this.host.env, o.owner_user).crossUserTrust(o.owner_user, "trust.request.add", request, `request:${id}`, entity)
    const added = outcomeOf(res.frames)
    return added.ok ? { ok: true, value: { status: "pending", offer_id: id, ...hostView } } : added
  }

  /** `trust.request.accept {offer_id}` by the host owner (session or own install, never a chief). */
  private async accept(entity: string, p: Principal, params: Record<string, unknown>): Promise<Outcome> {
    if (p.agent || (p.kind !== "session" && !deviceOf(this.host.user()!.state, p))) return fail("auth.forbidden", "the Mac's owner accepts")
    const id = params.offer_id
    if (typeof id !== "string" || !KEY.test(id)) return fail("validation.invalid", "offer_id is required")
    const trust = this.host.trust.open(entity).currentState
    // A retry after a partial accept: the guest is already recorded, the request gone.
    const request = trust.requests[id] ?? Object.values(trust.guests).find((g) => g.offer_id === id)
    if (!request) return fail("pairing.offer_unknown", "pairing request expired or unknown")
    const done = await offerStub(this.host.env, id).offerComplete(entity, request.install, Date.now())
    if (!done.ok) return fail(done.code, done.message)
    const o = done.offer
    const admitted = outcomeOf((await teamStub(this.host.env, request.team).hostGuest(request.team, "host.guest.set", { host: request.host, install: request.install, user: request.user, offer_id: id }, `guest:${id}`)).frames)
    if (!admitted.ok) return admitted
    const peer: TrustPeerDevice = { install: request.install, user: request.user, user_name: request.user_name, name: request.name, platform: request.platform, public_jwk: request.public_jwk, cert: request.cert }
    const guest = outcomeOf(submitTrust(this.host, entity, "trust.guest.add", { ...peer, offer_id: id, host: request.host, team: request.team }, `guest:${id}`))
    if (!guest.ok) return guest
    const remote = { host: o.host, team: o.team, owner_user: entity, name: o.host_name, host_install: o.host_install, public_jwk: o.host_jwk, cert: o.host_cert, install: request.install, offer_id: id }
    const indexed = outcomeOf((await userStub(this.host.env, request.user).crossUserTrust(request.user, "trust.remote.add", remote, `remote:${id}`, entity)).frames)
    return indexed.ok ? { ok: true, value: { host: request.host, install: request.install } } : indexed
  }

  private async decline(entity: string, p: Principal, params: Record<string, unknown>): Promise<Outcome> {
    if (p.agent || (p.kind !== "session" && !deviceOf(this.host.user()!.state, p))) return fail("auth.forbidden", "the Mac's owner declines")
    const id = params.offer_id
    if (typeof id !== "string" || !KEY.test(id)) return fail("validation.invalid", "offer_id is required")
    await offerStub(this.host.env, id).offerDecline(entity, Date.now())
    return outcomeOf(submitTrust(this.host, entity, "trust.request.remove", { offer_id: id }, `decline:${id}`))
  }

  /**
   * `pairing.revoke {host, install}`: the owner removes a guest from a host, or a guest's account
   * removes its own device's access. Admission goes first (TeamDO), then both trust stores.
   */
  private async revoke(entity: string, p: Principal, params: Record<string, unknown>): Promise<Outcome> {
    if (p.agent) return fail("auth.forbidden", "a chief token cannot change pairing")
    const { host, install } = params
    if (typeof host !== "string" || typeof install !== "string" || !ID.test(host) || !ID.test(install)) return fail("validation.invalid", "host and install are required")
    const trust = this.host.trust.open(entity).currentState
    const k = pairKey(host, install)
    const asOwner = trust.guests[k]
    const asGuest = trust.remote[k]
    if (!asOwner && !asGuest) return fail("selector.not_found", "no pairing between this host and device")
    const team = (asOwner ?? asGuest)!.team
    const key = `revoke:${host}:${install}`
    const removed = outcomeOf((await teamStub(this.host.env, team).hostGuest(team, "host.guest.remove", { host, install }, key)).frames)
    if (!removed.ok) return removed
    const mine = outcomeOf(submitTrust(this.host, entity, asOwner ? "trust.guest.remove" : "trust.remote.remove", { host, install }, key))
    if (!mine.ok) return mine
    const other = asOwner ? asOwner.user : asGuest!.owner_user
    const theirs = outcomeOf((await userStub(this.host.env, other).crossUserTrust(other, asOwner ? "trust.remote.remove" : "trust.guest.remove", { host, install }, key, entity)).frames)
    return theirs.ok ? { ok: true, value: { host, install } } : theirs
  }
}

/** `pairing.hosts`: this account's Macs and the other accounts' hosts it was accepted on. */
export const pairingHosts = (trust: TrustState | undefined) => ({
  hosts: [
    ...Object.values(trust?.devices ?? {})
      .filter((d) => d.host && d.certs.direct)
      .map((d) => ({ host: d.host!, name: d.name, install: d.install, trust: "trusted" as const, owner: "self" as const, key: (d.certs.direct as LinkCert).key })),
    ...Object.values(trust?.remote ?? {}).map((r) => ({ host: r.host, name: r.name, install: r.host_install, trust: "trusted" as const, owner: r.owner_user, key: r.cert.key }))
  ]
})
