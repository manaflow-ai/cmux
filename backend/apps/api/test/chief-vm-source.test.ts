import { describe, expect, it } from "vitest"
// @ts-expect-error a Vite raw import (the test runner bundles it; the Worker build never sees it)
import file from "../../../chief-cc/image/chief-vm.mjs?raw"
import { CHIEF_VM_MJS } from "../src/chief-brain-cc/chief-vm-source.ts"

/** The `chief-vm` the Worker writes into each turn machine is the checked-in client (bun scripts/gen-chief-vm-source.ts). */
describe("chief-vm source", () => {
  it("matches backend/chief-cc/image/chief-vm.mjs", () => {
    expect(CHIEF_VM_MJS).toBe(file)
  })
})
