#if os(iOS)
@testable import CmuxMobileFeed
import CmuxMobileDesign
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

    /// The warm-up draws the Feed's row shapes when it comes to rest, a frame's share at a time: it
    /// ran its whole queue back to back (74 ms of one frame, profile db0af69e). Each item costs
    /// 3 ms on a fake clock, so the count between two display frames is the budget's, not timing's.
    @Test func theWarmUpTakesAFramesShareAtATime() async throws {
        let store = FeedStore.shared
        let saved = store.items
        store.replaceAll([])
        defer { store.replaceAll(saved) }
        let screen = FeedScreen(path: .constant([])) { ToolbarItem { EmptyView() } }
            .environment(AppStore.mock())
        let host = UIHostingController(rootView: screen)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        // Waits by suspending, not by spinning the run loop inside this test's main-actor job: the
        // list's own waits are main-actor tasks (its 150 ms settle after a scroll event, the warm-up's
        // retry while not settled), and they cannot run until this job lets the main actor go
        // (green-25 34faf23e: spinning, the list never settled and the warm-up drew 0 items).
        func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        var list: UITableView?
        for _ in 0..<100 where list == nil {
            await pause(0.05)
            list = table(in: window)
        }
        let feed = try #require(list, "the Feed's table")
        let controller = try #require(feed.delegate as? FeedListController, "the Feed's controller")
        var now: CFTimeInterval = 1000
        controller.warmClock = { now }
        controller.warmItemHook = { now += 0.003 }
        // Items done between display frames.
        var lastDone = controller.warmItemsDone
        var perFrame: [Int] = []
        var ticks = 0
        let token = FrameClock.shared.subscribe { _ in
            ticks += 1
            perFrame.append(controller.warmItemsDone - lastDone)
            lastDone = controller.warmItemsDone
        }
        defer { FrameClock.shared.unsubscribe(token) }
        // Many row shapes at once: the warm-up queues one item per new shape.
        store.replaceAll(FeedStore.stressItems(count: 120, now: Date()))
        let queued = controller.warmQueueCount
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, controller.warmQueueCount > 0 || controller.warmItemsDone == 0 { await pause(0.02) }
        await pause(0.1)
        let state = "queued \(queued), done \(controller.warmItemsDone), left \(controller.warmQueueCount), passes \(controller.warmBatches), frames \(ticks), settled \(controller.rowsSettled)"
        let budgetItems = Int(FeedListController.warmBudget / 0.003) + 1
        // Enough items that the budget has to split them over frames, and frames to count them in:
        // otherwise the check below passes with nothing measured.
        #expect(controller.warmItemsDone > budgetItems * 2, "too few warm-up items to tell: \(state)")
        #expect(ticks > 3, "too few display frames to count in: \(state)")
        #expect((perFrame.max() ?? 0) <= budgetItems,
                "\(perFrame.max() ?? 0) warm-up items ran in one frame (at most \(budgetItems)): \(perFrame.filter { $0 > 0 }); \(state)")
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
