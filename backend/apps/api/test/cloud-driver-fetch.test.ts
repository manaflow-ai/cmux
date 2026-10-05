import { describe, expect, it } from "vitest"
import { FreestyleCloudDriver } from "../src/cloud-driver.ts"

/**
 * Found by the first real development create (2026-10-05): the driver stored the global fetch as a
 * property and called it as a method, which workerd refuses ("Illegal invocation"), so every real
 * provider call answered "no answer UNREACHABLE" and no test saw it (tests pass their own fetch).
 * Here the driver runs with its default fetch in workerd, against a port that refuses connections:
 * the error must carry the network reason, and it must not be an illegal invocation.
 */
describe("Freestyle driver default fetch", () => {
  it("reaches the network layer with the runtime's fetch", async () => {
    const driver = new FreestyleCloudDriver("not-a-key", "http://127.0.0.1:9", "cmuxnp-test-vmimg-1")
    const err = (await driver.find("cmuxnp-test-cld-vm-00000000000000000001").catch((e: unknown) => e)) as Error
    expect(err.message).toMatch(/^read VM: no answer UNREACHABLE \(/)
    expect(err.message).not.toMatch(/Illegal invocation/)
  })

  it("never puts the key or a URL with credentials into the error text (review P2)", async () => {
    const key = "fs_live_SECRETKEYVALUE0123456789abcdef"
    const fetchFn = (async () => {
      throw new TypeError(`Headers.append: "Bearer ${key}\n" is an invalid header value. Fetch API cannot load: https://user:pass@api.example/v5?key=abc`)
    }) as unknown as typeof fetch
    const driver = new FreestyleCloudDriver(`${key}\n`, "https://api.freestyle.sh", "cmuxnp-test-vmimg-1", fetchFn)
    const err = (await driver.find("cmuxnp-test-cld-vm-00000000000000000001").catch((e: unknown) => e)) as Error
    expect(err.message).toMatch(/^read VM: no answer UNREACHABLE \(/)
    for (const leak of [key, "SECRETKEY", "user:pass", "key=abc", "api.example"]) expect(err.message, leak).not.toContain(leak)
  })
})
