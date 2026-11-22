import logo from "./cmux-logo-dark.png?inline"

/**
 * Invite card designs (home-messaging.md section 15). Ghostty-style dark palette, no blue
 * fills; the only blue is the logo itself. Satori layout rules: every element with more than
 * one child is display:flex. Product UI in the cards is illustrative and never quotes the
 * inviter (they did not write it).
 */
export interface CardData {
  readonly first_name: string
  readonly avatar_url?: string | null
}

export type CardVariant = "conversation" | "terminal" | "minimal"
export const CARD_VARIANTS: ReadonlyArray<CardVariant> = ["conversation", "terminal", "minimal"]

const C = { bg: "#0d0e10", panel: "#16171a", raised: "#202126", line: "#26272c", fg: "#ecebe8", muted: "#8b8d93", green: "#8ec07c", yellow: "#e5c07b", magenta: "#c678dd", cyan: "#7fcfd6" }

const headline = (card: CardData | null) => (card ? `${card.first_name} invited you to chat` : "You're invited to chat on cmux")
const SUBTITLE = "Messages with people and their AI chiefs"
/** Short form for narrow columns (fits one line at 26 px in 540 px). */
const SUBTITLE_SHORT = "Chat with people and their AI chiefs"

const Brand = ({ size = 64 }: { size?: number }) => (
  <div style={{ display: "flex", alignItems: "center", gap: size * 0.28 }}>
    <img src={logo} width={size} height={size} />
    <div style={{ fontSize: size * 0.72, fontWeight: 700, letterSpacing: -1.5, color: C.fg }}>cmux</div>
  </div>
)

const Avatar = ({ card, size }: { card: CardData; size: number }) =>
  card.avatar_url ? (
    <img src={card.avatar_url} width={size} height={size} style={{ borderRadius: size / 2, objectFit: "cover", border: `4px solid ${C.line}` }} />
  ) : (
    <div style={{ width: size, height: size, borderRadius: size / 2, background: C.raised, border: `4px solid ${C.line}`, color: C.fg, fontSize: size * 0.48, fontWeight: 700, display: "flex", alignItems: "center", justifyContent: "center" }}>
      {card.first_name.slice(0, 1).toUpperCase()}
    </div>
  )

const Row = ({ dot, name, state }: { dot: string; name: string; state: string }) => (
  <div style={{ display: "flex", alignItems: "center", gap: 14, fontSize: 24, color: C.fg }}>
    <div style={{ width: 12, height: 12, borderRadius: 6, background: dot }} />
    <div style={{ display: "flex", flex: 1 }}>{name}</div>
    <div style={{ display: "flex", color: C.muted }}>{state}</div>
  </div>
)

/** A: headline on the left, a Home conversation with a Chief work card on the right. */
const Conversation = ({ card }: { card: CardData | null }) => (
  <div style={{ width: 1200, height: 630, display: "flex", padding: 64, gap: 56, background: C.bg, fontFamily: "Inter" }}>
    <div style={{ width: 540, display: "flex", flexDirection: "column", justifyContent: "space-between" }}>
      <Brand />
      <div style={{ display: "flex", flexDirection: "column", gap: 18 }}>
        {card ? <Avatar card={card} size={96} /> : null}
        <div style={{ display: "flex", fontSize: 56, fontWeight: 700, lineHeight: 1.08, letterSpacing: -1.5, color: C.fg }}>{headline(card)}</div>
        <div style={{ display: "flex", fontSize: 26, fontWeight: 500, color: C.muted }}>{SUBTITLE_SHORT}</div>
      </div>
    </div>
    <div style={{ flex: 1, display: "flex", flexDirection: "column", justifyContent: "center", gap: 16, padding: 32, background: C.panel, border: `1px solid ${C.line}`, borderRadius: 32 }}>
      <div style={{ display: "flex", fontSize: 20, color: C.muted, marginLeft: 6 }}>Chief</div>
      <div style={{ display: "flex", alignSelf: "flex-start", padding: "14px 22px", borderRadius: 24, background: C.raised, color: C.fg, fontSize: 26, fontWeight: 500 }}>3 agents finished overnight</div>
      <div style={{ display: "flex", flexDirection: "column", gap: 14, padding: 22, background: C.raised, border: `1px solid ${C.line}`, borderRadius: 22 }}>
        <Row dot={C.green} name="fix-sidebar" state="done" />
        <Row dot={C.green} name="review-pr" state="done" />
        <Row dot={C.yellow} name="ship-ios" state="running" />
      </div>
      <div style={{ display: "flex", alignSelf: "flex-end", padding: "14px 22px", borderRadius: 24, background: C.fg, color: "#111214", fontSize: 26, fontWeight: 500 }}>Nice. Ship it</div>
    </div>
  </div>
)

