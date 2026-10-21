import AppKit
@testable import CmuxNextDesign
import Testing

/// u2414 (2026-10-19): "make it the same blue as the notification blue by default". The pane's
/// unread ring and the sidebar's unread dot draw one color, the notification blue (rgb 57 130 245,
/// sampled from the Codex app), unless `notifications.attention.color` or the notifying source
/// sets one.
@MainActor
struct UnreadIndicatorColorTests {
    static func rgb(_ color: CGColor) -> [Int] {
        let srgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil) ?? color
        return (srgb.components ?? []).prefix(3).map { Int(($0 * 255).rounded()) }
    }

    @Test(arguments: AttentionHighlightLook.allCases)
    func theRingDefaultsToTheNotificationBlue(_ look: AttentionHighlightLook) {
        #expect(Self.rgb(look.defaultColor.cgColor) == [57, 130, 245], "\(look) draws \(Self.rgb(look.defaultColor.cgColor))")
    }

    @Test func theSidebarUnreadDotIsTheSameBlue() {
        let colors = StatusIndicatorLayer.Colors.current(loading: nil)
        #expect(Self.rgb(colors.color(for: .unread)) == Self.rgb(AttentionHighlightLook.subtle.defaultColor.cgColor))
    }
}
