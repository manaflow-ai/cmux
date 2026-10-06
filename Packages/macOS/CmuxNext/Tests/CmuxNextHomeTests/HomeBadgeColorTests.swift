import AppKit
@testable import CmuxHomeCore
import CmuxNextDesign
@testable import CmuxNextHome
import Testing

/// Lawrence chose iMessage blue for SENT bubbles only ("also default the
/// colors to the imessage blue bg"): the Home list's unread and mention
/// badges keep the theme's accent (`Palette.highlight`, the theme's own blue
/// slot), never MessagesLab's measured blue.
@MainActor @Suite(.serialized) struct HomeBadgeColorTests {
    private static func srgb(_ c: CGColor?) -> [CGFloat] {
        guard let c, let s = NSColor(cgColor: c)?.usingColorSpace(.sRGB) else { return [] }
        return [s.redComponent, s.greenComponent, s.blueComponent].map { ($0 * 255).rounded() }
    }

    @Test func theUnreadBadgeFollowsTheThemeAccentWhileSentBubblesStayBlue() throws {
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec("Catppuccin Mocha")!, input: HomeAccentTests.mocha, animated: false)
        let row = HomeConversationListTests.row("conv_austin", with: [HomeConversationListTests.person("user_austin", "Austin")],
                                                at: 9, unread: 2, mentions: 1)
        let (badge, mention, accent, sentIsBlue) = scope.perform { () -> ([CGFloat], [CGFloat], [CGFloat], Bool) in
            let cell = HomeConversationCellView(frame: NSRect(x: 0, y: 0, width: 280, height: 48))
            cell.show(row, me: HomeConversationListTests.me)
            return (Self.srgb(cell.badge.layer?.backgroundColor), Self.srgb(cell.mention.layer?.backgroundColor),
                    Self.srgb(Palette.highlight.cgColor), HomeThemePalette.usesMessagesBlueInScope())
        }
        #expect(badge == [0x89, 0xB4, 0xFA], "the theme's blue slot (Mocha #89B4FA), got \(badge)")
        #expect(badge == accent)
        #expect(mention == accent)
        let blue = Self.srgb(HomeThemePalette.messagesBlue.cgColor)
        #expect(badge != blue, "the badge is not MessagesLab's sent-bubble blue")
        // The sent bubble stays iMessage blue on the same theme.
        #expect(sentIsBlue, "sent bubbles are MessagesLab's measured blue on this theme")
    }
}
