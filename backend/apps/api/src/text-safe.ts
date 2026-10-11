/**
 * Postgres text and jsonb reject U+0000 and lone UTF-16 surrogates; one such
 * outbox row fails its drain transaction forever and blocks every later row of
 * the owner. Every string (keys too) becomes well-formed, with U+0000 replaced
 * by U+FFFD. The audit chain hashes the cleaned record, so projected rows verify.
 */
export const pgSafe = (value: unknown): unknown => {
  if (typeof value === "string") return clean(value)
  if (Array.isArray(value)) return value.map(pgSafe)
  if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([k, v]) => [clean(k), pgSafe(v)]))
  return value
}

const clean = (s: string): string => {
  const wellFormed = (s as unknown as { toWellFormed(): string }).toWellFormed()
  return wellFormed.includes("\u0000") ? wellFormed.replaceAll("\u0000", "\uFFFD") : wellFormed
}
