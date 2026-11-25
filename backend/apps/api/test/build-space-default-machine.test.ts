import { env } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { describe, expect, it } from "vitest"
import { spacedEnv, spacedName } from "../src/build-space.ts"
import type { RawEnv } from "../src/env.ts"
import { platformInSpace, type DefaultMachinePlatform } from "../src/user-chief-provision.ts"

/** cmux-platform's `ensureDefaultMachine(user, space?)` (cmux-platform#1465): its service RPC carries no header, so a
 * dev build's UserDO names its space as the second argument, and nightly's sends none. */
const raw = env as unknown as RawEnv
const inDO = runInDurableObject as unknown as <T>(stub: unknown, fn: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>
const USER = "user_00000000000000000042"

const recording = () => {
  const calls: Array<Array<unknown>> = []
  const platform = { ensureDefaultMachine: async (...args: Array<unknown>) => { calls.push(args); return { ok: false, code: "x", message: "x", retryable: false } } }
  return { calls, platform: platform as unknown as DefaultMachinePlatform }
}

describe("ensureDefaultMachine's build space", () => {
  it("a dev space names itself; nightly sends the user only", async () => {
    const dev = recording()
    await platformInSpace(dev.platform, "dev:feat-x")!.ensureDefaultMachine(USER)
    expect(dev.calls).toEqual([[USER, "dev:feat-x"]])
    const nightly = recording()
    await platformInSpace(nightly.platform, "")!.ensureDefaultMachine(USER)
    expect(nightly.calls).toEqual([[USER]])
    expect(platformInSpace(undefined, "dev:feat-x")).toBeUndefined()
  })

  it("a dev build's UserDO asks the platform in its own space", async () => {
    const devEnv = spacedEnv(raw, "dev:feat-x")
    const stub = devEnv.USER_DO.get(devEnv.USER_DO.idFromName(USER))
    const calls = await inDO(stub, async (instance) => {
      const fake = recording()
      Object.defineProperty(instance, "env", { value: { ...instance.env, PLATFORM: fake.platform }, configurable: true })
      await instance.signupPlatform().ensureDefaultMachine(USER)
      return fake.calls
    })
    expect(calls).toEqual([[USER, "dev:feat-x"]])
    const nightlyStub = raw.USER_DO.get(raw.USER_DO.idFromName(spacedName("", USER)))
    const nightlyCalls = await inDO(nightlyStub, async (instance) => {
      const fake = recording()
      Object.defineProperty(instance, "env", { value: { ...instance.env, PLATFORM: fake.platform }, configurable: true })
      await instance.signupPlatform().ensureDefaultMachine(USER)
      return fake.calls
    })
    expect(nightlyCalls).toEqual([[USER]])
  })
})
