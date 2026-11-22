import AppKit
@testable import CmuxNextPalette

extension PaletteController {
    /// A test's teardown: hides the palette and closes its panel. `hide()` only orders the panel
    /// out (the app reuses it for every open), so a test that stopped there left it open for the
    /// suites after it (`.closesItsWindows`).
    func closeForTest() {
        hide()
        for window in NSApp?.windows ?? [] where owns(window) {
            window.isReleasedWhenClosed = false
            window.close()
        }
    }
}
