import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextTabs
import Foundation
import Testing

/// Perceived speed (#20516): closing a browser tab back to a New Tab page, or Cmd-W back to one,
/// stalled the main thread 170-215 ms with almost no CPU. The page had left the window when the
/// browser showed, and putting a WKWebView back into a window waits synchronously for WebKit's
/// web process (`waitForDidUpdateActivityState`). A pane now keeps the agent page in place,
/// hidden, as it does a browser (cx-asb1), so showing it again never re-enters the window.
@MainActor @Suite(.serialized) struct AgentPageStaysInWindowTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// Counts the times its agent page left the window.
    final class WindowProbe: NSView {
        private(set) var leftWindow = 0
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { leftWindow += 1 }
        }
    }

    @Test func aNewTabPageStaysInTheWindowWhileABrowserShows() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "stays-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.html")
        try Data("<html><body>New Tab</body></html>".utf8).write(to: file)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let pane = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("page"), title: "New Tab")]),
                                   reveal: LaunchReveal(deadline: .zero))
        pane.frame = window.contentLayoutRect
        window.contentView = pane
        window.orderFrontRegardless()

        let page = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), newTab: AgentPaneNewTab(kind: .agent)),
                                              source: .bundled(file)))
        defer { page.close() }
        let probe = WindowProbe()
        page.addSubview(probe)
        pane.show(page)
        pane.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))

        // Cmd-T into a browser, then Cmd-W back to the page.
        let chrome = BrowserChromeView(tab: WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab())
        pane.show(chrome)
        pane.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300)) // any paint hold on the browser ends
        #expect(page.window === window, "the New Tab page left the window while the browser showed")
        pane.show(page)
        pane.layoutSubtreeIfNeeded()
        #expect(probe.leftWindow == 0, "the New Tab page re-entered the window \(probe.leftWindow) time(s)")
        #expect(!page.isHidden)
        #expect(page.frame == pane.contentHost.bounds)
    }
}
