/**
 * Where a link session's WebSocket relay (`LinkRelay`) is created, from both ends (RFD 0142 C1+O3).
 *
 * A Durable Object stays where it is first created, and a relay carries every datagram of a link from one end
 * to the other, so its round trip is rtt(a, relay) + rtt(relay, b). Before this, the relay took the first
 * joiner's `locationHint` only: the other end's location never counted. Now it takes the region r that makes
 * cost(a, r) + cost(r, b) least, where an end's cost to a region is:
 *
 * 1. its measured round trip to that region (`netcheck`: the client's own probes of `/v1/netcheck/:region`,
 *    sent with its signal socket), when it has one;
 * 2. else an estimate from Cloudflare's geolocation of its request (`req.cf` latitude and longitude, rounded):
 *    great-circle distance to the region's assumed centre over 100 km per millisecond of round trip (light in
 *    fibre covers about 200 km a millisecond one way, routes run about 1.5x longer than the great circle, so a
 *    round trip is about 1 ms per 66 to 100 km; assumed, not measured);
 * 3. else unknown, and the region falls back to the joiner's hint, as before.
 *
 * Among regions within 2 ms of the least sum, the one closest to even between the ends wins (a relay in the
 * middle leaves neither side a long leg to lose packets on), then the joiner's own hint, then the list's order.
 */
import type { Ingress } from "./team-hub.ts"

export const REGIONS = ["wnam", "enam", "sam", "weur", "eeur", "apac", "oc", "afr", "me"] as const
export type Region = (typeof REGIONS)[number]

/**
 * Assumed centres of each Durable Object region (Cloudflare does not publish which colos host each hint; these
 * are the large metros the region names cover). Only the geographic estimate uses them; a netcheck measures.
 */
export const REGION_CENTRES: Readonly<Record<Region, readonly [number, number]>> = {
  wnam: [37.4, -121.9], // San Jose / Bay Area
  enam: [39.0, -77.5], // Ashburn
  sam: [-23.5, -46.6], // Sao Paulo
  weur: [50.5, 3.0], // between London, Amsterdam, Paris and Frankfurt
  eeur: [52.2, 21.0], // Warsaw
  apac: [22.3, 114.2], // Hong Kong, between Tokyo and Singapore
  oc: [-33.9, 151.2], // Sydney
  afr: [-26.2, 28.0], // Johannesburg
  me: [25.2, 55.3], // Dubai
}

/** Round-trip milliseconds per kilometre of great-circle distance (assumed: see the module comment). */
export const MS_PER_KM = 1 / 100
/** Sums this close to the least count as a tie. */
export const TIE_MS = 2

export const isRegion = (v: string): v is Region => (REGIONS as readonly string[]).includes(v)

/**
 * The name of link session `sessionId`'s relay (`LinkRelay`) in a build space: the owner key, the space and the
 * (lowercase) session id, never a client value. The Worker's relay route and the hub's prewarm (TeamHub) both
 * name the object with this, so they reach the same one.
 */
export const relayRoomName = (ownerKey: string, space: string, sessionId: string) =>
  `${space ? `${space}|` : ""}relay:${ownerKey}:${sessionId}`

/**
 * Where a new TeamHub should live: the region of the caller's own location (Cloudflare's geolocation of the
 * client), not of the colo that received the request. A Durable Object stays where it is first created, and
 * free-plan traffic is sometimes received far away (a California client was served from Paris on 2026-10-13),
 * so creating hubs next to the ingress colo stranded them across an ocean. Only affects a hub's creation.
 */
export const locationHintFor = (cf: { continent?: unknown; longitude?: unknown; country?: unknown } | undefined): DurableObjectLocationHint | undefined => {
  if (!cf || typeof cf.continent !== "string") return undefined
  const lon = typeof cf.longitude === "string" ? Number.parseFloat(cf.longitude) : typeof cf.longitude === "number" ? cf.longitude : Number.NaN
  switch (cf.continent) {
    case "NA":
      return Number.isFinite(lon) && lon < -100 ? "wnam" : "enam"
    case "SA":
      return "sam"
    case "EU":
      return Number.isFinite(lon) && lon > 20 ? "eeur" : "weur"
    case "AF":
      return "afr"
    case "OC":
      return "oc"
    case "AS":
      return ["AE", "BH", "IL", "IQ", "IR", "JO", "KW", "LB", "OM", "QA", "SA", "SY", "YE"].includes(String(cf.country)) ? "me" : "apac"
    default:
      return undefined
  }
}

