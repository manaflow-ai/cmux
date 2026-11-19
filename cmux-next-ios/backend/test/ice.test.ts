import { describe, expect, it } from "vitest"
import type { Env } from "../src/env.ts"
import { STUN, iceServers } from "../src/ice.ts"

// STACK_TEST_ICE_SERVERS: an offline lab hands out its own TURN, only when ENVIRONMENT=test.
const lab = [
  { urls: ["turn:198.18.0.3:3478?transport=udp", "turns:turn.lab.test:443?transport=tcp"], username: "lab", credential: "labpass" },
  { urls: "stun:198.18.0.2:3478" }
]
const noFetch = (() => Promise.reject(new Error("no network in this test"))) as unknown as typeof fetch
const envOf = (vars: Record<string, string>) => vars as unknown as Env

describe("STACK_TEST_ICE_SERVERS", () => {
  it("adds the lab's servers beside Cloudflare STUN when ENVIRONMENT=test", async () => {
    const r = await iceServers(envOf({ ENVIRONMENT: "test", STACK_TEST_ICE_SERVERS: JSON.stringify(lab) }), noFetch)
    expect(r.turn).toBe(true)
    expect(r.iceServers).toEqual([
      { urls: [STUN] },
      { urls: lab[0]!.urls, username: "lab", credential: "labpass" },
      { urls: ["stun:198.18.0.2:3478"] }
    ])
  })

  it("is ignored outside ENVIRONMENT=test", async () => {
    for (const ENVIRONMENT of ["dev", "prod", ""]) {
      const r = await iceServers(envOf({ ENVIRONMENT, STACK_TEST_ICE_SERVERS: JSON.stringify(lab) }), noFetch)
      expect(r).toMatchObject({ iceServers: [{ urls: [STUN] }], turn: false })
    }
  })

  it("drops bad JSON and entries that are not STUN or TURN urls", async () => {
    const bad = await iceServers(envOf({ ENVIRONMENT: "test", STACK_TEST_ICE_SERVERS: "{nope" }), noFetch)
    expect(bad).toMatchObject({ iceServers: [{ urls: [STUN] }], turn: false })
    const mixed = await iceServers(
      envOf({ ENVIRONMENT: "test", STACK_TEST_ICE_SERVERS: JSON.stringify([null, 7, { urls: ["https://x"] }, { urls: ["stun:10.0.0.1"], username: 3 }]) }),
      noFetch
    )
    expect(mixed).toMatchObject({ iceServers: [{ urls: [STUN] }, { urls: ["stun:10.0.0.1"] }], turn: false })
  })
})
