#if os(iOS)
@testable import CmuxMobileFeed
import CmuxMobileModel
import Foundation
import SwiftUI
import Testing
import UIKit

/// The Feed's first scroll dropped a frame at base and head: the first row that needs a cell
/// before any cell has left the screen got a new one, built and drawn for the first time inside
/// one commit (profiles 4d3840dc/e01a6632, a permission card, ~13 ms). Once the Feed has been
/// still, that cell is a spare already built and drawn: the scroll takes it, and makes no new
/// cell before it.
@MainActor
@Suite(.serialized) struct FeedFirstScrollTests {
    private func settle(_ seconds: TimeInterval = 0.05) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func table(in view: UIView) -> UITableView? {
        if let table = view as? UITableView, table.accessibilityIdentifier == "feed.list" { return table }
        for sub in view.subviews { if let found = table(in: sub) { return found } }
        return nil
    }

    @Test func theFirstScrollTakesTheSpareNotANewCell() throws {
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
        let controller = try #require(feed.delegate as? FeedListController, "the Feed's controller")
        // Still: the spare is built once.
        for _ in 0..<40 where controller.sparesMade == 0 { settle() }
        #expect(controller.sparesMade == 1, "no spare was built while the Feed was still")
        #expect(feed.visibleCells.allSatisfy { $0.superview != nil })
        // The first scroll, a frame's worth at a time.
        for _ in 0..<120 {
            feed.contentOffset.y += 20
            feed.layoutIfNeeded()
            settle(0.005)
        }
        #expect(controller.sparesTaken == 1, "the scroll did not take the spare")
        #expect(controller.newCellsBeforeSpare == 0, "the scroll made \(controller.newCellsBeforeSpare) new cells before taking the spare")
        #expect(controller.sparesMade == 1, "a spare was built during the scroll")
    }
}
#endif
