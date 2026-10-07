/** Egress allowlist matching (pure; used by the gateway and by create/update validation). */

/**
 * Our own zones and Cloudflare's shared hosting zones (review P2, main's bypass list): a fetch
 * from our Worker to them could reach origins, buckets or services that trust our Worker's
 * identity. Never reachable, whatever the allowlist says. The allowlist stays the primary
 * control (nothing is reachable unless listed); this list only removes entries.
 */
export const DENIED_EGRESS_DOMAINS: ReadonlyArray<string> = [
  "cmux.dev",
  "cmux.com",
  "cmux.app",
  "manaflow.ai",
  "manaflow.com",
  "workers.dev",
  "pages.dev",
  "r2.dev",
  "r2.cloudflarestorage.com",
  "cloudflarestorage.com",
  // Our auth provider (sessions, project keys): automation code has no reason to call it.
  "stack-auth.com"
]
const denied = (host: string) => DENIED_EGRESS_DOMAINS.some((d) => host === d || host.endsWith(`.${d}`))

/** True when `host` (a URL hostname) matches one allowlist entry; `*.d` matches subdomains of d, never d itself. */
export const hostAllowed = (host: string, allow: ReadonlyArray<string>): boolean =>
  !denied(host) && allow.some((pattern) => (pattern.startsWith("*.") ? host.endsWith(pattern.slice(1)) && host.length > pattern.length - 1 : host === pattern))

/** An allowlist entry that names our own zones (refused at create and update). */
export const deniedPattern = (pattern: string) => denied(pattern.startsWith("*.") ? pattern.slice(2) : pattern)

