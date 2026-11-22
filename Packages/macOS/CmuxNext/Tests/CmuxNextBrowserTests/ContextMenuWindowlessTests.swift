import AppKit
import Testing
@testable import CmuxNextBrowser

/// A page context menu can arrive for a tab whose view is in no window (a
/// background tab of the pane, right-clicked through CDP or by an extension
/// with chrome.debugger). NSMenu raises 'View is not in any window' for
/// such a view, which terminated the app; the request must be dismissed.
@MainActor
@Suite struct ContextMenuWindowlessTests {
    @Test func windowlessViewDismissesTheRequest() {
        var result: Int?? = .none
        let request = BrowserContextMenuRequest(
            items: [BrowserContextMenuItem(id: 1, title: "Back")], target: BrowserContextMenuTarget(),
            location: CGPoint(x: 4, y: 4)
        ) { id in result = .some(id) }
        let presenter = BrowserContextMenuBuilder()
        presenter.present(request, in: NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)))
        #expect(result == .some(nil))
    }
}
