import { decodeProtectedHeader, exportPKCS8, generateKeyPair } from "jose"
import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test"
import { afterEach, describe, expect, it, vi } from "vitest"
import { env } from "cloudflare:workers"
import worker from "../src/index.ts"
import type { Env } from "../src/env.ts"
import { apnsTopics, sendCloudAttention } from "../src/push.ts"
import type { PushRegistration } from "../src/store.ts"
import { call, register, token } from "./helpers.ts"

// The App Store app (com.cmux.app) and the TestFlight app (cmux INTERNAL, dev.cmux.app.internal) share one
// Worker. Each phone registers its own bundle id; every push to it carries that topic, on the APNs host of
// the environment it registered with.
const APP_STORE = "com.cmux.app"
const INTERNAL = "dev.cmux.app.internal"

afterEach(() => {
  vi.restoreAllMocks()
})

const deployed = (): { dev: string; prod: string } => JSON.parse((env as unknown as Env).TEST_DEPLOYED_APNS_TOPICS ?? "{}")
const topicsOf = (list: string) => apnsTopics({ APNS_TOPICS: list } as Env)

describe("APNs topics per app bundle", () => {
  it("dev and prod accept both the App Store and the TestFlight bundle", () => {
    for (const [name, list] of Object.entries(deployed())) {
      const topics = topicsOf(list)
      expect(topics.has(APP_STORE), `${name} APNS_TOPICS`).toBe(true)
      expect(topics.has(INTERNAL), `${name} APNS_TOPICS`).toBe(true)
      // Extensions never register a token: APNs topics are the app's own bundle id.
      for (const ext of ["notification-content", "notification-service"]) {
        expect(topics.has(`${APP_STORE}.${ext}`), `${name} APNS_TOPICS`).toBe(false)
        expect(topics.has(`${INTERNAL}.${ext}`), `${name} APNS_TOPICS`).toBe(false)
      }
    }
    expect(Object.keys(deployed()).sort()).toEqual(["dev", "prod"])
  })

  it("refuses a bundle that is not one of the Worker's apps", async () => {
    const t = await token("topic-rhea")
    const phone = await register(t, "phone", "personal-topic-rhea")
    for (const topic of ["com.cmux.app.evil", "com.cmux", "COM.CMUX.APP", `${APP_STORE}.notification-service`, "dev.cmux.app", "", 7])
      expect((await call("PUT", `/v1/devices/${phone}/push`, t, { token: "ab".repeat(32), environment: "production", topic })).status, String(topic)).toBe(400)
    expect((await call("GET", "/v1/me/devices", t)).json.devices.find((d: any) => d.deviceId === phone).push).toBe(false)
  })

  it("pushes to each phone with its own bundle as the topic, on its own APNs environment", async () => {
    const t = await token("topic-sol")
    const mac = await register(t, "mac", "personal-topic-sol")
    const phones = [
      { id: await register(t, "phone", "personal-topic-sol"), token: "c1".repeat(32), environment: "production", topic: APP_STORE },
      { id: await register(t, "phone", "personal-topic-sol"), token: "c2".repeat(32), environment: "production", topic: INTERNAL },
      // An App Store bundle build installed from Xcode registers sandbox.
      { id: await register(t, "phone", "personal-topic-sol"), token: "c3".repeat(32), environment: "sandbox", topic: APP_STORE }
    ] as const
    for (const p of phones) {
      const r = await call("PUT", `/v1/devices/${p.id}/push`, t, { token: p.token, environment: p.environment, topic: p.topic, kinds: ["question"] })
      expect(r).toMatchObject({ status: 200, json: { push: { environment: p.environment, topic: p.topic } } })
    }
    const { privateKey } = await generateKeyPair("ES256", { extractable: true })
    const apnsEnv = { ...env, APNS_KEY_P8: await exportPKCS8(privateKey), APNS_KEY_ID: "KEYTOPIC1", APNS_TEAM_ID: "TEAMTOPIC" }
    const sent: Array<{ host: string; token: string; topic: string | null; kid: string | undefined }> = []
    const realFetch = globalThis.fetch
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const req = input instanceof Request ? input : new Request(String(input), init)
      const url = new URL(req.url)
      if (url.hostname !== "api.push.apple.com" && url.hostname !== "api.sandbox.push.apple.com") return realFetch(input, init)
      const kid = decodeProtectedHeader(req.headers.get("authorization")!.slice(7)).kid
      sent.push({ host: url.hostname, token: url.pathname.split("/").pop()!, topic: req.headers.get("apns-topic"), kid })
      return new Response(null, { status: 200 })
    })
    const ctx = createExecutionContext()
    const res = await worker.fetch(
      new Request(`https://api.test/v1/devices/${mac}/notify`, {
        method: "POST",
        headers: { "content-type": "application/json", authorization: `Bearer ${t}` },
        body: JSON.stringify({ eventId: "evt-topics", kind: "question", agent: "Claude", place: "repo" })
      }),
      apnsEnv as unknown as Parameters<typeof worker.fetch>[1],
      ctx
    )
    await waitOnExecutionContext(ctx)
    expect(res.status).toBe(200)
    expect(await res.json()).toMatchObject({ configured: true, sent: 3, failed: 0, dropped: 0 })
    expect(sent.sort((a, b) => a.token.localeCompare(b.token))).toEqual([
      { host: "api.push.apple.com", token: phones[0].token, topic: APP_STORE, kid: "KEYTOPIC1" },
      { host: "api.push.apple.com", token: phones[1].token, topic: INTERNAL, kid: "KEYTOPIC1" },
      { host: "api.sandbox.push.apple.com", token: phones[2].token, topic: APP_STORE, kid: "KEYTOPIC1" }
    ])
  })

  it("sends Cloud attention with each phone's own bundle as the topic", async () => {
    const { privateKey } = await generateKeyPair("ES256", { extractable: true })
    const config = { keyP8: await exportPKCS8(privateKey), keyId: "KEYTOPIC2", teamId: "TEAMTOPIC" }
    const target = (tok: string, topic: string): PushRegistration => ({
      deviceId: crypto.randomUUID(),
      ownerUserId: "owner",
      token: tok,
      environment: "production",
      topic,
      kinds: ["question"],
      mutedMacs: [],
      previews: true,
      updatedAt: ""
    })
    const seen: Array<Request> = []
    const fetcher = (async (req: Request) => {
      seen.push(req)
      return new Response(null, { status: 200 })
    }) as unknown as typeof fetch
    const event = {
      recipient: "owner",
      kind: "done" as const,
      event_id: "attention-topics",
      team_id: "team-1",
      machine_id: "vm_abcdefghijklmnopqrst",
      session_id: "session-1",
      deep_link: "cmux://cloud/chat/vm_abcdefghijklmnopqrst/session-1"
    }
    const result = await sendCloudAttention(config, [target("d1".repeat(32), APP_STORE), target("d2".repeat(32), INTERNAL)], event, Date.now(), fetcher)
    expect(result.map((r) => r.outcome)).toEqual(["sent", "sent"])
    expect(seen.map((r) => [new URL(r.url).pathname, r.headers.get("apns-topic")])).toEqual([
      [`/3/device/${"d1".repeat(32)}`, APP_STORE],
      [`/3/device/${"d2".repeat(32)}`, INTERNAL]
    ])
  })
})
