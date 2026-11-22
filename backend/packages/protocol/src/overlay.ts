/**
 * Overlay addresses (plans/cmux-next/transport.md 3.1): `fd7c:6d78::/32` plus the first 96 bits of
 * SHA-256 of the install or host id. The same derivation as cmux-tui/crates/cmux-link/src/overlay_addr.rs
 * (that crate is Rust, so it cannot be imported here); the shared reference values live in the tests
 * of both. RFC 5952 text form, as Rust's Ipv6Addr Display prints it.
 */
export const OVERLAY_PREFIX: ReadonlyArray<number> = [0xfd, 0x7c, 0x6d, 0x78]

export const overlayAddress = async (id: string): Promise<string> => {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(id)))
  const bytes = [...OVERLAY_PREFIX, ...digest.slice(0, 12)]
  const groups = Array.from({ length: 8 }, (_, i) => (bytes[2 * i]! << 8) | bytes[2 * i + 1]!)
  // RFC 5952: the longest run of two or more zero groups (the first on a tie) becomes "::".
  let best = { start: -1, len: 0 }
  for (let i = 0; i < 8; ) {
    if (groups[i] !== 0) {
      i++
      continue
    }
    let j = i
    while (j < 8 && groups[j] === 0) j++
    if (j - i > best.len && j - i >= 2) best = { start: i, len: j - i }
    i = j
  }
  const hex = groups.map((g) => g.toString(16))
  if (best.start < 0) return hex.join(":")
  return `${hex.slice(0, best.start).join(":")}::${hex.slice(best.start + best.len).join(":")}`
}
