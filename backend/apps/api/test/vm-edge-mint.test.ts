import { describe, expect, it } from "vitest"
import { EDGE_SIGNIN_REFUSAL, vmEdgeMintCheck } from "../src/vm-edge-mint.ts"
import { post, sessionToken } from "./cloud-bind-support.ts"
import { inDO, testEnv } from "./github-token-support.ts"

const MACHINE = `vm_${"7".repeat(20)}`
const TOKEN = "minted.vm.token"

/** cmux-platform over the PLATFORM binding: cloud.vm.self.get for MACHINE, answering `extra` on the machine's read. */
const platform = (answer: (op: string, machine: string | undefined, authorization: string | null) => Response) => {
  const seen: Array<{ op: string; machine?: string; authorization: string | null }> = []
  return {
    seen,
    PLATFORM: {
      fetch: async (req: Request) => {
        const { op, params } = (await req.json()) as { op: string; params: { machine?: string } }
        seen.push({ op, machine: params.machine, authorization: req.headers.get("authorization") })
        return answer(op, params.machine, req.headers.get("authorization"))
      }
    } as unknown as Fetcher
  }
}
const self = (extra: Record<string, unknown>) => () => Response.json({ op: "cloud.vm.self.get", value: { machine: { id: MACHINE }, ...extra }, revision: "cloud:1" })

describe("T17: a machine that signs in through its platform edge mints with no copied install key", () => {
  it("refuses a vm install's key when the platform says the machine signs in through its edge, asking as the minted token", async () => {
    const p = platform(self({ platform_edge: true, edge_signin: true }))
    expect(await vmEdgeMintCheck({ PLATFORM: p.PLATFORM }, "https://platform", { vm: true, bound_machine: MACHINE }, TOKEN)).toEqual({ refused: true, message: EDGE_SIGNIN_REFUSAL })
    expect(p.seen).toEqual([{ op: "cloud.vm.self.get", machine: MACHINE, authorization: `Bearer ${TOKEN}` }])
  })

  it("keeps today's mint when the machine's git is on the edge but its sign-in is not (platform_edge alone)", async () => {
    const p = platform(self({ platform_edge: true }))
    expect(await vmEdgeMintCheck({ PLATFORM: p.PLATFORM }, "https://platform", { vm: true, bound_machine: MACHINE }, TOKEN)).toEqual({ refused: false })
  })

  it("keeps today's mint for a machine without the edge, and when the read fails or there is no PLATFORM binding", async () => {
    for (const answer of [
      self({}),
      () => Response.json({ _tag: "Forbidden", code: "auth.forbidden", message: "not this machine" }, { status: 403 }),
      () => Response.json({ error: { code: "owner.unreachable", message: "down", retryable: true } }, { status: 503 }),
      () => new Response("not json", { status: 502 })
    ]) {
      const p = platform(answer)
      expect(await vmEdgeMintCheck({ PLATFORM: p.PLATFORM }, "https://platform", { vm: true, bound_machine: MACHINE }, TOKEN)).toEqual({ refused: false })
    }
    expect(await vmEdgeMintCheck({}, "https://platform", { vm: true, bound_machine: MACHINE }, TOKEN)).toEqual({ refused: false })
    const thrown = { fetch: async () => { throw new Error("binding gone") } } as unknown as Fetcher
    expect(await vmEdgeMintCheck({ PLATFORM: thrown }, "https://platform", { vm: true, bound_machine: MACHINE }, TOKEN)).toEqual({ refused: false })
  })

  it("never reads the platform for a person's own install or a vm with no bound machine", async () => {
    const p = platform(self({ edge_signin: true }))
    expect(await vmEdgeMintCheck({ PLATFORM: p.PLATFORM }, "https://platform", {}, TOKEN)).toEqual({ refused: false })
    expect(await vmEdgeMintCheck({ PLATFORM: p.PLATFORM }, "https://platform", { vm: true }, TOKEN)).toEqual({ refused: false })
    expect(p.seen).toEqual([])
  })

  it("UserDO.redeem names a vm install's bound machine (for the check), and the token answer does not", async () => {
    const sub = "t17-redeem-bound-machine"
    const session = await sessionToken(sub)
    const user = (await post("/v1/ops", session, { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "user" })).body.value
    const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
    const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
    const reg = await post("/v1/ops", session, { op: "install.register", params: { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x!, y: jwk.y! }, kind: "cli", name: "cli", device_name: "cli", platform: "macos" }, idempotency_key: crypto.randomUUID(), origin: "user" })
    const cli = reg.body.value.id as string
    // A VM install bound to MACHINE with the same key (as Cloud's bind registers one under the creator).
    const vm = `inst_vm${crypto.randomUUID().replace(/-/g, "").slice(0, 18)}`, grant = `grant_${crypto.randomUUID().replace(/-/g, "").slice(0, 20)}`
    const userDO = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user.id))
    await inDO(userDO, async (i) => {
      const s = i.boundEngine.currentState
      s.installs[vm] = { ...s.installs[cli], id: vm, kind: "vm", grant, revoked_at: null, bound_team: user.personal_team, bound_machine: MACHINE }
      s.grants[grant] = { id: grant, grantee: vm, op_classes: ["vm-self"], approval: "none", expires_at: null, revoked_at: null, created_from: "install" }
    })
    const sign = async (prefix: string, nonce: string) => {
      const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${prefix}${nonce}`))
      return btoa(String.fromCharCode(...new Uint8Array(sig))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
    }
    const ch = await post("/v1/auth/challenge", undefined, { user: user.id, install: vm })
    const redeemed = await userDO.redeem(user.id, vm, ch.body.nonce, await sign(ch.body.message_prefix, ch.body.nonce))
    expect([redeemed.ok, redeemed.vm, redeemed.bound_machine]).toEqual([true, true, MACHINE])
    // Over HTTP with no edge said (the test Worker has no PLATFORM binding): today's mint, and no machine id in the answer.
    const again = await post("/v1/auth/challenge", undefined, { user: user.id, install: vm })
    const tok = await post("/v1/auth/token", undefined, { user: user.id, install: vm, nonce: again.body.nonce, signature: await sign(again.body.message_prefix, again.body.nonce) })
    expect([tok.status, typeof tok.body.access_token, JSON.stringify(tok.body).includes(MACHINE)]).toEqual([200, "string", false])
    // The same mint over HTTP once the platform says the machine signs in through its edge: refused, no token.
    const p = platform(self({ platform_edge: true, edge_signin: true }))
    const had = testEnv.PLATFORM
    testEnv.PLATFORM = p.PLATFORM
    try {
      const third = await post("/v1/auth/challenge", undefined, { user: user.id, install: vm })
      const refused = await post("/v1/auth/token", undefined, { user: user.id, install: vm, nonce: third.body.nonce, signature: await sign(third.body.message_prefix, third.body.nonce) })
      expect([refused.status, refused.body.code, refused.body.message, "access_token" in refused.body]).toEqual([403, "auth.forbidden", EDGE_SIGNIN_REFUSAL, false])
      expect(p.seen.map((s) => [s.op, s.machine, /^Bearer ./.test(s.authorization ?? "")])).toEqual([["cloud.vm.self.get", MACHINE, true]])
    } finally {
      testEnv.PLATFORM = had
    }
    // A person's own install carries no machine.
    const own = await post("/v1/auth/challenge", undefined, { user: user.id, install: cli })
    const mine = await userDO.redeem(user.id, cli, own.body.nonce, await sign(own.body.message_prefix, own.body.nonce))
    expect([mine.ok, "bound_machine" in mine]).toEqual([true, false])
  })
})
