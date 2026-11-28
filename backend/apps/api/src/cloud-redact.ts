/**
 * A runtime network error text for the machine record (review P2): the key (as given and trimmed),
 * any Bearer value and any URL are removed, so neither a secret nor an operator URL with credentials
 * reaches team members or logs.
 */
export const redactReason = (raw: string, apiKey: string): string => {
  let t = raw
  for (const k of [apiKey, apiKey.trim()]) if (k.length >= 8) t = t.split(k).join("[key]")
  return t
    .replace(/bearer\s+\S+/gi, "Bearer [key]")
    .replace(/[a-z][a-z0-9+.-]*:\/\/\S+/gi, "[url]")
    .replace(/[^\x20-\x7e]/g, "")
    .slice(0, 120)
}
