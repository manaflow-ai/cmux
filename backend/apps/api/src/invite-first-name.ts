/** First word of a display name, for the public invite card (never a full name or an address). */
export const firstName = (name: string | undefined): string | null => {
  const first = (name ?? "").trim().split(/\s+/)[0] ?? ""
  return first.length > 0 && first.length <= 40 && !first.includes("@") ? first : null
}
