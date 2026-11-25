import { describe, it } from "vitest"
import { grantCarryProperty } from "./team-delete-grant-support.ts"

// Seeds 1032..1047 of the grant carry property's 64 (team-delete-grant-support.ts). Each interleaving builds a
// fresh team (about 1 s alone, 2.5 s beside the suite's other files, 4.5 s on a loaded runner), so 16 fit the time limit.
describe("property: a carry never grants more than the latest confirmed grant, or to anyone but the latest owner", { timeout: 300_000 }, () => {
  it("16 random interleavings of refreshes, webhooks, ownership changes, revocations and deletes (seeds 1032..1047)", () => grantCarryProperty(32, 16))
})
