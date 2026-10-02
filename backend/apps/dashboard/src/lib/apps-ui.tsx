import type { Tier } from "./apps"

const TIER_LABEL: Record<Tier, string> = { "first-party": "First party", verified: "Verified", community: "Community", unverified: "Unverified" }

/** Review tier badge (D45). Neutral colors; unverified uses the warning color. */
export function TierBadge({ tier }: { tier: Tier }) {
  const strong = tier === "first-party" || tier === "verified"
  return (
    <span
      className="mono"
      title={tier === "unverified" ? "Not reviewed and not attested. Install only from a source you trust." : undefined}
      style={{
        display: "inline-block",
        padding: "0 6px",
        borderRadius: 4,
        border: `1px solid ${tier === "unverified" ? "var(--bad)" : "var(--line)"}`,
        color: tier === "unverified" ? "var(--bad)" : strong ? "var(--fg)" : "var(--muted)",
        fontWeight: strong ? 600 : 400,
        whiteSpace: "nowrap"
      }}
    >
      {TIER_LABEL[tier]}
    </span>
  )
}

export const appPath = (id: string) => {
  const [publisher, name] = id.split("/") as [string, string]
  return { publisher, name }
}

export const formatDate = (ms: number) => new Date(ms).toISOString().slice(0, 10)
