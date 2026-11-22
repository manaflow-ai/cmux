/** Crockford base32 (the alphabet of `cmux-conversation::encode_id`), no padding. */
const CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

/** Encodes bytes as Crockford base32, most significant bit first, `chars` characters long. */
export const crockford = (bytes: Uint8Array, chars: number): string => {
  let out = ""
  let buffer = 0
  let bits = 0
  for (const byte of bytes) {
    buffer = (buffer << 8) | byte
    bits += 8
    while (bits >= 5 && out.length < chars) {
      bits -= 5
      out += CROCKFORD[(buffer >> bits) & 31]
    }
    buffer &= (1 << bits) - 1
  }
  if (out.length < chars && bits > 0) out += CROCKFORD[(buffer << (5 - bits)) & 31]
  if (out.length < chars) throw new Error(`need ${chars} base32 chars, have ${out.length}`)
  return out
}

/** True when `text` is exactly `length` Crockford base32 characters (upper case). */
export const isCrockford = (text: string, length: number): boolean =>
  text.length === length && [...text].every((c) => CROCKFORD.includes(c))
