import { env } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { describe, expect, it } from "vitest"
import { ACCOUNT_WIDE_BINDINGS, PER_BUILD_BINDINGS, envForObject, spaceOf, spaceOfObject, spacedEnv, spacedName } from "../src/build-space.ts"
import { spaceRows } from "../src/build-space-projection.ts"
import type { RawEnv } from "../src/env.ts"
import { fireAlarm } from "./setup/alarm.ts"

/** Build spaces (src/build-space.ts) below the HTTP routes: production, objects, alarms, projection rows, classification. */
const raw = env as unknown as RawEnv
/** Untyped stubs: runInDurableObject over a typed RPC stub is too deep for the checker. */
const inDO = runInDurableObject as unknown as <T>(stub: unknown, fn: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>

describe("build spaces inside the Worker", () => {
  it("production ignores the header and never builds a dev space", () => {
    const request = new Request("https://api.test/v1/read", { headers: { "x-cmux-build-space": "dev:a" } })
    expect(spaceOf(request, { ENVIRONMENT: "production" })).toEqual({ ok: true, space: "" })
    expect(spaceOf(new Request("https://api.test", { headers: { "x-cmux-build-space": "nope" } }), { ENVIRONMENT: "production" })).toEqual({ ok: true, space: "" })
    expect(spaceOf(request, { ENVIRONMENT: "staging" })).toEqual({ ok: true, space: "dev:a" })
    const production = { ...raw, ENVIRONMENT: "production" } as RawEnv
    expect(() => spacedEnv(production, "dev:a")).toThrow(/production/)
    // An object named into a dev space refuses to start in production.
    const ctx = { id: { name: spacedName("dev:a", "user_x") }, storage: { kv: { get: () => undefined, put: () => undefined } } } as unknown as DurableObjectState
    expect(() => envForObject(ctx, production)).toThrow(/production/)
  })

  it("an object's calls and alarms stay in its space", async () => {
    const user = `user_${crypto.randomUUID().replace(/-/g, "").slice(0, 20)}`
    const stub = raw.USER_DO.get(raw.USER_DO.idFromName(spacedName("dev:a", user)))
    const seen = await inDO(stub, async (instance, state) => {
      const e = instance.env
      // A DO-to-DO call from inside reaches the same space's object; an account-wide binding is the shared one.
      const conv = e.CONVERSATION_DO.idFromName("conv_X").toString() === raw.CONVERSATION_DO.idFromName("dev:a|conv_X").toString()
      const team = e.TEAM_DO.idFromName("team_x").toString() === raw.TEAM_DO.idFromName("team_x").toString()
      // A wake without a name (an alarm after eviction) reads the space the object remembered.
      const unnamed = spaceOfObject({ id: { name: undefined }, storage: state.storage } as unknown as DurableObjectState)
      return { space: e.BUILD_SPACE, conv, team, unnamed }
    })
    expect(seen).toEqual({ space: "dev:a", conv: true, team: true, unnamed: "dev:a" })
    // The alarm handler runs with the same env.
    await fireAlarm(stub)
    expect(await inDO(stub, async (instance) => instance.env.BUILD_SPACE)).toBe("dev:a")
    // A nightly object is untouched: no remembered space, raw bindings.
    const base = raw.USER_DO.get(raw.USER_DO.idFromName(user))
    expect(await inDO(base, async (instance, state) => [instance.env.BUILD_SPACE, state.storage.kv.get("__build_space") ?? null])).toEqual(["", null])
  })

  it("projects a dev build's rows keyed by its space and leaves nightly's untouched", () => {
    const rows = [
      { id: 1, kind: "home.conversation.upsert", entity: "c", payload: { id: "conv_dm_X", kind: "dm" }, seq: 1 },
      { id: 2, kind: "user.upsert", entity: "u", payload: { id: "user_x" }, seq: 2 },
      { id: 3, kind: "brand.new.kind", entity: "n", payload: {}, seq: 3 }
    ] as never
    const dev = spaceRows("dev:a", rows)
    expect(dev.dev.map((r) => (r.payload as any).id)).toEqual(["dev:a|conv_dm_X"])
    expect((dev.dev[0]!.payload as any).space).toBe("dev:a")
    // Account-wide and unclassified kinds never leave a dev build.
    expect(dev.skipped).toEqual([2, 3])
    expect(spaceRows("", rows)).toEqual({ base: rows, dev: [], skipped: [] })
    // A shared object's host row names its space in the payload.
    const host = spaceRows("", [{ id: 4, kind: "host.upsert", entity: "h", payload: { id: "host_1", space: "dev:b" }, seq: 4 }] as never)
    expect((host.dev[0]!.payload as any).id).toBe("dev:b|host_1")
  })

  it("classifies every Durable Object binding exactly once", () => {
    const bindings = Object.entries(raw).filter(([k, v]) => k.endsWith("_DO") && v && typeof (v as DurableObjectNamespace).idFromName === "function").map(([k]) => k).sort()
    const listed = [...PER_BUILD_BINDINGS, ...ACCOUNT_WIDE_BINDINGS]
    expect(new Set(listed).size).toBe(listed.length)
    for (const b of bindings) expect(listed, `${b} is in neither list of build-space.ts`).toContain(b)
  })
})
