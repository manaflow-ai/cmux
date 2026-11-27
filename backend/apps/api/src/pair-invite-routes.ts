import type { Principal } from "@cmux/ownership"
import type { Env } from "./env.ts"
import { displayInvite, inviteFromRandom, normalizeInvite, sha256Hex } from "./domains/pairing.ts"
import { collectSecret, watchSecret, watchSecretValid } from "./pair-collect.ts"
import { fail, isHumanSession, pairingStub, pairLimited, type OpReply } from "./pair-op-reply.ts"
import type { PairingInvite } from "./pairing-do.ts"

/**
 * Invite-code pairing, the reverse direction of server pairing (plans/cmux-next/server.md 6.2):
 * a signed-in device shows a code and the new machine types it (`cmux pair ABCDE-12345`), so
 * nobody ssh-es into the box to read its code. It ends in the same PairingDO record, preview and
 * approve as the forward flow.
 *
 * - `server.pair.invite` (`/v1/ops`, a person's session, origin user, a role that may add a
 *   server): mints a 10-symbol invite and a watch secret. One live invite per person: a new one
 *   voids the old one.
 * - `POST /v1/pair/begin` with `invite`: the box's begin as today, and the invite is redeemed
 *   atomically. The first box binds it; the same key again gets the same code back; any other key
 *   voids it, aborts the first box's pairing and gets 409.
 * - `GET /v1/pair/invite/wait?invite=CODE` (WebSocket, subprotocols `cmux.pair-invite.v1,
 *   watch.<secret>`): `pending`, `arrived` (replayed on connect), `paired`, `voided`; close 4408
 *   at the end of its life. The Worker checks the secret before any Durable Object wakes.
 * - `server.pair.approve` on an invited record: only the inviter, into the invite's team; the
 *   watcher then hears `paired`.
 */

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } })

const inviteStub = (env: Env, invite: string) => env.PAIRING_DO.get(env.PAIRING_DO.idFromName(`invite:${invite}`))
const ownedStub = (env: Env, user: string) => env.PAIRING_DO.get(env.PAIRING_DO.idFromName(`invite-user:${user}`))

/** What the box is told about who must confirm: the inviter's name, else their email. */
const inviterLabel = (p: Principal): string | null => {
  const named = p as Principal & { display_name?: string; email?: string | null }
  const label = named.display_name?.trim() || named.email?.trim() || ""
  return label ? label.slice(0, 120) : null
}

/** server.pair.invite: mint an invite for the caller's team and void the caller's previous one (pair-invite-owner.ts). */
export const pairInvite = async (env: Env, principal: Principal, frame: { op: string; params: unknown; idempotency_key: string; origin?: string }): Promise<OpReply> => {
  const op = frame.op
  const key = frame.idempotency_key
  if (!isHumanSession(principal)) return fail(op, key, "auth.forbidden", "pairing needs a signed-in user")
  if (frame.origin !== "user") return fail(op, key, "auth.forbidden", "an invite is made by a person (origin user)")
  const params = (frame.params ?? {}) as { team?: unknown }
  // Phase 1 routes TeamDO by the token's team only, as approve does.
  if (params.team !== principal.team) return fail(op, key, "auth.forbidden", "pairing into another team is not supported yet")
  if (!(await pairLimited(env, principal))) return fail(op, key, "auth.forbidden", "too many pairing requests, try again in a minute", true)
  const team = principal.team!
  const user = principal.user!
  if (!(await env.TEAM_DO.get(env.TEAM_DO.idFromName(team)).canEnrollServer(team, principal))) return fail(op, key, "auth.forbidden", "only team owners and admins may add a server")
  const now = Date.now()
  // Idempotent per person and request key: the owner records the key before the invite is minted.
  const keyHash = await sha256Hex(key)
  const ownerStub = ownedStub(env, user)
  const reply = (invite: string, expiresAt: number, secret: string, replayed: boolean): OpReply => ({
    ok: true, op, value: { invite, display: displayInvite(invite), expires_at: expiresAt, watch_secret: secret }, transaction: "", idempotency_key: key, replayed, stream: "pairing", sequence: 0
  })
  // 50-bit codes: a collision with a live invite is negligible; try a few anyway.
  for (let attempt = 0; attempt < 5; attempt++) {
    const candidate = inviteFromRandom(crypto.getRandomValues(new Uint8Array(7)))
    const begun = await ownerStub.inviteOwnerBegin(keyHash, candidate, team, now)
    if (begun.state === "conflict") return fail(op, key, "idempotency.conflict", "this idempotency key made an invite for another team")
    const invite = begun.state === "fresh" ? candidate : begun.invite
    const secret = await watchSecret(env, invite, user, keyHash)
    if (begun.state === "replay" && begun.expires_at !== null) return reply(invite, begun.expires_at, secret, true)
    const minted = await inviteStub(env, invite).inviteMint({ invite, approver: user, team, inviter: inviterLabel(principal), watch_hash: await sha256Hex(secret), now })
    if (!minted.ok) {
      await ownerStub.inviteOwnerForget(keyHash, invite)
      continue
    }
    // Makes it the live invite and voids the previous one; a void that fails is retried on the owner's alarm.
    const committed = await ownerStub.inviteOwnerCommit(keyHash, invite, minted.expires_at, now)
    if (!committed.ok) {
      // The owner gave the key up (this request stalled past its recheck): this invite must not stay live.
      await voidInvite(env, invite, "replaced", now)
      return fail(op, key, "owner.unreachable", "making the invite took too long, try again", true)
    }
    return reply(invite, minted.expires_at, secret, begun.state === "replay")
  }
  return fail(op, key, "owner.unreachable", "no free invite code, try again", true)
}

