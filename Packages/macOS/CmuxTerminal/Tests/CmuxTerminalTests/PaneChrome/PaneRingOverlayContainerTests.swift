import AppKit
import Testing
import CmuxTerminalCore
@testable import CmuxTerminal

@MainActor
@Suite("PaneRingOverlayContainer")
struct PaneRingOverlayContainerTests {
    private static let presentation = TerminalPaneRingPresentation(
        red: 0,
        green: 0.5,
        blue: 1,
        alpha: 1,
        glowOpacity: 0.35,
        glowRadius: 3,
        lineWidth: 2.5,
        inset: 2,
        cornerRadius: 6
    )

    @Test("notification ring starts hidden and toggles visibility")
    func notificationRingToggles() {
        let container = PaneRingOverlayContainer(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
        container.configureNotificationRing(presentation: Self.presentation)

        #expect(container.notificationRingDebugState.isHidden == true)
        #expect(container.notificationRingDebugState.opacity == 0)

        container.setNotificationRing(visible: true)
        #expect(container.notificationRingDebugState.isHidden == false)
        #expect(container.notificationRingDebugState.opacity == 1)

        container.setNotificationRing(visible: false)
        #expect(container.notificationRingDebugState.isHidden == true)
        #expect(container.notificationRingDebugState.opacity == 0)
    }

    @Test("overlay is non-interactive (never hit-tests)")
    func overlayDoesNotHitTest() {
        let container = PaneRingOverlayContainer(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
        #expect(container.hitTest(CGPoint(x: 10, y: 10)) == nil)
        #expect(container.acceptsFirstResponder == false)
    }

    @Test("layout produces a ring path once the overlay is large enough")
    func layoutBuildsRingPath() {
        let container = PaneRingOverlayContainer(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
        container.configureNotificationRing(presentation: Self.presentation)
        container.configureFlash(presentation: Self.presentation)
        container.layoutPaneChrome(bounds: CGRect(x: 0, y: 0, width: 200, height: 120))
        // No crash and visibility state is unchanged by layout.
        #expect(container.notificationRingDebugState.isHidden == true)
    }
}
