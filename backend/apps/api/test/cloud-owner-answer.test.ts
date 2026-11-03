import { CloudConnectInfo } from "@cmux/protocol"
import { runInDurableObject } from "cloudflare:test"
import { Exit, Schema } from "effect"
import { describe, expect, it } from "vitest"
import { verifyLinkToken } from "../src/link-token.ts"
import { cloudStub, createdAndBound, installOf, person } from "./cloud-bind-support.ts"
import { SHARED_TEAM } from "./setup/cloud-teams.ts"

/**
 * The owner answer of the app-server link (cmux-platform#89; Leo, 2026-10-30: "well why can't we
 * just.... do our best now?"): connect_info and link_token answer the caller's vm_kind with the
 * classic attach rule (web vmKindForCaller), and the link token signs it as claim `vmk`, so the
 * answer is the one of a single dial and ends with its token.
 */

const now = () => Math.floor(Date.now() / 1000)
const runIn = runInDurableObject as unknown as <T>(stub: unknown, fn: (instance: any) => Promise<T>) => Promise<T>
/** The shared test team has no TeamDO roster: bind asks whether the creator still may use its machines. */
const sharedTeamMembers = () => runIn(cloudStub(SHARED_TEAM), async (instance) => void (instance.creatorIsMember = async () => true))
const connectInfo = (x: ReturnType<typeof person>, p: typeof x.p, host: string) => x.stub.readOp(x.team, p, "cloud.machine.connect_info", { host })

