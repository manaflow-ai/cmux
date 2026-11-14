/// One toast design from the Toast Playground (Lawrence 2026-11-13: "we need to improve all our
/// toasts/prompts, make a swift playground for me to pick my favorite"). The pick
/// (``CmuxToastStyleStore``) is the style of every toast and prompt the app draws; ``standard`` is
/// today's look and the default until the person picks.
public nonisolated enum CmuxToastStyle: String, Sendable, CaseIterable, Hashable {
    /// Today's toast: the veil-tinted glass, the toast role's corners, a text action, rising in.
    case standard
    /// A Liquid Glass pill with round ends, clear glass, popping in.
    case capsule
    /// One short line in the caption font, tight padding.
    case compact
    /// A card with the tone's icon and the detail as a second line.
    case iconCard
    /// The primary action as an accent-filled button.
    case filledAction
    /// The close button shows only under the pointer.
    case hoverClose
    /// The close button sits in a ring that empties over the toast's time.
    case progressRing
    /// Bottom trailing corner, sliding in from the edge.
    case trailing
    /// A bar in the tone's color on the leading edge.
    case accentTinted
    /// An opaque surface, no glass, popping in.
    case solid

    /// The style's name in the playground.
    public var title: String {
        switch self {
        case .standard: "Standard (today)"
        case .capsule: "Liquid Glass capsule"
        case .compact: "Compact one-line"
        case .iconCard: "Two lines with icon"
        case .filledAction: "Filled action button"
        case .hoverClose: "Close on hover"
        case .progressRing: "Countdown ring"
        case .trailing: "Bottom trailing"
        case .accentTinted: "Accent bar"
        case .solid: "Solid, no glass"
        }
    }

    /// One line on what the style is, under its name in the playground.
    public var summary: String {
        switch self {
        case .standard: "Today's toast: veil-tinted glass, rounded corners, text action, rises from the bottom."
        case .capsule: "Clear Liquid Glass pill with round ends; grows in from 95% about its center."
        case .compact: "Caption-size text and tight padding: the least room a toast can take."
        case .iconCard: "Leading icon in the tone's color; the detail shows as a second line."
        case .filledAction: "The primary action is an accent-filled button, the rest stay quiet."
        case .hoverClose: "No close button until the pointer is on the toast: a calmer resting state."
        case .progressRing: "A ring around the close button empties as the toast's time runs out."
        case .trailing: "Rests at the bottom trailing corner, out of the work's center; slides in from the edge."
        case .accentTinted: "A bar in the tone's color on the leading edge: errors read red at a glance."
        case .solid: "Opaque theme surface, no glass: the most legible over a busy page."
        }
    }

    /// What the style draws.
    public var look: CmuxToastLook {
        var look = CmuxToastLook()
        switch self {
        case .standard: break
        case .capsule:
            look.shape = .capsule
            look.glass = .liquid
            look.entrance = .pop
        case .compact: look.compact = true
        case .iconCard:
            look.showsIcon = true
            look.showsDetailLine = true
        case .filledAction: look.fillsAction = true
        case .hoverClose: look.closeOnHover = true
        case .progressRing: look.showsCountdown = true
        case .trailing:
            look.placement = .bottomTrailing
            look.entrance = .slide
        case .accentTinted: look.accentBar = true
        case .solid:
            look.solid = true
            look.entrance = .pop
        }
        return look
    }
}
