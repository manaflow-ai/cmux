import { describe, expect, it } from "vitest"
import { CloudSocketAuthority } from "../src/cloud-socket-authority.ts"

const A = "a".repeat(64), B = "b".repeat(64)
const member = (authority_version: string) => ({ role: "admin", authority_version })
const deferred = <T>() => {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((done) => { resolve = done })
  return { promise, resolve }
}
const socket = (user: string, authority?: string) => {
  const closes: Array<{ code: number; reason: string }> = []
  const ws = { deserializeAttachment: () => ({ principal: { user }, team_authority: authority }),
    close: (code: number, reason: string) => { closes.push({ code, reason }) } } as unknown as WebSocket
  return { ws, closes }
}

describe("Cloud socket authority races", () => {
  it("a notice during a held admission refuses the old answer", async () => {
    const held = deferred<ReturnType<typeof member>>()
    let reads = 0
    const gate = new CloudSocketAuthority(() => ++reads === 1 ? held.promise : Promise.resolve(member(B)), () => [])
    const admission = gate.admit("team", "user")
    await gate.changed("team", "user")
    held.resolve(member(A))
    expect(await admission).toBeNull()
    expect(await gate.admit("team", "user")).toBe(B)
  })

  it("a newer notice owns the result when two authority reads complete out of order", async () => {
    const held = deferred<ReturnType<typeof member>>()
    const fresh = socket("user", B), stale = socket("user", A)
    let reads = 0
    const gate = new CloudSocketAuthority(() => ++reads === 1 ? held.promise : Promise.resolve(member(B)), () => [fresh.ws, stale.ws])
    const older = gate.changed("team", "user")
    await gate.changed("team", "user")
    held.resolve(member(A))
    await older
    expect(fresh.closes).toEqual([])
    expect(stale.closes).toEqual([{ code: 4401, reason: "team authority changed" }])
  })

  it("an older notice read cannot close a connection admitted by a newer membership read", async () => {
    const held = deferred<ReturnType<typeof member>>()
    const old = socket("user", "0".repeat(64)), fresh = socket("user", B)
    const sockets = [old.ws]
    let reads = 0
    const gate = new CloudSocketAuthority(() => ++reads === 1 ? held.promise : Promise.resolve(member(B)), () => sockets)
    const notice = gate.changed("team", "user")
    expect(await gate.admit("team", "user")).toBe(B)
    sockets.push(fresh.ws)
    held.resolve(member(A))
    await notice
    expect(fresh.closes).toEqual([])
    expect(old.closes).toEqual([{ code: 4401, reason: "team authority changed" }])
  })

  it("an unreachable owner closes affected idle sockets and leaves delivery retryable", async () => {
    const affected = socket("user", A), other = socket("other", A)
    let unavailable = true
    const gate = new CloudSocketAuthority(async () => { if (unavailable) throw new Error("offline"); return member(A) }, () => [affected.ws, other.ws])
    await expect(gate.changed("team", "user")).rejects.toThrow("offline")
    expect(affected.closes).toHaveLength(1)
    expect(other.closes).toEqual([])
    expect(await gate.admit("team", "user")).toBeNull()
    unavailable = false
    await gate.changed("team", "user")
    expect(affected.closes).toHaveLength(1)
  })

  it("invalid authority refuses admission and closes idle authority without acknowledging success", async () => {
    const old = socket("user", A)
    const gate = new CloudSocketAuthority(async () => member("malformed"), () => [old.ws])
    expect(await gate.admit("team", "user")).toBeNull()
    await expect(gate.changed("team", "user")).rejects.toThrow("team authority is unavailable")
    expect(old.closes).toHaveLength(1)
  })

  it("a new gate reads persisted socket authority and retires legacy attachments", async () => {
    const fresh = socket("user", B), old = socket("user", A), legacy = socket("user")
    const gate = new CloudSocketAuthority(async () => member(B), () => [fresh.ws, old.ws, legacy.ws])
    await gate.changed("team", "user")
    expect(fresh.closes).toEqual([])
    expect(old.closes).toHaveLength(1)
    expect(legacy.closes).toHaveLength(1)
  })

  it.each([null, { role: "guest", authority_version: B }])("missing or resource-less membership closes every affected connection: %j", async (membership) => {
    const old = socket("user", A)
    const gate = new CloudSocketAuthority(async () => membership, () => [old.ws])
    expect(await gate.admit("team", "user")).toBeNull()
    await gate.changed("team", "user")
    expect(old.closes).toHaveLength(1)
  })
})
