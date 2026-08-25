/** vNext-compatible outbound protocol message limit. */
export const MAX_OUTBOUND_MESSAGE_BYTES = 4_194_304;
/** vNext-compatible inbound protocol message limit. */
export const MAX_INBOUND_MESSAGE_BYTES = 16_777_216;
/** Current WebSocket pre-authentication frame limit. */
export const MAX_PREAUTH_MESSAGE_BYTES = 4_096;
/** Matches the server's bounded regular-message queue. */
export const MAX_PENDING_MESSAGES = 256;
/** Matches the server's bounded regular-message bytes. */
export const MAX_PENDING_BYTES = 16_777_216;

/** Maximum decoded Kitty pixel bytes retained by one render attach. */
export const RENDER_GRAPHIC_MAX_DECODED_BYTES = 10_000_000;
/** Maximum base64 characters for the decoded Kitty pixel budget. */
export const RENDER_GRAPHIC_MAX_ENCODED_CHARS =
  Math.ceil(RENDER_GRAPHIC_MAX_DECODED_BYTES / 3) * 4;
export const RENDER_GRAPHIC_MAX_IMAGES = 4_096;
export const RENDER_GRAPHIC_MAX_PLACEMENTS = 16_384;
/** Maximum encoded JSON characters accepted for a raw attach event. */
export const RENDER_ATTACH_MAX_ENCODED_CHARS = 32 * 1024 * 1024;

const encoder = new TextEncoder();

export function utf8ByteLength(value: string): number {
  return encoder.encode(value).byteLength;
}

export function positiveLimit(name: string, value: number | undefined, fallback: number): number {
  const limit = value ?? fallback;
  if (!Number.isSafeInteger(limit) || limit < 1) {
    throw new RangeError(`${name} must be a positive safe integer`);
  }
  return limit;
}
