import { describe, expect, it, vi } from "vitest"
import type { appkv } from "@cmux/home-core"
import type { SecondaryStream } from "../src/secondary-stream.ts"
import { readAppKvOp } from "../src/user-appkv.ts"

describe("appkv list pagination validation", () => {
  it.each([0.5, 0, -1, 501, NaN, Infinity, "1", null])("refuses invalid limit %s before opening storage", (limit) => {
    const open = vi.fn()
    const stream = { open } as unknown as SecondaryStream<appkv.AppKvHead>
    expect(readAppKvOp(stream, "user", "appkv.list", { limit })).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(open).not.toHaveBeenCalled()
  })
})
