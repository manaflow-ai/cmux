import SwiftUI

/// Visual tokens for the chat surface: colors, metrics, and type styles.
///
/// Injected through the environment so the host app can re-tint the surface
/// (and a future macOS host can supply denser metrics) without touching the
/// views.
public struct ChatTheme: Sendable, Equatable {
    /// Accent used for outgoing bubbles, actionable buttons, and the send
    /// button.
    public var accent: Color

    /// Fill for incoming (agent) prose bubbles.
    public var incomingBubbleFill: Color

    /// Foreground for monospace content on ``terminalCardFill``. Terminal
    /// cards keep a dark fill in both color schemes (terminals read as
    /// screens), so their text is a fixed light color rather than the
    /// adaptive primary.
    public var terminalCardText: Color

    /// Fill for outgoing (user) prose bubbles.
    public var outgoingBubbleFill: Color

    /// Background for terminal and diff cards; darker than bubbles so
    /// terminals read as screens in both color schemes.
    public var terminalCardFill: Color

    /// Hairline color for card borders and separators.
    public var hairline: Color

    /// Corner radius of prose bubbles.
    public var bubbleCornerRadius: CGFloat

    /// Tightened corner radius for grouped bubble inner corners.
    public var bubbleGroupedCornerRadius: CGFloat

    /// Horizontal screen margin for transcript content.
    public var horizontalMargin: CGFloat

    /// Vertical gap between bubble groups.
    public var groupSpacing: CGFloat

    /// Vertical gap between rows inside one bubble group.
    public var intraGroupSpacing: CGFloat

    /// Maximum fraction of the container width a prose bubble may take.
    public var bubbleMaxWidthFraction: CGFloat

    /// Creates a theme; defaults match the cmux dark-first design, with
    /// light-mode variants derived per surface. Terminal cards deliberately
    /// stay dark in both schemes.
    public init(
        accent: Color = .blue,
        incomingBubbleFill: Color = Color.chatAdaptive(
            light: Color(red: 0.914, green: 0.914, blue: 0.922),
            dark: Color(white: 0.16)
        ),
        terminalCardText: Color = Color(white: 0.88),
        outgoingBubbleFill: Color = .blue,
        terminalCardFill: Color = Color(white: 0.055),
        hairline: Color = Color.chatAdaptive(
            light: Color(white: 0.78),
            dark: Color(white: 0.28)
        ),
        bubbleCornerRadius: CGFloat = 18,
        bubbleGroupedCornerRadius: CGFloat = 6,
        horizontalMargin: CGFloat = 12,
        groupSpacing: CGFloat = 12,
        intraGroupSpacing: CGFloat = 5,
        bubbleMaxWidthFraction: CGFloat = 0.78
    ) {
        self.accent = accent
        self.incomingBubbleFill = incomingBubbleFill
        self.terminalCardText = terminalCardText
        self.outgoingBubbleFill = outgoingBubbleFill
        self.terminalCardFill = terminalCardFill
        self.hairline = hairline
        self.bubbleCornerRadius = bubbleCornerRadius
        self.bubbleGroupedCornerRadius = bubbleGroupedCornerRadius
        self.horizontalMargin = horizontalMargin
        self.groupSpacing = groupSpacing
        self.intraGroupSpacing = intraGroupSpacing
        self.bubbleMaxWidthFraction = bubbleMaxWidthFraction
    }
}

extension EnvironmentValues {
    /// The active chat theme; defaults to ``ChatTheme/init(accent:incomingBubbleFill:outgoingBubbleFill:terminalCardFill:hairline:bubbleCornerRadius:bubbleGroupedCornerRadius:horizontalMargin:groupSpacing:intraGroupSpacing:bubbleMaxWidthFraction:)`` defaults.
    @Entry public var chatTheme = ChatTheme()
}
