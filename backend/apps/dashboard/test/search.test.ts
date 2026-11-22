import { describe, expect, it } from "bun:test"
import { callbackSearch, parseSearch, stringifySearch } from "../src/lib/search.ts"

describe("callback search params", () => {
  it("keeps the exact URL GitHub sends as plain strings and serializes it back unquoted", () => {
    const github = "?code=684ed4464c4860dd49aa&installation_id=167172954&setup_action=install&state=eyJhbGciOiJFUzI1NiJ9.eyJjb25uIjoiY29ubl8xIn0.sig"
    const parsed = callbackSearch(parseSearch(github))
    expect(parsed).toEqual({ state: "eyJhbGciOiJFUzI1NiJ9.eyJjb25uIjoiY29ubl8xIn0.sig", code: "684ed4464c4860dd49aa", installation_id: "167172954", setup_action: "install", error: undefined })
    const back = stringifySearch(parsed)
    expect(back).not.toContain("%22")
    expect(new URLSearchParams(back).get("installation_id")).toBe("167172954")
  })
  it("drops a non-numeric installation id, including the old quoted form", () => {
    expect(callbackSearch(parseSearch("?installation_id=%22167172954%22")).installation_id).toBeUndefined()
    expect(callbackSearch(parseSearch("?installation_id=12abc")).installation_id).toBeUndefined()
  })
  it("reads Slack and Linear redirects and provider errors", () => {
    expect(callbackSearch(parseSearch("?code=abc&state=s1"))).toMatchObject({ code: "abc", state: "s1" })
    expect(callbackSearch(parseSearch("error=access_denied&state=s1"))).toMatchObject({ error: "access_denied" })
  })
})
