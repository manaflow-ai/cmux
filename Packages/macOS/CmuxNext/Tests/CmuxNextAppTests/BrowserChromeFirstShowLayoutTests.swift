import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Relaunch after an update (Leo 2026-11-04: "the restarted after nightly update does too many layout shifts/flicker
/// renderings"): a restored browser tab showed its pane without the toolbar for 100-400 ms, then the address bar and
/// buttons popped in. The pane already had its final size when the chrome arrived, so its layout found the host
/// unchanged and the content at the host's bounds (`install` set them), and skipped the forced layout a chrome needs;
/// the toolbar stayed at its init frames (zero) until the page's host view asked for layout.
@MainActor @Suite(.serialized, .closesItsWindows) struct BrowserChromeFirstShowLayoutTests {
    /// How the chrome arrives in a pane that already has its size: `fresh` never laid out; `laidOutAtZero` laid out once
    /// while still at its zero init frame (its subviews solved at 0x0, as when it is bound before it is installed);
    /// `hidden` while the window is not on screen yet (a relaunch shows the window after its content).
    enum Arrival: CaseIterable { case fresh, laidOutAtZero, hiddenWindow, hiddenLaidOutAtZero }

    @Test(arguments: Arrival.allCases)
    func aChromeShownInAnAlreadySizedPaneIsLaidOutInTheWindowsNextPass(_ arrival: Arrival) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let pane = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("browser"), title: "Example")]),
                                   reveal: LaunchReveal(deadline: .zero))
        pane.barOrder = .aboveToolbar
        pane.frame = window.contentLayoutRect
        window.contentView = pane
        let hidden = arrival == .hiddenWindow || arrival == .hiddenLaidOutAtZero
        if !hidden { window.orderFrontRegardless() }
        let page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
        defer {
            window.orderOut(nil)
            window.close()
            page.close()
        }
        // The pane at its final size before any content, as on relaunch.
        pane.layoutSubtreeIfNeeded()
        let chrome = pane.browserChrome.bind(page, state: BrowserChromeTabState())
        if arrival == .laidOutAtZero || arrival == .hiddenLaidOutAtZero { chrome.layoutSubtreeIfNeeded() }
        pane.show(chrome)
        if hidden { window.orderFrontRegardless() }
        // Only the window's own pass, what runs before the next frame: no layout of the pane or the chrome by hand.
        window.displayIfNeeded()
        #expect(chrome.frame.width > 0, "the chrome takes the pane's content area")
        #expect(chrome.toolbar.frame.height == chrome.currentToolbarHeight, "the toolbar has its height in the first frame")
        #expect(chrome.addressBar.frame.width > 0, "the address bar is laid out in the first frame, not at zero size")
        #expect(abs(chrome.contentContainer.frame.height - (chrome.bounds.height - chrome.toolbar.frame.height)) <= 1,
                "the page area fills the chrome under the toolbar")
    }
}
