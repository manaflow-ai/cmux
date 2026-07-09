#if canImport(AppKit)
import AppKit
import Testing

@testable import CmuxAppKitSupportUI

/// Covers the Tab Bar Backdrop Lab window shell the app forwards into
/// ``DebugWindowsCoordinator``. The lab window is transparent and floating (unlike
/// the decorated utility panels), so the controller owns no ``WindowDecorating``
/// seam; instead it mounts the app-supplied content view and applies the
/// clear-background layer treatment the original app-target controller performed.
@MainActor
@Suite struct TabBarBackdropLabWindowControllerTests {
    @Test func showBuildsTransparentFloatingPanelAndMountsContent() {
        let content = NSView()
        let controller = TabBarBackdropLabWindowController(contentProvider: { content })

        controller.show()

        let window = controller.window
        #expect(window != nil)
        #expect(window?.identifier?.rawValue == "cmux.tabBarBackdropLab")
        #expect(window?.contentView === content)
        #expect(window?.isOpaque == false)
        #expect(window?.level == .floating)
        #expect(content.wantsLayer == true)
    }
}
#endif
