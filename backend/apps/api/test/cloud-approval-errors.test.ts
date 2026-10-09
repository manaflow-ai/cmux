import { cloudOpByName } from "@cmux/protocol"
import { describe, expect, it } from "vitest"
import { CLOUD_APPROVAL_OPS } from "../src/domains/cloud.ts"

/**
 * cx-t2rz: the G8 approval path (cx-wb5.65) answers approval.pending, approval.denied,
 * approval.expired and approval.too_many_pending for every Cloud op it gates when an install
 * calls it. The catalog row is the client's contract: a code the row does not declare is a
 * protocol break for every client (cmux-cloud turns it into cmux.cloud.protocol_error).
 */
const APPROVAL_CODES = ["approval.pending", "approval.denied", "approval.expired", "approval.too_many_pending"]

describe("Cloud approval codes in the catalog (cx-t2rz)", () => {
  it("every op the approval gate holds declares the approval codes", () => {
    expect(CLOUD_APPROVAL_OPS.size).toBeGreaterThan(0)
    for (const name of CLOUD_APPROVAL_OPS) {
      const def = cloudOpByName.get(name)
      expect(def, name).toBeDefined()
      for (const code of APPROVAL_CODES) expect(def!.errors, `${name} ${code}`).toContain(code)
    }
  })
  it("ops the gate does not hold do not declare them", () => {
    for (const name of ["cloud.machine.list", "cloud.machine.start", "cloud.machine.pause", "cloud.machine.rename"]) {
      for (const code of APPROVAL_CODES) expect(cloudOpByName.get(name)!.errors, `${name} ${code}`).not.toContain(code)
    }
  })
})