/** `locationHintFor` of an end known by its signal socket's ingress (the hub has no `req.cf`, only this). */
export const locationHintOf = (end: Ingress | null | undefined): DurableObjectLocationHint | undefined =>
  end ? locationHintFor({ continent: end.continent ?? undefined, longitude: end.lon ?? undefined, country: end.country ?? undefined }) : undefined

/** The netcheck target of `region` in a build space: one `LinkRelay` object per region, never a client value. */
export const netcheckRoomName = (space: string, region: Region) => `${space ? `${space}|` : ""}netcheck:${region}`

/**
 * A client's netcheck as it sends it: `wnam:31,enam:72` (region:milliseconds, at most one entry per region).
 * Anything malformed is dropped entry by entry; an empty result is undefined.
 */
export const parseNetcheck = (raw: string | null | undefined): Partial<Record<Region, number>> | undefined => {
  if (!raw || raw.length > 256) return undefined
  const out: Partial<Record<Region, number>> = {}
  for (const part of raw.split(",")) {
    const [k, v] = part.split(":")
    if (!k || v === undefined || !isRegion(k)) continue
    const ms = Number(v)
    if (!Number.isFinite(ms) || ms < 0 || ms > 5000) continue
    out[k] = Math.round(ms)
  }
  return Object.keys(out).length ? out : undefined
}

const km = (a: readonly [number, number], b: readonly [number, number]) => {
  const rad = Math.PI / 180
  const dLat = (b[0] - a[0]) * rad
  const dLon = (b[1] - a[1]) * rad
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(a[0] * rad) * Math.cos(b[0] * rad) * Math.sin(dLon / 2) ** 2
  return 2 * 6371 * Math.asin(Math.min(1, Math.sqrt(h)))
}

/** An end's round trip to `r`: measured when its netcheck has it, else estimated from its location. */
export const costTo = (end: Ingress | null | undefined, r: Region): number | undefined => {
  if (!end) return undefined
  const measured = end.rtt?.[r]
  if (measured !== undefined) return measured
  if (typeof end.lat === "number" && typeof end.lon === "number") return km([end.lat, end.lon], REGION_CENTRES[r]) * MS_PER_KM
  return undefined
}

export interface RelayPlacement {
  readonly hint: Region | undefined
  /** How it was chosen: `both` (both ends' costs), `joiner` (the joiner's hint: the peer's location unknown). */
  readonly by: "both" | "joiner"
  /** The estimated relay round trip (ms) for `both`. */
  readonly ms?: number
}

/** The relay's region for a link between `joiner` and `peer` (see the module comment). */
export const relayPlacement = (joiner: Ingress | null | undefined, peer: Ingress | null | undefined, joinerHint: DurableObjectLocationHint | undefined): RelayPlacement => {
  const fallback: RelayPlacement = { hint: joinerHint && isRegion(joinerHint) ? joinerHint : undefined, by: "joiner" }
  const scored: { r: Region; sum: number; skew: number }[] = []
  for (const r of REGIONS) {
    const a = costTo(joiner, r)
    const b = costTo(peer, r)
    if (a === undefined || b === undefined) continue
    scored.push({ r, sum: a + b, skew: Math.abs(a - b) })
  }
  if (!scored.length) return fallback
  const best = Math.min(...scored.map((s) => s.sum))
  const near = scored.filter((s) => s.sum <= best + TIE_MS)
  near.sort((x, y) => x.skew - y.skew || Number(y.r === fallback.hint) - Number(x.r === fallback.hint))
  const pick = near[0]!
  return { hint: pick.r, by: "both", ms: Math.round(pick.sum) }
}
