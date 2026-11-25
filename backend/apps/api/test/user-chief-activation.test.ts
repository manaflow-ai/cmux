import { env } from "cloudflare:workers"
import { runInDurableObject as runIn } from "cloudflare:test"
import type { OwnerFrame, Principal, ResultFrame } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { DEFAULT_CHIEF_ENSURE, HOSTED_DEFAULT_KEY, defaultChiefIdentity } from "../src/domains/user-chief-default.ts"
import { personalTeamIdFor, type UserState } from "../src/domains/user.ts"
import type { SubmitResult } from "../src/owner-do.ts"
import { quiesce } from "./setup/alarm.ts"
import { cloudTestUser } from "./setup/cloud-teams.ts"

const inDO = runIn as unknown as <T>(stub: unknown, fn: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>
const testEnv = env as unknown as { USER_DO: DurableObjectNamespace; CHIEF_BRAIN_DO: DurableObjectNamespace }
const resultOf = (reply: SubmitResult): ResultFrame => {
  const frame = reply.frames.find((f: OwnerFrame) => f.t === "result" || f.t === "reject")
  if (frame?.t !== "result") throw new Error(JSON.stringify(reply))
  return frame
}
const owner = async (n: number, select = true) => {
  const user = cloudTestUser(n), team = personalTeamIdFor(user)
  const stub = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user)) as unknown as {
    submit(entity: string, principal: Principal, frame: unknown): Promise<SubmitResult>
  }
  const principal: Principal = { identity: `user:${user}`, kind: "session", user, team, stack_user_id: `activation-${n}`, email: `activation-${n}@example.com`, email_verified: true, display_name: "New User" }
  resultOf(await stub.submit(user, principal, { t: "op", op: "user.ensure", params: {}, idempotency_key: "signup", origin: "user" }))
  const agent = await inDO(stub, async (i, state) => {
    await quiesce(i, state)
    if (select) resultOf(i.submitSystem(DEFAULT_CHIEF_ENSURE, {}, HOSTED_DEFAULT_KEY, defaultChiefIdentity(user)))
    await quiesce(i, state)
    return (i.boundEngine.currentState as UserState).hosted_default
  })
  return { user, principal, stub, agent: agent! }
}
const settings = (agent: string) => testEnv.CHIEF_BRAIN_DO.get(testEnv.CHIEF_BRAIN_DO.idFromName(agent)) as unknown as {
  activateDefault(agent: string, owner: string): Promise<{ ok: boolean; reason?: string }>
  configure(agent: string, owner: string, patch: { enabled: boolean }): Promise<{ ok: boolean }>
  status(): Promise<{ config: { enabled: boolean } }>
  admit(agent: string, owner: string, turn: boolean): Promise<{ ok: boolean; reason?: string }>
}
const create = (o: Awaited<ReturnType<typeof owner>>, key = HOSTED_DEFAULT_KEY) => o.stub.submit(o.user, o.principal, {
  t: "op", op: "chief.create", params: { display_name: "Chief", is_default: true }, idempotency_key: key, origin: "user"
})

describe("signup Chief activation and client adoption", () => {
  it("a fresh Mac adopting the signup Chief does not turn an explicitly disabled brain back on", async () => {
    const o = await owner(191), brain = settings(o.agent)
    expect(await brain.configure(o.agent, o.user, { enabled: false })).toMatchObject({ ok: true })
    const reply = resultOf(await create(o))
    expect(reply.value).toMatchObject({ id: o.agent })
    // ensureHosted on a new Mac enables a Chief only when chief.create reports a new creation.
    if (!reply.replayed) expect(await brain.configure(o.agent, o.user, { enabled: true })).toMatchObject({ ok: true })
    expect((await brain.status()).config.enabled).toBe(false)
    expect(reply.replayed).toBe(true)
    expect(await brain.admit(o.agent, o.user, true)).toEqual({ ok: false, reason: "disabled" })
  })

  it("reports genuine client creations as new, then replays the same fixed key", async () => {
    const o = await owner(192, false)
    const created = resultOf(await create(o))
    expect(created.replayed).toBe(false)
    const replay = resultOf(await create(o))
    expect(replay.replayed).toBe(true)
    expect(replay.value).toEqual(created.value)
    const selected = await owner(193)
    expect(resultOf(await create(selected, "another-chief")).replayed).toBe(false)
  })

  it("keeps an explicit disable written before the first signup activation", async () => {
    const o = await owner(194), brain = settings(o.agent)
    expect(await brain.configure(o.agent, o.user, { enabled: false })).toMatchObject({ ok: true })
    expect(await brain.activateDefault(o.agent, o.user)).toEqual({ ok: false, reason: "disabled" })
    expect((await brain.status()).config.enabled).toBe(false)
    expect(await brain.admit(o.agent, o.user, true)).toEqual({ ok: false, reason: "disabled" })
  })

  it("activates signup's selected hosted Chief when the account default has moved", async () => {
    const o = await owner(196), brain = settings(o.agent)
    resultOf(await create(o, "new-account-default"))
    await inDO(o.stub, async (i, state) => {
      await quiesce(i, state)
      expect((i.boundEngine.currentState as UserState).chiefs?.[o.agent]?.is_default).toBe(false)
    })
    expect(await brain.activateDefault(o.agent, o.user)).toMatchObject({ ok: true })
    expect((await brain.status()).config.enabled).toBe(true)
    expect(await brain.admit(o.agent, o.user, true)).toEqual({ ok: false, reason: "provisioning_pending" })
  })

  it("keeps a disable committed while signup activation awaits the owner's Chief record", async () => {
    const o = await owner(195), brain = settings(o.agent)
    await inDO(brain, async (i) => {
      const original = i.env
      let release!: () => void, observed!: () => void
      const readStarted = new Promise<void>((resolve) => { observed = resolve })
      const resumeRead = new Promise<void>((resolve) => { release = resolve })
      i.env = { ...original, USER_DO: {
        idFromName: (name: string) => original.USER_DO.idFromName(name),
        get: (id: DurableObjectId) => ({ readOp: async (...args: unknown[]) => {
          const value = await original.USER_DO.get(id).readOp(...args)
          observed()
          await resumeRead
          return value
        } })
      } }
      try {
        const activation = i.activateDefault(o.agent, o.user)
        await readStarted
        expect(await i.configure(o.agent, o.user, { enabled: false })).toMatchObject({ ok: true })
        release()
        expect(await activation).toEqual({ ok: false, reason: "disabled" })
      } finally {
        release()
        i.env = original
      }
    })
    expect((await brain.status()).config.enabled).toBe(false)
    expect(await brain.admit(o.agent, o.user, true)).toEqual({ ok: false, reason: "disabled" })
  })
})
