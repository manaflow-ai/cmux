import { describe, expect, it } from "vitest"
import { pairApprove } from "../src/pair-routes.ts"
import { beginPairing, op, read, sessionPrincipal, sessionToken, testEnv, userSubmit, waitFor } from "./pairing-harness.ts"

/**
 * A paired box gets the same machine credential as a pasted join line (pair-machine-join.ts): the approval mints a
 * join token for the approver on the platform and pushes it with the result, never in the op's reply.
 */
const TOKEN = `cmj_${"a".repeat(43)}`

const platform = (reply: () => Response) => {
  const calls: Array<{ url: string; auth: string | null; body: any }> = []
  return {
    calls,
    fetch: async (url: string, init: RequestInit) => {
      calls.push({ url, auth: new Headers(init.headers).get("authorization"), body: JSON.parse(String(init.body)) })
      return reply()
    }
  }
}
const minted = () => Response.json({ joinTokenId: "join_1", token: TOKEN, expiresAt: new Date(Date.now() + 600_000).toISOString(), teamId: "t" })

const setup = async (name: string) => {
  const owner = await sessionToken(name)
  await op(owner, "user.ensure", {})
  const team = (await read(owner, "team.directory", {})).json.value.team as string
  const user = (await read(owner, "install.list", {})).json.value.user.id as string
  const { res } = await beginPairing(Date.now(), false, "203.0.113.40")
  const code = res.json.code as string
  const waiter = await waitFor(code, res.json.collect_secret)
  await waiter.until(() => waiter.frames.length >= 1)
  return { owner, team, user, code, waiter }
}

describe("server pairing mints the box's machine join token (workerd)", () => {
  it("pushes one join token minted for the approver with the result, and a retry reuses it", async () => {
    const { owner, team, user, code, waiter } = await setup("stack-pair-machine-join")
    const fake = platform(minted)
    const env = { PAIRING_DO: testEnv.PAIRING_DO, TEAM_DO: testEnv.TEAM_DO, PLATFORM: fake, INTERNAL_TOKEN: "internal-test" } as never
    const approve = () => pairApprove(env, sessionPrincipal(user, team), { op: "server.pair.approve", params: { code, team, name: "Studio" }, idempotency_key: "machine-join" }, userSubmit as never)
    const first = await approve()
    expect(first.ok).toBe(true)
    // The approver's reply never carries the token.
    expect(JSON.stringify(first)).not.toContain(TOKEN)
    expect(fake.calls).toHaveLength(1)
    expect(fake.calls[0]).toMatchObject({ url: "https://platform/internal/v1/machines/join-tokens", auth: "Bearer internal-test", body: { teamId: team, userId: user, label: "Studio", ttlSeconds: 600 } })
    await waiter.until(() => waiter.frames.some((f) => f.t === "paired"))
    const paired = waiter.frames.find((f) => f.t === "paired")
    expect(paired.machine_join.token).toBe(TOKEN)
    expect(paired.machine_join.expires_at).toBeGreaterThan(Date.now())
    // Only the token and its expiry reach the box.
    expect(Object.keys(paired.machine_join).sort()).toEqual(["expires_at", "token"])
    expect(paired).toMatchObject({ team, user })
    // A retried approval answers the same result and mints nothing more.
    expect(await approve()).toMatchObject({ ok: true, value: first.value })
    expect(fake.calls).toHaveLength(1)
    // The server row is written as before.
    expect(((await read(owner, "team.directory", {})).json.value.hosts as Array<{ kind?: string }>).filter((h) => h.kind === "server")).toHaveLength(1)
  })

  it("a platform that cannot mint fails the approval before any install or host, and a retry finishes it", async () => {
    const { owner, team, user, code, waiter } = await setup("stack-pair-machine-join-down")
    let down = true
    const fake = platform(() => (down ? new Response("nope", { status: 503 }) : minted()))
    const env = { PAIRING_DO: testEnv.PAIRING_DO, TEAM_DO: testEnv.TEAM_DO, PLATFORM: fake, INTERNAL_TOKEN: "internal-test" } as never
    const approve = () => pairApprove(env, sessionPrincipal(user, team), { op: "server.pair.approve", params: { code, team, name: "Studio" }, idempotency_key: "machine-join-down" }, userSubmit as never)
    expect(await approve()).toMatchObject({ ok: false, error: { code: "owner.unreachable", retryable: true } })
    expect(((await read(owner, "install.list", {})).json.value.installs as Array<{ kind: string }>).filter((i) => i.kind === "daemon")).toHaveLength(0)
    down = false
    expect((await approve()).ok).toBe(true)
    await waiter.until(() => waiter.frames.some((f) => f.t === "paired"))
    expect(waiter.frames.find((f) => f.t === "paired").machine_join.token).toBe(TOKEN)
  })

  it("without the platform binding the box pairs as before, with no join token", async () => {
    const { team, user, code, waiter } = await setup("stack-pair-machine-join-unbound")
    const env = { PAIRING_DO: testEnv.PAIRING_DO, TEAM_DO: testEnv.TEAM_DO } as never
    expect((await pairApprove(env, sessionPrincipal(user, team), { op: "server.pair.approve", params: { code, team, name: "Studio" }, idempotency_key: "unbound" }, userSubmit as never)).ok).toBe(true)
    await waiter.until(() => waiter.frames.some((f) => f.t === "paired"))
    expect(waiter.frames.find((f) => f.t === "paired").machine_join).toBeUndefined()
  })
})
