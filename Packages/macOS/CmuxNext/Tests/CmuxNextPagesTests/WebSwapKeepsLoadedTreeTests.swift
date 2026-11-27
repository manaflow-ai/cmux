import Foundation
@testable import CmuxNextPages
import Testing
import WebKit

/// Leo 2026-11-07: "this updated to nightly thing also sometimes flickers". The sidebar's Updated card is a
/// WebKit page, and the every-merge web channel (the default) publishes a web update at every merge: each one
/// that arrived reloaded the card's page at the safe point (WebUpdates+SafePoint `look()`), so its words went
/// blank for a few frames and came back (cosmic-gray's nightly, 2026-11-06 20:44-21:31: eight
/// `WebPageProxy::reload` of the card's page, each a minute after a publish, each followed by the surface's
/// `data` and `height` again). The card keeps the web it loaded with until it closes; other pages still swap.
@MainActor
@Suite(.serialized)
struct WebSwapKeepsLoadedTreeTests {
    static let bundled = URL(fileURLWithPath: "/App.app/Contents/Resources/CmuxNextPages.bundle/pages/changelog", isDirectory: true)

    static func tree(_ n: Int) -> URL {
        URL(fileURLWithPath: "/Support/web-updates/trees/t\(n)", isDirectory: true).standardizedFileURL
    }

    static func page() -> WKWebView {
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 64))
        // A page with a document (`shown`): WebKit reports the requested URL from the load on.
        view.load(URLRequest(url: URL(string: "about:blank") ?? URL(fileURLWithPath: "/")))
        return view
    }

    /// The reloads one page takes over `publishes` web updates, through the safe point's own selection
    /// (``WebBundleServedViews/behind(_:)`` then ``WebBundleServedViews/reload(_:to:)``).
    static func reloads(publishes: Int, keepsCardLoaded: Bool) async -> (card: Int, other: Int, pinned: Int) {
        let overlay = WebBundleOverlay(bases: [.init(bundled: bundled.deletingLastPathComponent().path, output: WebBundleOverlay.pagesOutput)])
        let served = WebBundleServedViews()
        let card = page(), other = page()
        overlay.activate(tree(0))
        for view in [card, other] {
            served.add(view)
            _ = await served.root(for: bundled, in: view, overlay: overlay)
        }
        if keepsCardLoaded { served.keepLoadedTree(card) }
        var counts = (card: 0, other: 0)
        for n in 1...publishes {
            overlay.activate(tree(n))
            let behind = served.behind(tree(n))
            if behind.contains(card) { counts.card += 1 }
            if behind.contains(other) { counts.other += 1 }
            served.reload(behind, to: tree(n))
        }
        return (counts.card, counts.other, served.pinnedTrees.count)
    }

    @Test func aWebUpdateNeverReloadsTheUpdatedCardInPlace() async {
        let publishes = 20
        let kept = await Self.reloads(publishes: publishes, keepsCardLoaded: true)
        #expect(kept.card == 0, "the Updated card reloaded \(kept.card) times over \(publishes) web updates")
        // Every other page still takes each update at its safe point.
        #expect(kept.other == publishes)
        // The card's tree stays on disk while it is open (one tree, however many updates came).
        #expect(kept.pinned == 2)
    }

    /// The same harness without the card's keep: the count the fix removes.
    @Test func withoutTheKeepEveryWebUpdateReloadsTheCard() async {
        let publishes = 20
        let swapped = await Self.reloads(publishes: publishes, keepsCardLoaded: false)
        #expect(swapped.card == publishes)
        #expect(swapped.other == publishes)
    }
}
