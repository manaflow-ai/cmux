/** Egress allowlist matching (pure; used by the gateway and by create/update validation). */

/**
 * Our own zones (review P2): a fetch from our Worker to them could reach origins or services
 * that trust our Worker's identity. Never reachable, whatever the allowlist says.
 */
export const DENIED_EGRESS_DOMAINS: ReadonlyArray<string> = ["cmux.dev", "cmux.com", "workers.dev"]
const denied = (host: string) => DENIED_EGRESS_DOMAINS.some((d) => host === d || host.endsWith(`.${d}`))

/** True when `host` (a URL hostname) matches one allowlist entry; `*.d` matches subdomains of d, never d itself. */
export const hostAllowed = (host: string, allow: ReadonlyArray<string>): boolean =>
  !denied(host) && allow.some((pattern) => (pattern.startsWith("*.") ? host.endsWith(pattern.slice(1)) && host.length > pattern.length - 1 : host === pattern))

/** An allowlist entry that names our own zones (refused at create and update). */
export const deniedPattern = (pattern: string) => denied(pattern.startsWith("*.") ? pattern.slice(2) : pattern)

