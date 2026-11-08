const UTF8_ENCODER = new TextEncoder();
const HAS_NON_WHITESPACE = /\P{White_Space}/u;
const HAS_CONTROL = /\p{Cc}/u;

/** Returns true only for well-formed Unicode strings inside the UTF-8 byte bounds. */
export function hasUtf8ByteLength(
  value: unknown,
  minimum: number,
  maximum: number,
): value is string {
  if (typeof value !== "string" || !isWellFormedUnicode(value)) return false;
  const bytes = UTF8_ENCODER.encode(value).byteLength;
  return bytes >= minimum && bytes <= maximum;
}

export function isValidIdempotencyKey(value: unknown): value is string {
  return hasUtf8ByteLength(value, 1, 128)
    && HAS_NON_WHITESPACE.test(value)
    && !HAS_CONTROL.test(value);
}

function isWellFormedUnicode(value: string): boolean {
  for (const scalar of value) {
    const codePoint = scalar.codePointAt(0)!;
    if (codePoint >= 0xd800 && codePoint <= 0xdfff) return false;
  }
  return true;
}
