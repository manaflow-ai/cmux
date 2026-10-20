const MAX_REQUEST_TIMEOUT_MS = 0x7fff_ffff;

/** Validates a command acknowledgement timeout accepted by JavaScript timers. */
export function validateRequestTimeout(timeoutMs: number): number {
  if (
    !Number.isFinite(timeoutMs)
    || timeoutMs < 0
    || timeoutMs > MAX_REQUEST_TIMEOUT_MS
  ) {
    throw new TypeError("timeoutMs must be between 0 and 2147483647");
  }
  return timeoutMs;
}
