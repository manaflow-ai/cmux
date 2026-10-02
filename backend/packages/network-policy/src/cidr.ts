/** Minimal IPv4/IPv6 CIDR handling (no Node APIs, so it runs in workerd). */

interface Net {
  readonly v6: boolean
  readonly addr: bigint
  readonly prefix: number
}

const parseV4 = (s: string): bigint | null => {
  const parts = s.split(".")
  if (parts.length !== 4) return null
  let v = 0n
  for (const p of parts) {
    if (!/^\d{1,3}$/.test(p) || Number(p) > 255 || (p.length > 1 && p.startsWith("0"))) return null
    v = (v << 8n) | BigInt(Number(p))
  }
  return v
}

const parseV6 = (s: string): bigint | null => {
  if (!/^[0-9a-fA-F:.]+$/.test(s)) return null
  const halves = s.split("::")
  if (halves.length > 2) return null
  const groups = (h: string) => (h === "" ? [] : h.split(":"))
  const head = groups(halves[0]!)
  const tail = halves.length === 2 ? groups(halves[1]!) : []
  // An embedded IPv4 tail counts as two groups.
  const expand = (gs: Array<string>): Array<number> | null => {
    const out: Array<number> = []
    for (let i = 0; i < gs.length; i++) {
      const g = gs[i]!
      if (i === gs.length - 1 && g.includes(".")) {
        const v4 = parseV4(g)
        if (v4 === null) return null
        out.push(Number(v4 >> 16n), Number(v4 & 0xffffn))
      } else {
        if (!/^[0-9a-fA-F]{1,4}$/.test(g)) return null
        out.push(parseInt(g, 16))
      }
    }
    return out
  }
  const h = expand(head)
  const t = expand(tail)
  if (!h || !t) return null
  const missing = 8 - h.length - t.length
  if (halves.length === 1 ? missing !== 0 : missing < 1) return null
  const all = [...h, ...Array<number>(halves.length === 1 ? 0 : missing).fill(0), ...t]
  return all.reduce((acc, g) => (acc << 16n) | BigInt(g), 0n)
}

const parseNet = (text: string): Net | null => {
  const [addrText, prefixText, extra] = text.split("/")
  if (extra !== undefined || addrText === undefined) return null
  const v4 = parseV4(addrText)
  const v6 = v4 === null ? parseV6(addrText) : null
  if (v4 === null && v6 === null) return null
  const max = v4 !== null ? 32 : 128
  let prefix = max
  if (prefixText !== undefined) {
    if (!/^\d{1,3}$/.test(prefixText)) return null
    prefix = Number(prefixText)
    if (prefix > max) return null
  }
  const addr = (v4 ?? v6)!
  const mask = prefix === 0 ? 0n : ((1n << BigInt(prefix)) - 1n) << BigInt(max - prefix)
  return { v6: v4 === null, addr: addr & mask, prefix }
}

export const isCidrOrAddress = (text: string): boolean => parseNet(text) !== null

const formatV4 = (v: bigint) => [24n, 16n, 8n, 0n].map((s) => String(Number((v >> s) & 0xffn))).join(".")

const formatV6 = (v: bigint) => {
  const groups = Array.from({ length: 8 }, (_, i) => Number((v >> BigInt(112 - 16 * i)) & 0xffffn))
  // Compress the longest run of zero groups (RFC 5952).
  let best = -1
  let bestLen = 0
  for (let i = 0; i < 8; ) {
    if (groups[i] !== 0) {
      i++
      continue
    }
    let j = i
    while (j < 8 && groups[j] === 0) j++
    if (j - i > bestLen && j - i > 1) {
      best = i
      bestLen = j - i
    }
    i = j
  }
  const hex = groups.map((g) => g.toString(16))
  if (best < 0) return hex.join(":")
  return `${hex.slice(0, best).join(":")}::${hex.slice(best + bestLen).join(":")}`
}

/** Canonical `network/prefix` (a bare address becomes /32 or /128). Throws on invalid input. */
export const normalizeCidr = (text: string): string => {
  const n = parseNet(text)
  if (!n) throw new Error(`invalid CIDR ${text}`)
  return `${n.v6 ? formatV6(n.addr) : formatV4(n.addr)}/${n.prefix}`
}

/** True when `inner` (address or CIDR) lies entirely inside `outer`. */
export const cidrContains = (outer: string, inner: string): boolean => {
  const o = parseNet(outer)
  const i = parseNet(inner)
  if (!o || !i || o.v6 !== i.v6 || i.prefix < o.prefix) return false
  const max = o.v6 ? 128 : 32
  const mask = o.prefix === 0 ? 0n : ((1n << BigInt(o.prefix)) - 1n) << BigInt(max - o.prefix)
  return (i.addr & mask) === o.addr
}
