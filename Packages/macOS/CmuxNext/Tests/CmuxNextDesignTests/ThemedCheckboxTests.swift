import AppKit
@testable import CmuxNextDesign
import Testing

/// A checked box draws the theme, never macOS's blue (cx-wqn5): a native card's checkbox
/// (`ThemedCheckbox`) fills with the theme's ink, as onboarding's do, not the system accent.
@MainActor
struct ThemedCheckboxTests {
    @Test func aCheckboxIsFilledWithTheThemeNotTheAccent() throws {
        let check = ThemedCheckbox(checkboxWithTitle: "Always", target: nil, action: nil)
        check.state = .on
        check.font = Typography.body
        #expect(check.state == .on)
        let fill = try #require(check.bezelColor?.usingColorSpace(.sRGB))
        let channels = [fill.redComponent, fill.greenComponent, fill.blueComponent]
        #expect(channels.max()! - channels.min()! < 0.08)
    }
}
