#if os(iOS)
@testable import CmuxMobileFeed
import CmuxMobileModel
import Foundation
import SwiftUI
import Testing
import UIKit

/// The Feed's first scroll dropped a frame where the first permission card scrolled in: the table
/// made a new row cell and its command block and quote bubble in that frame (profile 8a637e86,
/// 10 ms of main thread). Once the Feed has been idle, scrolling makes no row cell, and a quote
/// bubble of a size already drawn is not computed again.
@MainActor
@Suite(.serialized) struct FeedScrollCellTests {
    private func settle(_ seconds: TimeInterval = 0.05) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func table(in view: UIView) -> UITableView? {
        if let table = view as? UITableView, table.accessibilityIdentifier == "feed.list" { return table }
        for sub in view.subviews { if let found = table(in: sub) { return found } }
        return nil
    }

    @Test func scrollingAfterIdleMakesNoRowCell() throws {
        let store = FeedStore.shared
        let saved = store.items
        store.replaceAll(FeedStore.stressItems(count: 120, now: Date()))
        defer { store.replaceAll(saved) }
        let screen = FeedScreen(path: .constant([])) { ToolbarItem { EmptyView() } }
            .environment(AppStore.mock())
        let host = UIHostingController(rootView: screen)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        var list: UITableView?
        for _ in 0..<100 where list == nil {
            settle()
            list = table(in: window)
        }
        let feed = try #require(list, "the Feed's table")
        // Idle: the warm-up draws each shape and makes the spare cells, one per run-loop turn.
        for _ in 0..<60 { settle() }
        let controller = try #require(feed.delegate as? FeedListController, "the Feed's controller")
        #expect(controller.sparesMade > 0, "no spare cells were made while idle")
        let made = controller.newCells
        // A slow scroll through the first 40 rows, a frame's worth at a time.
        for _ in 0..<240 {
            feed.contentOffset.y += 40
            feed.layoutIfNeeded()
            settle(0.005)
        }
        // Cells made by the provider during the scroll (spares made in idle turns are not counted).
        #expect(controller.newCells - made == 0,
                "the scroll made \(controller.newCells - made) row cells (spares made \(controller.sparesMade), taken \(controller.sparesTaken))")
    }

    @Test func aQuoteBubbleOfAKnownSizeIsNotComputedAgain() {
        let rect = CGRect(x: 0, y: 0, width: 280, height: 64)
        _ = FeedQuoteView.bubblePath(rect, outgoing: true)
        let made = FeedQuoteView.bubblesMade
        for _ in 0..<20 {
            _ = FeedQuoteView.bubblePath(rect, outgoing: true)
        }
        #expect(FeedQuoteView.bubblesMade == made)
        _ = FeedQuoteView.bubblePath(rect, outgoing: false)
        #expect(FeedQuoteView.bubblesMade == made + 1, "another side is another bubble")
    }
}
#endif
