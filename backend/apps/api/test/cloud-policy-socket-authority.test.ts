import { describe, expect, it } from "vitest"
import { CloudSocketAuthority } from "../src/cloud-socket-authority.ts"

const A = "a".repeat(64), B = "b".repeat(64)
const member = (authority_version: string) => ({ role: "owner", authority_version })
const deferred = <T>() => {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((done) => { resolve = done })
  return { promise, resolve }
}
const socket = (user: string, authority?: string) => {
  const closes: number[] = []
  const ws = { deserializeAttachment: () => ({ principal: { user }, team_authority: authority }),
    close: (code: number) => { closes.push(code) } } as unknown as WebSocket
  return { ws, closes }
}

describe("Cloud policy authority fanout", () => {
  it("fences a pending admission even when the user has no existing socket", async () => {
    const held = deferred<ReturnType<typeof member>>()
    let reads = 0, accepted = 0
    const gate = new CloudSocketAuthority(() => ++reads === 1 ? held.promise : Promise.resolve(member(B)), () => [])
    const pending = gate.admit("team", "user", () => { accepted++; return new Response("accepted") })
    await gate.changedAll("team")
    held.resolve(member(A))
    expect(await pending).toBeNull()
    expect(accepted).toBe(0)
    expect(await (await gate.admit("team", "user", (version) => new Response(version)))?.text()).toBe(B)
  })

  it("reads each subscribed user once and preserves current sockets", async () => {
    const a = socket("one", A), fresh = socket("one", B), b = socket("two", A), legacy = socket("two")
    const reads: string[] = []
    const gate = new CloudSocketAuthority(async (_team, user) => { reads.push(user); return member(B) },
      () => [a.ws, fresh.ws, b.ws, legacy.ws])
    await gate.changedAll("team")
    expect(reads.sort()).toEqual(["one", "two"])
    expect(a.closes).toEqual([4401]); expect(b.closes).toEqual([4401]); expect(legacy.closes).toEqual([4401])
    expect(fresh.closes).toEqual([])
  })

  it("publishes the accepted socket before releasing its admission ticket", async () => {
    const sockets: WebSocket[] = [], published = socket("user", A)
    let reads = 0, notice: Promise<void> | undefined
    const gate = new CloudSocketAuthority(async () => member(++reads === 1 ? A : B), () => sockets)
    const response = await gate.admit("team", "user", () => {
      sockets.push(published.ws)
      notice = gate.changedAll("team")
      return new Response("accepted")
    })
    await notice
    expect(await response?.text()).toBe("accepted")
    expect(published.closes).toEqual([4401])
  })

  it("an older policy read cannot close a newly admitted socket", async () => {
    const held = deferred<ReturnType<typeof member>>()
    const old = socket("user", "0".repeat(64)), fresh = socket("user", B), sockets = [old.ws]
    let reads = 0
    const gate = new CloudSocketAuthority(() => ++reads === 1 ? held.promise : Promise.resolve(member(B)), () => sockets)
    const notice = gate.changedAll("team")
    expect(await gate.admit("team", "user", (version) => {
      sockets.push(fresh.ws); return new Response(version)
    })).not.toBeNull()
    held.resolve(member(A)); await notice
    expect(old.closes).toEqual([4401]); expect(fresh.closes).toEqual([])
  })

  it("one unavailable member closes that user's candidates and leaves the whole delivery retryable", async () => {
    const healthy = socket("one", A), unavailable = socket("two", A), fresh = socket("one", B)
    let offline = true
    const gate = new CloudSocketAuthority(async (_team, user) => {
      if (user === "two" && offline) throw new Error("unavailable")
      return member(B)
    }, () => [healthy.ws, unavailable.ws, fresh.ws])
    await expect(gate.changedAll("team")).rejects.toThrow("Cloud team authority unavailable")
    expect(healthy.closes).toEqual([4401]); expect(unavailable.closes).toEqual([4401]); expect(fresh.closes).toEqual([])
    offline = false
    await gate.changedAll("team")
    expect(fresh.closes).toEqual([])
  })
})
