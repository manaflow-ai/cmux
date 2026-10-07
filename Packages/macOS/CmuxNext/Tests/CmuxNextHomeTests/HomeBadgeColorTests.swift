import AppKit
@testable import CmuxHomeCore
import CmuxNextDesign
@testable import CmuxNextHome
import Testing

/// Lawrence chose iMessage blue for SENT bubbles only ("also default the
/// colors to the imessage blue bg"): the Home list's unread and mention
/// badges use the neutral app accent (`Palette.accent`, resolved in the
/// row's theme scope; Lawrence 2026-10-06), never a blue.
@MainActor @Suite(.serialized) struct HomeBadgeColorTests {
    private static func srgb(_ c: CGColor?) -> [CGFloat] {
        guard let c, let s = NSColor(cgColor: c)?.usingColorSpace(.sRGB) else { return [] }
        return [s.redComponent, s.greenComponent, s.blueComponent].map { ($0 * 255).rounded() }
    }

    @Test func theUnreadBadgeFollowsTheThemeAccentWhileSentBubblesStayBlue() throws {
        let row = HomeConversationListTests.row("conv_austin", with: [HomeConversationListTests.person("user_austin", "Austin")],
                                                at: 9, unread: 2, mentions: 1)
        let cell = HomeConversationCellView(frame: NSRect(x: 0, y: 0, width: 280, height: 48))
        cell.show(row, me: HomeConversationListTests.me)
        let accent = cell.performWithTheme { Self.srgb(Palette.accent.cgColor) }
        let themeBlue = cell.performWithTheme { Self.srgb(Palette.highlight.cgColor) }
        let badge = Self.srgb(cell.badge.layer?.backgroundColor), mention = Self.srgb(cell.mention.layer?.backgroundColor)
        #expect(!accent.isEmpty && badge == accent, "the badge is the theme accent \(accent), got \(badge)")
        #expect(mention == accent)
        #expect(badge != Self.srgb(HomeThemePalette.messagesBlue.cgColor), "the badge is not MessagesLab's sent-bubble blue")
        #expect(accent == themeBlue || badge != themeBlue, "the badge is not the theme's blue slot")
        // The sent bubble stays iMessage blue in the same scope.
        #expect(cell.performWithTheme { HomeThemePalette.usesMessagesBlueInScope() })
    }
}
