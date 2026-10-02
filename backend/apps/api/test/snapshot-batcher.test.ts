import { describe, expect, it } from "vitest"
import { SnapshotBatcher } from "../src/snapshot-batcher.ts"

/** Review P2 (snapshot cost): one filtered snapshot per subscriber per batch, one view per user. */
describe("SnapshotBatcher", () => {
  it("coalesces hidden events into one snapshot per subscriber and builds one view per user", () => {
    let scheduled: (() => void) | undefined
    const sent: Array<[string, string]> = []
    let views = 0
    const batcher = new SnapshotBatcher<string>({
      schedule: (fn) => {
        expect(scheduled).toBeUndefined()
        scheduled = fn
      },
      viewFor: (user) => {
        views += 1
        return `view:${user}`
      },
      send: (socket, text) => sent.push([socket, text])
    })
    for (let i = 0; i < 5; i++) {
      batcher.mark("ws-a", "user_1")
      batcher.mark("ws-b", "user_1")
      batcher.mark("ws-c", "user_2")
    }
    expect(sent).toEqual([])
    scheduled!()
    expect(sent).toEqual([["ws-a", "view:user_1"], ["ws-b", "view:user_1"], ["ws-c", "view:user_2"]])
    expect(views).toBe(2)
    // A new burst schedules again.
    scheduled = undefined
    batcher.mark("ws-a", "user_1")
    expect(scheduled).toBeDefined()
  })
})
