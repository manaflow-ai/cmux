import AppKit
@testable import CmuxNextFloating
import Testing

/// Start Agent from Any App summons the Quick Composer over the frontmost app without activating
/// or unhiding cmux. With cmux hidden (⌘H, Hide Others), a window that hides with its app would stay
/// hidden; the panel doesn't, so it shows without bringing back every main window.
@MainActor @Suite struct QuickComposerPanelTests {
    @Test func theQuickComposerShowsWhileCmuxIsHidden() {
        let panel = QuickComposerPanel()
        #expect(!panel.canHide)
        #expect(!panel.hidesOnDeactivate)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
    }
}
