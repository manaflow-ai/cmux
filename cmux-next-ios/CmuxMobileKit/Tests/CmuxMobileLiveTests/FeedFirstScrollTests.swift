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

    /// The spare is filled with the heaviest row (a permission card) but the first row that needs
    /// a cell is an answer: the spare shows that answer, with no command block left from the card,
    /// and while it was parked it was nowhere in the Feed's accessibility.
    @Test func theSpareShowsTheRowThatTakesItNotTheOneItWasBuiltWith() throws {
        let store = FeedStore.shared
        let saved = store.items
        let ask = FeedStore.stressItem(index: 2, now: Date())
        guard case .permission = ask.kind else { Issue.record("stress-2 is not a permission card"); return }
        let answers = (0..<60).map { FeedStoreChurnTests.item("a\($0)", "an answer, long enough to wrap onto a second line of the Feed row", ago: Double($0) + 1) }
        store.replaceAll([ask] + answers)
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
        for _ in 0..<40 where controller.sparesMade == 0 { settle() }
        let parked = try #require(controller.parkedSpare, "no spare was built")
        #expect(parked.showsCommandBlock, "the spare was not built with the permission card")
        // Parked: not in the table, off the window, and nothing VoiceOver or a UI test reads.
        let holder = try #require(controller.parkedHolder, "the spare has no holder")
        #expect(parked.superview === holder)
        #expect(parked.accessibilityIdentifier == FeedListController.parkedSpareID, "the parked spare answers to a row's identifier")
        #expect(!parked.isDescendant(of: feed), "the parked spare is in the table")
        #expect(holder.accessibilityElementsHidden)
        #expect(!holder.isUserInteractionEnabled)
        #expect(!holder.convert(holder.bounds, to: window).intersects(window.bounds), "the parked spare is on screen")
        #expect(!feed.visibleCells.contains { $0 === parked }, "the parked spare counts as a visible row")
        for _ in 0..<60 {
            feed.contentOffset.y += 20
            feed.layoutIfNeeded()
            settle(0.005)
        }
        let given = try #require(controller.spareGiven, "the scroll did not take the spare")
        let id = given.accessibilityIdentifier ?? ""
        #expect(id.hasPrefix("feed.row.a"), "the spare shows \(id), not the answer that took it")
        #expect(!given.showsCommandBlock, "the answer that took the spare shows the card's command block")
        #expect(given.isDescendant(of: feed), "the spare is not in the table")
        // Every row on screen shows its own event.
        for cell in feed.visibleCells.compactMap({ $0 as? FeedRowCell }) {
            let rowID = String((cell.accessibilityIdentifier ?? "").dropFirst("feed.row.".count))
            let item = try #require(store.item(id: rowID), "a cell shows \(rowID), not an event of the Feed")
            if case .permission = item.kind { continue }
            #expect(!cell.showsCommandBlock, "\(rowID) shows a command block")
        }
    }
}
#endif
