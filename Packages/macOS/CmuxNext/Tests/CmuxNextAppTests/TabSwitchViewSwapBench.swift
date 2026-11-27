import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import QuartzCore
import Testing
import WebKit

/// tab-switch-fast: the main-thread cost of a warm tab switch's view swap (`PaneContentView.show`
/// plus the layout and display of that frame) for content with a live web process, in a real
/// window: an internal page (Markdown, a file viewer) parked in the pane, the same page in a
/// wrapper that is not parkable (what every internal page did before: out of the window and back),
/// and a WebKit browser tab. Prints `TAB-SWITCH-SWAP <case> p50 <ms> p90 <ms> max <ms>`; the checks
/// are behavioral (each switch shows the tab), not timing budgets. Opt-in: `CMUX_TAB_SWITCH_BENCH=1`.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_TAB_SWITCH_BENCH"] == "1"),
                  .timeLimit(.minutes(2)), .closesItsWindows)
struct TabSwitchViewSwapBench {
    /// Not ``PaneParkableContent``: the pane takes it out of the window on a switch away.
    final class Unparked: NSView {}

    final class Loaded: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Never>?
        private func done() {
            continuation?.resume()
            continuation = nil
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { done() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { done() }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { done() }
    }

    private static let rounds = 24
    private static let html = "<!doctype html><body style='font:16px -apple-system'>" + String(repeating: "<p>row <code>x</code> <b>bold</b></p>", count: 300)

    /// A WKWebView that finished loading a page (its web process is running).
    private func loadedWebView() async -> WKWebView {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
        let loaded = Loaded()
        web.navigationDelegate = loaded
        await withCheckedContinuation { continuation in
            loaded.continuation = continuation
            web.loadHTMLString(Self.html, baseURL: nil)
        }
        web.navigationDelegate = nil
        return web
    }

    private func wrap(_ content: NSView, in host: NSView) -> NSView {
        content.frame = host.bounds
        content.autoresizingMask = [.width, .height]
        host.addSubview(content)
        return host
    }

    /// The rest of the main-thread turn after a switch: layout, display, the commit, and one run-loop pass
    /// whose exit observers run WebKit's activity-state dispatch (where a web view that comes back into a
    /// window waits synchronously for its web process).
    private func finishTurn(_ pane: PaneContentView, _ window: NSWindow) {
        pane.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        _ = CFRunLoopRunInMode(.defaultMode, 0, true)
    }

    /// Times `rounds` switches to `view` (from `other`): show, then the rest of that turn.
    private func time(_ label: String, view: NSView, other: NSView, pane: PaneContentView, window: NSWindow) -> [Double] {
        var samples: [Double] = []
        for round in 0..<(Self.rounds + 2) {
            pane.show(other)
            finishTurn(pane, window)
            let start = CACurrentMediaTime()
            pane.show(view)
            finishTurn(pane, window)
            let elapsed = (CACurrentMediaTime() - start) * 1_000
            if round >= 2 { samples.append(elapsed) } // two warm-up rounds
            #expect(view.window === window && !view.isHidden, "\(label): the switch shows the tab")
        }
        let sorted = samples.sorted()
        let pick = { (q: Double) in sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
        print(String(format: "TAB-SWITCH-SWAP %@ p50 %.2f p90 %.2f max %.2f ms (n=%d)", label, pick(0.5), pick(0.9), sorted.last ?? 0, sorted.count))
        return samples
    }

    @Test func warmSwitchViewSwap() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        let pane = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("a"), title: "A"), TabItem(id: TabID("b"), title: "B")]),
                                   reveal: LaunchReveal(deadline: .zero))
        pane.frame = window.contentLayoutRect
        window.contentView = pane
        window.orderFrontRegardless()
        let plain = NSView()
        print("TAB-SWITCH-SWAP window visible=\(window.occlusionState.contains(.visible)) screen=\(window.screen != nil)")

        let parked = InternalPageView(key: "local-page:markdown:bench", page: InternalPageID(rawValue: "markdown"), content: await loadedWebView())
        let unparked = wrap(await loadedWebView(), in: Unparked(frame: pane.contentHost.bounds))
        let browserTab = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
        defer { browserTab.close() }
        let browser = BrowserChromeView(tab: browserTab)

        let before = time("page-unparked", view: unparked, other: plain, pane: pane, window: window)
        let after = time("page-parked", view: parked, other: plain, pane: pane, window: window)
        _ = time("webkit-browser", view: browser, other: plain, pane: pane, window: window)
        _ = time("page-parked-from-browser", view: parked, other: browser, pane: pane, window: window)
        #expect(before.count == Self.rounds && after.count == Self.rounds)
    }
}
