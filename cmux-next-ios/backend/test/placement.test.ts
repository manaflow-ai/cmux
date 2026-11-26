import { describe, expect, it } from "vitest"
import { costTo, parseNetcheck, relayPlacement } from "../src/placement.ts"
import type { Ingress } from "../src/team-hub.ts"

const at = (lat: number, lon: number, rtt?: Ingress["rtt"]): Ingress => ({ colo: null, country: null, continent: null, lat, lon, ...(rtt ? { rtt } : {}) })
const SEATTLE = at(47.6, -122.3)
const LONDON = at(51.5, -0.1)
const MUMBAI = at(19.1, 72.9)
const TOKYO = at(35.7, 139.7)
const PARIS = at(48.9, 2.4)

describe("relay placement from both ends", () => {
  it("falls back to the joiner's hint when the peer's location is unknown", () => {
    expect(relayPlacement(SEATTLE, null, "wnam")).toEqual({ hint: "wnam", by: "joiner" })
    expect(relayPlacement(SEATTLE, { colo: "SEA", country: "US", continent: "NA" }, "wnam")).toEqual({ hint: "wnam", by: "joiner" })
  })

  it("places a Mumbai-London link between them, not at the joiner", () => {
    // The joiner in Mumbai would have put it in apac (Hong Kong), about 10,000 km from London.
    const p = relayPlacement(MUMBAI, LONDON, "apac")
    expect(p.by).toBe("both")
    expect(["me", "eeur", "weur"]).toContain(p.hint)
    expect(p.ms!).toBeLessThan(costTo(MUMBAI, "apac")! + costTo(LONDON, "apac")!)
  })

  it("is the same region whichever end joins first", () => {
    expect(relayPlacement(TOKYO, SEATTLE, "apac").hint).toBe(relayPlacement(SEATTLE, TOKYO, "wnam").hint)
    expect(relayPlacement(MUMBAI, LONDON, "apac").hint).toBe(relayPlacement(LONDON, MUMBAI, "weur").hint)
  })

  it("keeps two ends in one region there", () => {
    expect(relayPlacement(LONDON, PARIS, "weur").hint).toBe("weur")
  })

  it("prefers measured round trips over geography", () => {
    // Geography says weur for both; their netchecks say eeur is faster for this pair.
    const a = at(51.5, -0.1, { weur: 40, eeur: 12 })
    const b = at(48.9, 2.4, { weur: 38, eeur: 14 })
    expect(relayPlacement(a, b, "weur")).toEqual({ hint: "eeur", by: "both", ms: 26 })
  })

  it("mixes a measured end with an estimated one", () => {
    // By geography alone a Seattle-London relay goes to weur; Seattle's netcheck finds Europe slow from there.
    expect(relayPlacement(SEATTLE, LONDON, "wnam").hint).toBe("weur")
    const a = at(47.6, -122.3, { wnam: 20, enam: 70, weur: 160, eeur: 180, sam: 190, apac: 150, oc: 180, afr: 300, me: 260 })
    expect(relayPlacement(a, LONDON, "wnam").hint).toBe("wnam")
  })
})

describe("parseNetcheck", () => {
  it("keeps valid region entries only", () => {
    expect(parseNetcheck("wnam:31,enam:72.4,mars:3,weur:-1,eeur:x,apac")).toEqual({ wnam: 31, enam: 72 })
    expect(parseNetcheck("")).toBeUndefined()
    expect(parseNetcheck("x".repeat(300))).toBeUndefined()
    expect(parseNetcheck(null)).toBeUndefined()
  })
})
