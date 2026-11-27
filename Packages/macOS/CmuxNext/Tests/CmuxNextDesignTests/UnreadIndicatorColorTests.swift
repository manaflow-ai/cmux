import AppKit
@testable import CmuxNextDesign
import Testing

/// u2414 (2026-10-19): the sidebar's unread dot is the notification blue (rgb 57 130 245, sampled
/// from the Codex app). The pane's attention ring is themed (Leo, 2026-10-21: "if we have any kind
/// of blinky, it should be themed/customizable"): the theme accent unless
/// `notifications.attention.color` or the notifying source sets one, never the fixed blue.
@MainActor
struct UnreadIndicatorColorTests {
    static func rgb(_ color: CGColor) -> [Int] {
        let srgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil) ?? color
        return (srgb.components ?? []).prefix(3).map { Int(($0 * 255).rounded()) }
    }

    @Test(arguments: AttentionHighlightLook.allCases)
    func theRingDefaultsToTheThemeAccent(_ look: AttentionHighlightLook) {
        #expect(look.defaultColor == Palette.accentFill, "\(look) draws \(Self.rgb(look.defaultColor.cgColor))")
        #expect(Self.rgb(look.defaultColor.cgColor) != [57, 130, 245], "\(look) draws the fixed notification blue")
    }

    @Test func theSidebarUnreadDotIsTheNotificationBlue() {
        let colors = StatusIndicatorLayer.Colors.current(loading: nil)
        #expect(Self.rgb(colors.color(for: .unread)) == [57, 130, 245])
    }
}