const voidInvite = async (env: Env, invite: string, reason: "replaced" | "second_redemption", now: number) => {
  const voided = await inviteStub(env, invite).inviteVoid(invite, reason, now)
  if (voided.code) await pairingStub(env, voided.code).inviteAbort(voided.code, invite, now)
}

export interface BegunPairing {
  readonly code: string
  readonly collect: string
  readonly expires_at: number
}

const notFound = () => json({ error: "invite expired or unknown" }, 404)
const used = () => json({ error: "invite already used" }, 409)

/**
 * The invite half of `POST /v1/pair/begin`, after the Worker verified the box's proof. `create`
 * makes the box's PairingDO record as a plain begin does (with the invite on it); `reply` is the
 * plain begin's reply.
 */
export const beginWithInvite = async (
  env: Env,
  box: { invite: string; thumbprint: string; info: unknown; country: string | null; now: number },
  create: (invite: PairingInvite) => Promise<BegunPairing | null>,
  reply: (begun: BegunPairing, extra: Record<string, unknown>) => Response
): Promise<Response> => {
  const { invite, thumbprint, now } = box
  const stub = inviteStub(env, invite)
  const peek = await stub.invitePeek(invite, now)
  if (peek.state === "unknown") return notFound()
  if (peek.state === "used") return used()
  const extra = { invited: true, inviter: peek.inviter }
  // The same box again (a lost reply): the bound code with a fresh collect secret.
  const resume = async (code: string): Promise<Response> => {
    const collect = await collectSecret(env, code)
    const rekeyed = await pairingStub(env, code).inviteRekey(code, invite, thumbprint, await sha256Hex(collect), now)
    return rekeyed.ok ? reply({ code, collect, expires_at: rekeyed.expires_at }, extra) : notFound()
  }
  if (peek.state === "arrived") {
    if (peek.thumbprint === thumbprint) return resume(peek.code)
    await voidInvite(env, invite, "second_redemption", now)
    return used()
  }
  const begun = await create({ invite, invited_by: peek.approver, invited_team: peek.team })
  if (!begun) return json({ error: "no free pairing code, try again" }, 503)
  const redeemed = await stub.inviteRedeem(invite, { code: begun.code, thumbprint, info: box.info, country: box.country, expires_at: begun.expires_at }, now)
  if (redeemed.ok && redeemed.code === begun.code) return reply(begun, extra)
  // Lost a race: forget this begin's record (nobody saw its code).
  await pairingStub(env, begun.code).inviteAbort(begun.code, invite, now)
  if (redeemed.ok) return resume(redeemed.code)
  if (redeemed.reason === "voided" && redeemed.first) await pairingStub(env, redeemed.first).inviteAbort(redeemed.first, invite, now)
  return redeemed.reason === "unknown" ? notFound() : used()
}

/** After an approval of an invited record completed: the inviter's watcher hears `paired`. */
export const invitePairedNotify = async (env: Env, invite: string, code: string, host: string): Promise<void> => {
  await inviteStub(env, invite).invitePaired(invite, code, host, Date.now())
}

/** `GET /v1/pair/invite/wait` (WebSocket). Stateless secret check before any Durable Object wakes. */
export const handlePairInviteWait = async (request: Request, env: Env): Promise<Response> => {
  if (request.headers.get("Upgrade") !== "websocket") return json({ error: "websocket required" }, 426)
  const invite = normalizeInvite(new URL(request.url).searchParams.get("invite") ?? "")
  const protocols = (request.headers.get("Sec-WebSocket-Protocol") ?? "").split(",").map((s) => s.trim())
  const secret = protocols.find((p) => p.startsWith("watch."))?.slice("watch.".length)
  if (!invite || !secret) return json({ error: "invite and watch secret required" }, 400)
  if (!(await watchSecretValid(env, invite, secret))) return json({ error: "not found" }, 404)
  const headers = new Headers(request.headers)
  headers.set("x-cmux-watch-hash", await sha256Hex(secret))
  return inviteStub(env, invite).fetch(new Request(`https://pairing.internal/v1/pair/invite/wait`, { headers, method: "GET" }))
}
