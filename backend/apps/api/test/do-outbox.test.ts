import type { OutboxRow } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { groupTargets } from "../src/do-outbox.ts"

const row = (id: number, cls: string | null, name: string, kind: string, key: string, coalesce?: string): OutboxRow => ({
  id,
  seq: id,
  kind,
  entity: key,
  payload: { n: id },
  target: cls ? { class: cls, name, ...(coalesce ? { coalesce } : {}) } : null
})

describe("DO-to-DO outbox grouping (E4)", () => {
  it("groups by target in outbox order, skips projection rows, and keeps the newest per coalesce key", () => {
    const batches = groupTargets([
      row(1, "UserDO", "user_a", "inbox.bump", "bump:c1:1", "c1"),
      row(2, null, "x", "home.message.upsert", "m"),
      row(3, "UserDO", "user_b", "inbox.bump", "bump:c1:1", "c1"),
      row(4, "UserDO", "user_a", "inbox.bump", "bump:c1:2", "c1"),
      row(5, "MuxDO", "agent_x", "mux.wake", "wake:c1:2"),
      row(6, "UserDO", "user_a", "inbox.bump", "bump:c2:7", "c2")
    ])
    expect(batches.map((b) => `${b.class}:${b.name}`)).toEqual(["UserDO:user_a", "UserDO:user_b", "MuxDO:agent_x"])
    const a = batches[0]!
    expect(a.items.map((i) => i.key)).toEqual(["bump:c1:2", "bump:c2:7"])
    expect(a.superseded).toEqual([1])
    expect(batches[2]!.items).toEqual([{ id: 5, op: "mux.wake", params: { n: 5 }, key: "wake:c1:2" }])
  })
})
