/**
 * Plain URL search params for the router. TanStack Router JSON-encodes search
 * values by default, so a provider redirect such as
 * `?installation_id=167172954` came back as a number and was re-serialized as
 * `installation_id=%22167172954%22`. Provider callbacks are flat strings, so
 * the dashboard reads and writes them as plain strings.
 */
export const parseSearch = (search: string): Record<string, string> => {
  const out: Record<string, string> = {}
  for (const [k, v] of new URLSearchParams(search.startsWith("?") ? search.slice(1) : search)) out[k] = v
  return out
}

export const stringifySearch = (search: Record<string, unknown>): string => {
  const p = new URLSearchParams()
  for (const [k, v] of Object.entries(search)) if (v !== undefined && v !== null) p.set(k, String(v))
  const q = p.toString()
  return q ? `?${q}` : ""
}

const str = (v: unknown, re?: RegExp) => (typeof v === "string" && v.length > 0 && (!re || re.test(v)) ? v : undefined)

/** The provider redirect to /integrations/callback (GitHub Setup URL, Linear, Slack). */
export const callbackSearch = (s: Record<string, unknown>) => ({
  state: str(s.state),
  code: str(s.code),
  /** GitHub sends a numeric id; anything else is dropped (the API validates it again). */
  installation_id: str(s.installation_id, /^[0-9]{1,20}$/),
  setup_action: str(s.setup_action),
  error: str(s.error)
})
