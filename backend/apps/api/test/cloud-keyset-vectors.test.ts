import { describe, expect, it } from "vitest"
import keysetVectors from "../../../../schemas/link-token/keyset-vectors.json"
import { parseKeysetAnswer } from "../src/link-keyset.ts"
import { worker } from "./cloud-bind-support.ts"

/**
 * schemas/link-token/keyset-vectors.json (a9's request, 2026-10-05): what the VM daemon does with each
 * GET /v1/cloud/keyset answer. The reference parser here must give every expected result, and the
 * live endpoint's answer must parse.
 */

interface Case {
  readonly name: string
  readonly answers: ReadonlyArray<{ readonly status: number; readonly headers: Record<string, string>; readonly body: unknown; readonly expect: Record<string, unknown> }>
}
const doc = keysetVectors as unknown as { cases: ReadonlyArray<Case> }

describe("keyset vectors", { timeout: 60_000 }, () => {
  it("covers a9's cases", () => {
    const names = doc.cases.map((c) => c.name)
    for (const n of ["ok", "unknown_fields", "three_kids", "version_change", "rate_limited", "unavailable", "wrong_alg", "wrong_crv"]) expect(names, n).toContain(n)
  })

  it("the reference parser gives every expected result", () => {
    for (const c of doc.cases) for (const a of c.answers) expect(parseKeysetAnswer(a), c.name).toEqual(a.expect)
  })

  it("the live endpoint answer parses", async () => {
    const res = await worker.fetch("https://api.test/v1/cloud/keyset")
    const r = parseKeysetAnswer({ status: res.status, headers: Object.fromEntries(res.headers), body: await res.json() })
    expect(r).toMatchObject({ ok: true })
  })
})
