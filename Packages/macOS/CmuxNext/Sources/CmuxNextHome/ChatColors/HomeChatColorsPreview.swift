import CmuxHomeRender
import CmuxNextDesign
import CmuxNextHomeModel
import Foundation

/// The colours a chat draws with for a choice (its bubble style, the default for every chat, then
/// the chat's own colours): the Chat Colors panel's preview and a colour well's starting colour.
struct HomeChatColorsPreview: Hashable, Sendable {
    /// One side's bubble: its fill and its text.
    struct Pair: Hashable, Sendable {
        let fill: HomeColor
        let text: HomeColor
    }

    /// The chat's page colour (opaque).
    let background: HomeColor
    let sent: Pair
    let received: Pair

    init(_ palette: HomePalette) {
        let page = palette.background
        background = HomeColor(red: page.red, green: page.green, blue: page.blue)
        sent = Pair(fill: palette.outgoingGradient.first?.color ?? palette.caret, text: palette.outgoingText)
        received = Pair(fill: palette.incomingBubble, text: palette.incomingText)
    }

    /// The colours `chosen` draws with under `design`'s bubble style and default for every chat.
    /// Callers run inside `performWithTheme` (theme-scoped), as the transcript does.
    /// - Parameters:
    ///   - chosen: the chat's own colours.
    ///   - design: the settings the bubble style and the default for every chat come from.
    /// - Returns: the resolved colours.
    @MainActor
    static func resolveInScope(_ chosen: HomeBubbleColors, design: DesignSettings) -> HomeChatColorsPreview { // theme-scoped
        let style: HomePalette.BubbleStyle = design.homeChiefBubblesThemed ? .theme : .iMessage
        let all = HomeChatColorStore.colors(fromHexes: design.homeBubbleColors)
        return HomeChatColorsPreview(HomeThemePalette.resolveInScope(active: true, style: style).applying(chosen.over(all)))
    }
}
