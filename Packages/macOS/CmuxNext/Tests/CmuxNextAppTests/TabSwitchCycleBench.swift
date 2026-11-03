import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import QuartzCore
import Testing
import WebKit

/// pane-tab-switch-fast (u2327): held Ctrl-Tab over 2, 10 and 30 warm pages (each a WKWebView with a
/// running web process) in one pane, each switch timed with the rest of its turn (layout, display, the
/// commit and one run-loop pass, where a web view that re-enters a window waits for its web process).
/// Prints `TAB-SWITCH-CYCLE n=<count> p50 <ms> p90 <ms> max <ms> moves <n>`. The check is behavioral: a
/// warm switch moves no page out of the window, at every tab count (a pane once kept only 8 hidden, so
/// 10 or 30 tabs moved a view on every switch). Timing is printed, not gated (shared fleet hosts).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .closesItsWindows)
struct TabSwitchCycleBench {
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

    /// Counts window moves of the page it wraps.
    final class WindowMoves: NSView {
        var moves = 0
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            moves += 1
        }
    }

    private static let html = "<!doctype html><body style='font:16px -apple-system'>" + String(repeating: "<p>row <code>x</code> <b>bold</b></p>", count: 300)

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

    private func finishTurn(_ pane: PaneContentView, _ window: NSWindow) {
        pane.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        _ = CFRunLoopRunInMode(.defaultMode, 0, true)
    }

    @Test(arguments: [2, 10, 30])
    func warmCycleOverTabs(_ count: Int) async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        let items = (0..<count).map { TabItem(id: TabID("t\($0)"), title: "Tab \($0)") }
        let pane = PaneContentView(stripModel: TabStripModel(tabs: items), reveal: LaunchReveal(deadline: .zero))
        pane.frame = window.contentLayoutRect
        window.contentView = pane
        window.orderFrontRegardless()
        var probes: [WindowMoves] = []
        var pages: [NSView] = []
        for index in 0..<count {
            let probe = WindowMoves(frame: pane.contentHost.bounds)
            let web = await loadedWebView()
            web.frame = probe.bounds
            web.autoresizingMask = [.width, .height]
            probe.addSubview(web)
            probes.append(probe)
            pages.append(InternalPageView(key: "local-page:markdown:cycle\(index)", page: InternalPageID(rawValue: "markdown"), content: probe))
        }
        for page in pages { pane.show(page); finishTurn(pane, window) }
        let entered = probes.map(\.moves)
        var samples: [Double] = []
        for _ in 0..<max(3, 60 / count) {
            for page in pages {
                let start = CACurrentMediaTime()
                pane.show(page)
                finishTurn(pane, window)
                samples.append((CACurrentMediaTime() - start) * 1_000)
                #expect(page.window === window && !page.isHidden)
            }
        }
        let moves = zip(probes.map(\.moves), entered).reduce(0) { $0 + ($1.0 - $1.1) }
        let sorted = samples.sorted()
        let pick = { (q: Double) in sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
        print(String(format: "TAB-SWITCH-CYCLE n=%d p50 %.2f p90 %.2f max %.2f ms moves %d (switches=%d, visible=%@)",
                     count, pick(0.5), pick(0.9), sorted.last ?? 0, moves, sorted.count,
                     window.occlusionState.contains(.visible) ? "yes" : "no"))
        #expect(moves == 0, "\(moves) window moves in warm switches over \(count) pages")
    }
}
