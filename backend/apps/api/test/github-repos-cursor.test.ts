import { describe, expect, it } from "vitest"
import { followingRepoPage, selectRepoPage } from "../src/integrations/github-tokens.ts"

const a = { id: "conn_" + "a".repeat(20) }
const b = { id: "conn_" + "b".repeat(20) }
const c = { id: "conn_" + "c".repeat(20) }
const principal = "session:user-a"
const policy = "policy-version-a"

function first(ids = [a, b]) {
  const picked = selectRepoPage(ids, principal, "reports", policy)
  if (!picked.ok) throw new Error("initial page denied")
  return picked
}
function next(ids = [a, b], hasNext = false) {
  return followingRepoPage(first(ids), ids, hasNext)
}
function expectStale(ids: Array<{ id: string }>, cursor: string, actor = principal, filter = "reports", policyHash = policy) {
  expect(selectRepoPage(ids, actor, filter, policyHash, cursor)).toMatchObject({
    ok: false,
    status: 409,
    code: "cursor_stale",
  })
}

describe("GitHub repository cursors preserve selected installation identity", () => {
  it("tracks the same selected connection through subsequent pages", () => {
    const page2 = next([a, b], true)
    expect(page2).toBeTruthy()
    expect(selectRepoPage([a, b], principal, "reports", policy, page2!)).toMatchObject({
      ok: true, index: 0, connectionId: a.id, page: 2,
    })
    const secondConnection = next([a, b], false)
    expect(secondConnection).toBeTruthy()
    expect(selectRepoPage([a, b], principal, "reports", policy, secondConnection!)).toMatchObject({
      ok: true, index: 1, connectionId: b.id, page: 1,
    })
    const last = selectRepoPage([a, b], principal, "reports", policy, secondConnection!)
    if (!last.ok) throw new Error("second connection missing")
    expect(followingRepoPage(last, [a, b], false)).toBeNull()
  })

  it("refuses reorder, revoke or insertion instead of changing installations", () => {
    const cursor = next()!
    expectStale([b, a], cursor)
    expectStale([a], cursor)
    expectStale([a, c, b], cursor)
    expectStale([c, a, b], cursor)
  })

  it("binds the cursor to exact caller, query and policy snapshot", () => {
    const cursor = next()!
    expectStale([a, b], cursor, "session:user-b")
    expectStale([a, b], cursor, principal, "other-query")
    expectStale([a, b], cursor, principal, "reports", "policy-version-b")
    // Query normalization is stable across case and surrounding whitespace.
    expect(selectRepoPage([a, b], principal, " REPORTS ", policy, cursor)).toMatchObject({
      ok: true, connectionId: b.id, page: 1,
    })
  })

  it("rejects index-based legacy cursors, malformed data and oversized input", () => {
    const legacy = btoa(JSON.stringify({ installation: 1, page: 1 }))
    for (const value of [legacy, "?oops", "a".repeat(4_097)]) {
      expect(selectRepoPage([a, b], principal, "reports", policy, value)).toMatchObject({
        ok: false, status: 400, code: "request.invalid",
      })
    }
  })

  it("returns an explicit refusal for an empty connection list", () => {
    expect(selectRepoPage([], principal, "reports", policy)).toMatchObject({
      ok: false, code: "integration.not_found",
    })
  })
})
