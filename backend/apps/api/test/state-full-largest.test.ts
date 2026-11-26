import { describe, expect, it } from "vitest"
import { STATE_MAX_BYTES, stateFull, stateLargest } from "@cmux/ownership"

const big = (n: number) => Array.from({ length: n }, (_, i) => ({ id: `x${i}`, pad: "p".repeat(2000) }))

describe("owner.state_full names the head's largest parts", () => {
  const head = { user: { id: "u1" }, installs: big(300), grants: big(50), ssh_revoke_pending: big(1200), tag: "secret-value" }
  const json = JSON.stringify(head)

  it("names keys, bytes and entry counts, never values", () => {
    expect(json.length).toBeGreaterThan(STATE_MAX_BYTES)
    const msg = stateFull(json, "user:test", "install.register")
    expect(msg).toMatch(/would be \d+ bytes \(limit 1500000\); largest \(bytes\/entries\): ssh_revoke_pending \d+\/1200, installs \d+\/300, grants \d+\/50/)
    expect(msg).not.toContain("secret-value")
  })

  it("orders by size", () => {
    expect(stateLargest(head).map((p) => p.key)).toEqual(["ssh_revoke_pending", "installs", "grants", "tag", "user"])
  })

  it("answers undefined under the limit and [] for a non-object head", () => {
    expect(stateFull(JSON.stringify({ a: 1 }), "user:test", "x")).toBeUndefined()
    expect(stateLargest([1, 2])).toEqual([])
    expect(stateLargest(null)).toEqual([])
  })
})