/** B: a cmux window (sidebar + terminal) under the headline. */
const Terminal = ({ card }: { card: CardData | null }) => (
  <div style={{ width: 1200, height: 630, display: "flex", flexDirection: "column", padding: "52px 60px", gap: 34, background: C.bg, fontFamily: "Inter" }}>
    <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
      <Brand size={56} />
      <div style={{ display: "flex", alignItems: "center", gap: 18 }}>
        {card ? <Avatar card={card} size={64} /> : null}
        <div style={{ display: "flex", fontSize: 40, fontWeight: 700, color: C.fg, letterSpacing: -0.5 }}>{headline(card)}</div>
      </div>
    </div>
    <div style={{ flex: 1, display: "flex", background: C.panel, border: `1px solid ${C.line}`, borderRadius: 24, overflow: "hidden" }}>
      <div style={{ width: 270, display: "flex", flexDirection: "column", gap: 16, padding: "28px 24px", borderRight: `1px solid ${C.line}`, fontSize: 28, color: C.muted }}>
        <div style={{ display: "flex", color: C.fg, background: C.raised, borderRadius: 10, padding: "8px 12px", margin: "0 -12px" }}>Home</div>
        <div style={{ display: "flex" }}>ship-ios</div>
        <div style={{ display: "flex" }}>review-pr</div>
        <div style={{ display: "flex" }}>fix-sidebar</div>
      </div>
      <div style={{ flex: 1, display: "flex", flexDirection: "column", gap: 12, padding: 30, fontSize: 30, color: C.muted }}>
        <div style={{ display: "flex", gap: 12 }}><span style={{ color: C.green }}>›</span><span style={{ color: C.cyan }}>cmux</span><span style={{ color: C.fg }}>agents</span></div>
        <div style={{ display: "flex", gap: 24 }}><span>fix-sidebar</span><span style={{ color: C.green }}>done</span></div>
        <div style={{ display: "flex", gap: 24 }}><span>review-pr</span><span style={{ color: C.green }}>done</span></div>
        <div style={{ display: "flex", gap: 24 }}><span>ship-ios</span><span style={{ color: C.yellow }}>running</span></div>
        <div style={{ display: "flex", marginTop: "auto", alignSelf: "flex-end", padding: "14px 24px", borderRadius: 26, background: C.fg, color: "#111214", fontSize: 30, fontWeight: 500 }}>Chief: all three shipped</div>
      </div>
    </div>
  </div>
)

/** C: centered and quiet: avatar (or the logo), headline, subtitle, one pill. */
const Minimal = ({ card, height = 630 }: { card: CardData | null; height?: number }) => {
  // The square form (1200x1200) scales the type up so it stays legible as a small tile.
  const k = height > 630 ? 1.5 : 1
  return (
    <div style={{ width: 1200, height, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 28 * k, background: `radial-gradient(900px 520px at 50% 34%, #1c1d21 0%, ${C.bg} 72%)`, fontFamily: "Inter" }}>
      {card ? (
        <div style={{ display: "flex", alignItems: "center" }}>
          <Avatar card={card} size={132 * k} />
          <img src={logo} width={92 * k} height={92 * k} style={{ marginLeft: -26 * k, marginTop: 64 * k }} />
        </div>
      ) : (
        <img src={logo} width={140 * k} height={140 * k} />
      )}
      <div style={{ display: "flex", textAlign: "center", justifyContent: "center", maxWidth: k > 1 ? 900 : 1080, fontSize: 60 * k, fontWeight: 700, letterSpacing: -1.5, lineHeight: 1.1, color: C.fg }}>{headline(card)}</div>
      <div style={{ display: "flex", fontSize: 30 * k, fontWeight: 500, color: C.muted }}>{SUBTITLE}</div>
      <div style={{ display: "flex", marginTop: 6 * k, padding: `${12 * k}px ${28 * k}px`, borderRadius: 999, border: `1px solid ${C.line}`, background: C.panel, fontSize: 24 * k, color: C.fg }}>Tap to open your invite</div>
    </div>
  )
}

export const CardFor = ({ variant, card, height = 630 }: { variant: CardVariant; card: CardData | null; height?: number }) =>
  variant === "terminal" ? <Terminal card={card} /> : variant === "minimal" ? <Minimal card={card} height={height} /> : <Conversation card={card} />
