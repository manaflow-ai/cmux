import AppKit
@testable import CmuxNextBrowser
import Testing

/// A Chromium window created for a pane no one has seen (an agent's
/// background tab, a pane under the Home page) starts at the hidden-tab
/// viewport, not at the host view's empty bounds. Before, it started at 1x1:
/// the page had a 0x0 viewport, every locator.click timed out (element is
/// not in the viewport) and Page.captureScreenshot never answered.
struct CEFHiddenWindowSizeTests {
    @Test func aNeverLaidOutHostStartsAtTheHiddenTabViewport() {
        #expect(CEFPaneHost.creationSize(for: .zero) == CEFPaneHost.hiddenTabViewport)
        #expect(CEFPaneHost.creationSize(for: NSSize(width: 0, height: 600)) == CEFPaneHost.hiddenTabViewport)
        #expect(CEFPaneHost.hiddenTabViewport == NSSize(width: 1280, height: 800))
    }

    @Test func aShownHostKeepsItsOwnSize() {
        #expect(CEFPaneHost.creationSize(for: NSSize(width: 900, height: 500)) == NSSize(width: 900, height: 500))
    }
}
