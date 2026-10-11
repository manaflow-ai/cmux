import { PUBLIC_SUFFIX_RULES } from "./public-suffix-data.ts"

/**
 * Public Suffix List matching (https://publicsuffix.org/list/, algorithm
 * section). A team may claim only a registrable domain or a name below one:
 * never a public suffix (co.uk, github.io), or one claim could route every
 * site under that suffix to the team's IdP.
 */
let rules: { exact: Set<string>; wildcard: Set<string>; exception: Set<string> } | undefined
const load = () => {
  if (rules) return rules
  rules = { exact: new Set(), wildcard: new Set(), exception: new Set() }
  for (const r of PUBLIC_SUFFIX_RULES.split("\n")) {
    if (r.startsWith("!")) rules.exception.add(r.slice(1))
    else if (r.startsWith("*.")) rules.wildcard.add(r.slice(2))
    else rules.exact.add(r)
  }
  return rules
}

/** The public suffix of `domain` (the default rule "*" makes the last label one). */
export const publicSuffix = (domain: string): string => {
  const r = load()
  const labels = domain.split(".")
  for (let i = 0; i < labels.length; i++) {
    const candidate = labels.slice(i).join(".")
    if (r.exception.has(candidate)) return labels.slice(i + 1).join(".")
    if (r.exact.has(candidate)) return candidate
    const parent = labels.slice(i + 1).join(".")
    if (i + 1 < labels.length && r.wildcard.has(parent)) return candidate
  }
  return labels[labels.length - 1]!
}

/** True when `domain` is itself a public suffix (nothing registrable). */
export const isPublicSuffix = (domain: string): boolean => publicSuffix(domain) === domain

/** The registrable domain: the public suffix plus one label, or undefined for a suffix. */
export const registrableDomain = (domain: string): string | undefined => {
  const suffix = publicSuffix(domain)
  if (suffix === domain) return undefined
  const labels = domain.split(".")
  return labels.slice(labels.length - suffix.split(".").length - 1).join(".")
}
