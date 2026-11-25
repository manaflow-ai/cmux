import AppKit
@testable import CmuxNextMacScreen
import Testing

/// The Screen Sharing page is one labelled AX group named `macScreen.home`, so the feature-flows probe (and
/// VoiceOver) can find it; a plain NSView left the identifier out of the AX tree.
@MainActor @Suite struct MacScreenHomeAccessibilityTests {
    @Test func homeIsALabelledGroupWithItsIdentifier() {
        let home = MacScreenHomeView(host: MacScreenShareHost(), actions: MacScreenHomeActions())
        #expect(home.isAccessibilityElement())
        #expect(home.accessibilityRole() == .group)
        #expect(home.accessibilityIdentifier() == "macScreen.home")
        #expect(!(home.accessibilityLabel() ?? "").isEmpty)
    }
}
