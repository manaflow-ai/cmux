import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextBookmarks
import CmuxNextTestSupport
import Foundation
import Testing
import WebKit

/// The bookmarks bar's cost as tabs and bookmarks grow (the bar is chrome in every browser tab):
/// 200 browser tabs whose profile has 2,000 bookmarks, 50 on the bar, one tab shown in a window.
/// It times attaching every tab's bar, one bookmark change fanned out to every chrome, and showing
/// the one bar, and counts the views and web views every bar holds. It uses only what the bar's
/// owner had before and after the move to React, so the same file runs on both.
/// `scripts/ci/package-test-lane.sh suite Packages/macOS/CmuxNext BookmarksBarCostBench`; it prints
/// one `BENCH bookmarks-bar` line.
@MainActor @Suite(.serialized)
struct BookmarksBarCostBench {
    static let tabs = 200
    static let rounds = 50

    static func page() -> BrowserEntry {
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/")))
        return BrowserEntry(tab: tab)
    }

    static func tree() throws -> BookmarkTree {
        var tree = BookmarkTree()
        let url = try #require(URL(string: "https://example.com/"))
        for index in 0..<50 { try tree.apply(.create(.bookmark("Bar \(index)", url: url, in: BookmarkRoot.bar.rawValue), index: nil)) }
        let folder = BookmarkNode.folder("Archive", in: BookmarkRoot.other.rawValue)
        try tree.apply(.create(folder, index: nil))
        for index in 0..<1_949 { try tree.apply(.create(.bookmark("Saved \(index)", url: url, in: folder.id), index: nil)) }
        return tree
    }

    static func ms(_ start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    static func descendants(_ view: NSView) -> (views: Int, web: Int) {
        view.subviews.reduce((1, view is WKWebView ? 1 : 0)) { sum, child in
            let inner = descendants(child)
            return (sum.0 + inner.views, sum.1 + inner.web)
        }
    }

    @Test func barCostAsTabsAndBookmarksGrow() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let bookmarks = services.bookmarks
        let profile = BrowserProfileRecord.defaultID
        bookmarks.trees[profile] = try Self.tree()
        bookmarks.setBarShown(true)
        let entries = (0..<Self.tabs).map { _ in Self.page() }
        defer { entries.forEach { $0.close() } }

        let attachStart = ContinuousClock.now
        for entry in entries { bookmarks.attach(entry) }
        let attach = Self.ms(attachStart)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 40), styleMask: [.borderless], backing: .buffered, defer: true)
        // ARC owns the window: a close must not release it a second time.
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let shown = try #require(entries[0].state.accessory?.view)
        shown.frame = NSRect(x: 0, y: 0, width: 1200, height: 28)
        let showStart = ContinuousClock.now
        window.contentView?.addSubview(shown)
        shown.layoutSubtreeIfNeeded()
        let show = Self.ms(showStart)

        var fanOut: [Double] = []
        for _ in 0..<Self.rounds {
            let start = ContinuousClock.now
            bookmarks.changed(profiles: [profile])
            shown.layoutSubtreeIfNeeded()
            fanOut.append(Self.ms(start))
        }
        fanOut.sort()
        let p50 = fanOut[fanOut.count / 2], p95 = fanOut[fanOut.count * 95 / 100], worst = fanOut[fanOut.count - 1]
        let counts = entries.compactMap(\.state.accessory?.view).map(Self.descendants).reduce((0, 0)) { ($0.0 + $1.views, $0.1 + $1.web) }
        print(String(format: "BENCH bookmarks-bar tabs=%d bookmarks=2000 attach_ms=%.2f show_ms=%.2f change_p50_ms=%.3f change_p95_ms=%.3f change_max_ms=%.3f views=%d webviews=%d",
                     Self.tabs, attach, show, p50, p95, worst, counts.0, counts.1))
        #expect(entries.allSatisfy { $0.state.accessory != nil })
    }
}
