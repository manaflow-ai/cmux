import AppKit
import Testing
@testable import CmuxNextBrowser

/// The popup window panel needs a shown tab to open over. In the ext-e2e
/// suite the last shown host had lost its tab (a moved tab was removed), so
/// the popup was closed ("adopt opener=false"). Another shown pane must do.
@MainActor @Suite struct PopupWindowOpenerTests {
    @Test func openerFallsBackToAnotherShownPane() {
        let runtime = CEFRuntime.shared
        let shown = runtime.host(for: CEFPaneKey(pane: BrowserPaneID(rawValue: "opener-shown"), profile: .default))
        let tab = CEFTab(id: .random(), profile: .default, host: shown, runtime: runtime)
        shown.add(tab)
        shown.present(tab, in: NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)))
        let empty = runtime.host(for: CEFPaneKey(pane: BrowserPaneID(rawValue: "opener-empty"), profile: .default))
        runtime.lastShownHost = empty
        #expect(runtime.popupWindowOpener() === tab)
    }
}