describe("owner answer: vm_kind on connect_info and link_token", { timeout: 60_000 }, () => {
  it("the creator on their personal team is owner, in connect_info, the mint and the signed claim", async () => {
    const x = person()
    const { host, keyset } = await createdAndBound(x)
    const info = await connectInfo(x, x.p, host)
    expect(info.ok, JSON.stringify(info)).toBe(true)
    expect(info.value.vm_kind).toBe("owner")
    expect(Exit.isSuccess(Schema.decodeUnknownExit(CloudConnectInfo as Schema.Codec<unknown, unknown>)(info.value))).toBe(true)
    const inst = installOf(x.p)
    expect((await connectInfo(x, inst, host)).value.vm_kind).toBe("owner")
    const minted = await x.stub.mintLinkToken(x.team, inst, { host, services: ["daemon", "ssh"] })
    expect(minted.ok, JSON.stringify(minted)).toBe(true)
    expect(minted.value.vm_kind).toBe("owner")
    const verified = await verifyLinkToken(minted.value.token, { aud: host, epoch: 1, now: now(), keyset: keyset.keys })
    expect(verified).toMatchObject({ ok: true, claims: { vmk: "owner", sub: inst.install } })
    const audit = (await x.stub.fakeControl({})).audit
    expect(audit.filter((a) => a.op === "connect_info").map((a) => a.vm_kind)).toEqual(["owner", "owner"])
    expect(audit.filter((a) => a.op === "link_token").map((a) => a.vm_kind)).toEqual(["owner"])
  })

  it("an agent token acting as the creator never carries the owner answer", async () => {
    const x = person()
    const { host } = await createdAndBound(x)
    const agent = { ...installOf(x.p), agent: "agent_chief01" }
    expect((await connectInfo(x, agent, host)).value.vm_kind).toBe("team")
  })

  it("a shared-team creator is owner while each teammate keeps team access", async () => {
    await sharedTeamMembers()
    const creator = person(SHARED_TEAM)
    const { host, keyset } = await createdAndBound(creator)
    expect((await connectInfo(creator, creator.p, host)).value.vm_kind).toBe("owner")
    const creatorToken = await creator.stub.mintLinkToken(SHARED_TEAM, installOf(creator.p), { host, services: ["daemon", "ssh"] })
    expect(creatorToken.ok, JSON.stringify(creatorToken)).toBe(true)
    expect(creatorToken.value.vm_kind).toBe("owner")
    expect(await verifyLinkToken(creatorToken.value.token, { aud: host, epoch: 1, now: now(), keyset: keyset.keys })).toMatchObject({ ok: true, claims: { vmk: "owner" } })
    const third = person(SHARED_TEAM)
    expect((await connectInfo(third, third.p, host)).value.vm_kind).toBe("team")
    const mate = person(SHARED_TEAM)
    const mateInfo = await connectInfo(mate, mate.p, host)
    expect(mateInfo.ok, JSON.stringify(mateInfo)).toBe(true)
    expect(mateInfo.value.vm_kind).toBe("team")
    const minted = await mate.stub.mintLinkToken(SHARED_TEAM, installOf(mate.p), { host, services: ["ssh"] })
    expect(minted.ok, JSON.stringify(minted)).toBe(true)
    expect(minted.value.vm_kind).toBe("team")
    expect(await verifyLinkToken(minted.value.token, { aud: host, epoch: 1, now: now(), keyset: keyset.keys })).toMatchObject({ ok: true, claims: { vmk: "team" } })
  })

  it("another team gets no answer: refused before any vm_kind, on connect_info and the mint", async () => {
    const x = person()
    const { host } = await createdAndBound(x)
    const other = person()
    for (const p of [other.p, installOf(other.p)]) {
      expect(await connectInfo(x, p, host)).toMatchObject({ ok: false, code: "auth.forbidden" })
      expect(await x.stub.mintLinkToken(x.team, installOf(p), { host, services: ["ssh"] })).toMatchObject({ ok: false, code: "auth.forbidden" })
    }
    // Claiming this team's id does not make another person this personal machine's owner.
    const claimed = { ...other.p, team: x.team }
    expect(await connectInfo(x, claimed, host)).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(await x.stub.mintLinkToken(x.team, installOf(claimed), { host, services: ["ssh"] })).toMatchObject({ ok: false, code: "auth.forbidden" })
    await sharedTeamMembers()
    const shared = await createdAndBound(person(SHARED_TEAM))
    expect(await person(SHARED_TEAM).stub.readOp(SHARED_TEAM, x.p, "cloud.machine.connect_info", { host: shared.host })).toMatchObject({ ok: false, code: "auth.forbidden" })
  })

  it("an expired token answers no claims, so its owner answer ends with it", async () => {
    const x = person()
    const { host, keyset } = await createdAndBound(x)
    const minted = await x.stub.mintLinkToken(x.team, installOf(x.p), { host, services: ["ssh"] })
    expect(minted.value.vm_kind).toBe("owner")
    const exp = Math.floor(minted.value.expires_at / 1000)
    expect(await verifyLinkToken(minted.value.token, { aud: host, epoch: 1, now: exp - 1, keyset: keyset.keys })).toMatchObject({ ok: true, claims: { vmk: "owner" } })
    expect(await verifyLinkToken(minted.value.token, { aud: host, epoch: 1, now: exp, keyset: keyset.keys })).toEqual({ ok: false, error: "expired" })
  })

  it("a replayed token answers no claims; a fresh mint answers again", async () => {
    const x = person()
    const { host, keyset } = await createdAndBound(x)
    const inst = installOf(x.p)
    const minted = await x.stub.mintLinkToken(x.team, inst, { host, services: ["ssh"] })
    const seen = new Set<string>()
    const at = { aud: host, epoch: 1, now: now(), keyset: keyset.keys, seen }
    expect(await verifyLinkToken(minted.value.token, at)).toMatchObject({ ok: true, claims: { vmk: "owner" } })
    expect(await verifyLinkToken(minted.value.token, at)).toEqual({ ok: false, error: "replay" })
    const again = await x.stub.mintLinkToken(x.team, inst, { host, services: ["ssh"] })
    expect(again.value.token).not.toBe(minted.value.token)
    expect(await verifyLinkToken(again.value.token, at)).toMatchObject({ ok: true, claims: { vmk: "owner" } })
  })
})
