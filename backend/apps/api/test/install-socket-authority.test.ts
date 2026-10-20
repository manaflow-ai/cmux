import { describe, expect, it } from "vitest"
import type { Env } from "../src/env.ts"
import { InstallSocketAuthority, type InstallSocketView } from "../src/install-socket-authority.ts"

const A = "a".repeat(64), B = "b".repeat(64)
const deferred = <T>() => {
  let resolve!: (value: T) => void, reject!: (error: Error) => void
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no })
  return { promise, resolve, reject }
}
const peer = (version?: string, grant = "grant", user = "user") => {
  const closes: number[] = []
  return { closes, socket: { deserializeAttachment: () => ({ principal: { kind: "install", user, install: "install", grant, install_authority: version } }),
    close: (code: number) => { closes.push(code) } } as unknown as WebSocket }
}
const environment = (read: (refs: ReadonlyArray<unknown>) => Promise<ReadonlyArray<InstallSocketView>>) => ({ USER_DO: {
  idFromName: (user: string) => user, get: () => ({ installSocketAuthorities: (_user: string, refs: ReadonlyArray<unknown>) => read(refs) })
} }) as unknown as Env

describe("current install socket authority", () => {
  it("closes stale and legacy candidates while preserving current and unrelated users", async () => {
    const stale = peer(A), legacy = peer(), fresh = peer(B), other = peer(A, "grant", "other")
    const gate = new InstallSocketAuthority(environment(async () => [B]), () => [stale.socket, legacy.socket, fresh.socket, other.socket])
    await gate.changed("user", "install")
    expect(stale.closes).toEqual([4401]); expect(legacy.closes).toEqual([4401])
    expect(fresh.closes).toEqual([]); expect(other.closes).toEqual([])
  })

  it("a held older notice excludes connections admitted after its candidate snapshot", async () => {
    const held = deferred<ReadonlyArray<InstallSocketView>>(), stale = peer(A), fresh = peer(B), sockets = [stale.socket]
    const gate = new InstallSocketAuthority(environment(() => held.promise), () => sockets)
    const pending = gate.changed("user", "install")
    sockets.push(fresh.socket); held.resolve([null]); await pending
    expect(stale.closes).toEqual([4401]); expect(fresh.closes).toEqual([])
  })

  it("an older failed read cannot undo a newer successful check", async () => {
    const held = deferred<ReadonlyArray<InstallSocketView>>(), current = peer(B); let calls = 0
    const gate = new InstallSocketAuthority(environment(() => ++calls === 1 ? held.promise : Promise.resolve([B])), () => [current.socket])
    const older = gate.changed("user", "install")
    await gate.changed("user", "install")
    held.reject(new Error("old unreachable")); await older
    expect(current.closes).toEqual([])
  })

  it("partial unavailability closes affected candidates and leaves delivery retryable", async () => {
    const current = peer(B), bad = peer(A, "another")
    const gate = new InstallSocketAuthority(environment(async () => [B, { unavailable: true }]), () => [current.socket, bad.socket])
    await expect(gate.changed("user", "install")).rejects.toThrow("install authority unavailable")
    expect(current.closes).toEqual([]); expect(bad.closes).toEqual([4401])
  })

  it("groups duplicate grants and bounds every read to 128 identities", async () => {
    const peers = Array.from({ length: 257 }, (_, index) => peer(A, `grant-${index}`)), batches: number[] = []
    const gate = new InstallSocketAuthority(environment(async (refs) => { batches.push(refs.length); return refs.map(() => B) }), () => peers.map((p) => p.socket))
    await gate.changed("user", "install")
    expect(batches).toEqual([128, 128, 1]); expect(peers.every((p) => p.closes.length === 1)).toBe(true)
  })
})
