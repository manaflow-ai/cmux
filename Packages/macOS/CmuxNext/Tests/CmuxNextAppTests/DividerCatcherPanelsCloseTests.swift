import AppKit
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// The divider catcher panels close with their window (`WindowController.teardown` -> `WindowOverlayLayer.teardown`
/// -> ``DividerMouseCatchers/teardown()``). They only left the window (`orderOut`), so a panel was never closed: it
/// stayed open as long as anything held the closed parent window. macOS 26 keeps a closed window alive past the end
/// of a test, so `ParkedPageCatcherPanelsTests`, `DividerCatcherHoldsPressTests` and `OverlayTakesThePointerTests`
/// left their panels open there (aws-m4pro-8); macOS 27 frees the window at once and hid it.
@Suite(.serialized, .closesItsWindows)
@MainActor struct DividerCatcherPanelsCloseTests {
    @Test func theTeardownClosesEveryPanel() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 800, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        let page = DividerCatcherSwitchReuseTests.page(over: window)
        defer { window.removeChildWindow(page); page.close() }
        // The catchers outlive the teardown, as a closed window that something still holds keeps its overlay layer.
        let catchers = DividerMouseCatchers(window: window)
        let a = LayoutMouseArea(id: "a", rect: CGRect(x: 200, y: 0, width: 8, height: 400), resizesColumns: true)
        let b = LayoutMouseArea(id: "b", rect: CGRect(x: 500, y: 0, width: 8, height: 400), resizesColumns: true)
        catchers.update([a, b], active: true)
        catchers.update([a], active: true)
        let panels = (window.childWindows ?? []).compactMap { $0 as? DividerMousePanel }
        try #require(panels.count == 2, "one shown panel and one parked spare: \(panels.count)")
        catchers.teardown()
        window.close()
        let open = panels.filter { !WindowLeaks.wasClosed($0) }
        #expect(open.isEmpty, "\(open.count) of \(panels.count) catcher panels stayed open after their window closed")
        #expect(catchers.windowNumbers.isEmpty)
    }
}
