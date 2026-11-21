#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileWorkspaces

/// A busy Mac's changes reach the Workspaces list as many model updates in one turn of the main
/// run loop. The list applies them once per turn, redraws only the rows whose value changed, and
/// for a model updated from the shown one compares only its changed items, not every section and
/// row (WS-9). A change that removes rows above the one being read keeps that row in place.
@MainActor
@Suite(.serialized) struct WorkspacesApplyPerFrameTests {
    struct Host {
        let window: UIWindow
        let list: WorkspacesListController
        let view: WorkspacesCollectionView
        let actions: WorkspacesCollectionActions
    }

    static let now = Date(timeIntervalSince1970: 2_000_000_000)

    static func row(_ index: Int, title: String? = nil) -> WorkspacesListItem {
        let ws = Workspace(id: "w\(index)", macID: "mac-1", title: title ?? "agent \(index)", directory: "~/p\(index)",
                           branch: "main", tabs: [], lastActivityAt: now)
        return .row(WorkspaceRowModel(workspace: ws, status: .idle, isStale: false, tracksMacData: false, canManage: true,
                                      canArrange: true, canDuplicate: true, canMoveUp: false, canMoveDown: false))
    }

    static func model(_ count: Int, titles: [Int: String] = [:], version: Int = 0) -> WorkspacesListModel {
        var model = WorkspacesListModel()
        let ids = (0..<count).map { WorkspacesListModel.rowID("w\($0)") }
        model.sections = [ListSectionIDs(id: "recent", items: ids)]
        for index in 0..<count { model.items[ids[index]] = row(index, title: titles[index]) }
        model.version = version
        return model
    }

    private func host() -> Host {
        let store = AppStore.mock()
        let creator = WorkspaceCreator(store: store, backend: MockWorkspaceCreationBackend(latency: .zero))
        let owner = WorkspacesList(store: store, creator: creator, open: { _ in })
        let list = WorkspacesListController(control: WorkspacesListControl())
        let view = list.makeView()
        let screen = UIViewController()
        view.frame = screen.view.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        screen.view.addSubview(view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = screen
        window.makeKeyAndVisible()
        let actions = WorkspacesCollectionActions(
            row: { model in WorkspaceListRow(model: model, host: owner).equatable() },
            content: { _, _ in AnyView(EmptyView()) },
            menu: { _, _ in nil },
            swipe: { _, _ in nil },
            refresh: nil
        )
        return Host(window: window, list: list, view: view, actions: actions)
    }

    /// Lets the main run loop turn (the list applies at the end of the turn its updates came in).
    private func turn() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    @Test func manyUpdatesInOneTurnAreOneApplyRedrawingTheChangedRowsAlone() {
        let host = host()
        defer { host.window.isHidden = true }
        host.list.update(model: Self.model(200), actions: host.actions, animated: false, membershipKey: 0)
        turn()
        host.view.layoutIfNeeded()
        let passes = host.list.applyPasses, snapshots = host.list.applyCount, redrawn = host.list.reconfigureCount
        // 30 publications in one turn, touching rows 1, 2 and 3 over and over.
        var titles: [Int: String] = [:]
        for round in 0..<30 {
            titles[1 + round % 3] = "agent \(1 + round % 3) r\(round)"
            host.list.update(model: Self.model(200, titles: titles), actions: host.actions, animated: false, membershipKey: 0)
        }
        turn()
        #expect(host.list.applyPasses == passes + 1, "\(host.list.applyPasses - passes) applies for one turn's updates")
        #expect(host.list.applyCount == snapshots, "a content change applied a snapshot")
        #expect(Set(host.list.lastReconfigured) == ["ws.w1", "ws.w2", "ws.w3"], "redrew \(host.list.lastReconfigured)")
        #expect(host.list.reconfigureCount - redrawn == 3)
    }

    /// Models updated from the shown one (the list's patch path): the changed items alone are
    /// compared and redrawn, chained over several updates in one turn.
    @Test func patchedModelsApplyTheirChangedItemsAlone() {
        let host = host()
        defer { host.window.isHidden = true }
        host.list.update(model: Self.model(200, version: 1), actions: host.actions, animated: false, membershipKey: 0)
        turn()
        host.view.layoutIfNeeded()
        let patched = host.list.patchedApplyCount
        var second = Self.model(200, titles: [4: "four"], version: 2)
        second.patchedFrom = 1
        second.patchedItems = ["ws.w4"]
        var third = Self.model(200, titles: [4: "four", 6: "six"], version: 3)
        third.patchedFrom = 2
        third.patchedItems = ["ws.w6"]
        host.list.update(model: second, actions: host.actions, animated: false, membershipKey: 0)
        host.list.update(model: third, actions: host.actions, animated: false, membershipKey: 0)
        turn()
        #expect(host.list.patchedApplyCount == patched + 1)
        #expect(Set(host.list.lastReconfigured) == ["ws.w4", "ws.w6"])
        // A model not built from the shown one compares the whole list again.
        host.list.update(model: Self.model(200, titles: [4: "four", 6: "six", 8: "eight"], version: 9),
                         actions: host.actions, animated: false, membershipKey: 0)
        turn()
        #expect(host.list.patchedApplyCount == patched + 1)
        #expect(host.list.lastReconfigured == ["ws.w8"])
    }

    /// An active workspace jumps to the top on every tick (the normal live case): a model patched
    /// with that one move applies one move, not a new snapshot of every row.
    @Test func aRowMovedToTheTopIsOneMove() {
        let host = host()
        defer { host.window.isHidden = true }
        host.list.update(model: Self.model(300, version: 1), actions: host.actions, animated: false, membershipKey: 0)
        turn()
        host.view.layoutIfNeeded()
        let moves = host.list.movedApplyCount
        var next = Self.model(300, titles: [150: "jumped"], version: 2)
        var order = next.sections[0].items
        let key = WorkspacesListModel.rowID("w150")
        order.removeAll { $0 == key }
        order.insert(key, at: 0)
        next.sections[0].items = order
        next.patchedFrom = 1
        next.patchedItems = [key]
        next.patchedMoves = [key]
        host.list.update(model: next, actions: host.actions, animated: false, membershipKey: 0)
        turn()
        #expect(host.list.movedApplyCount == moves + 1, "the move rebuilt the list")
        #expect(host.list.shownItemIDs(inSection: "recent") == order, "the list's order is the model's")
        #expect(host.list.lastReconfigured == [key])
    }

    /// A busy row jumps to the top on every tick while the person scrolls: no move is applied
    /// during the scroll (the rows update in place), then one apply at rest leaves the list in
    /// the order a live apply would have shown, the row being read in place.
    @Test func reordersWhileScrollingWaitForRestThenApplyOnce() throws {
        let host = host()
        defer {
            host.window.isHidden = true
            ListApplyProbe.shared.codeDrivenScroll = false
        }
        host.list.update(model: Self.model(300, version: 1), actions: host.actions, animated: false, membershipKey: 0)
        turn()
        host.view.layoutIfNeeded()
        host.view.contentOffset.y = 3000
        host.view.layoutIfNeeded()
        ListApplyProbe.shared.codeDrivenScroll = true
        let moves = host.list.movedApplyCount, snapshots = host.list.applyCount
        var order = Self.model(300).sections[0].items
        var titles: [Int: String] = [:]
        var version = 1
        for tick in 0..<12 {
            // The scroll moves on (a frame of the rig's scroll), then a tick's row jumps up.
            host.view.contentOffset.y += 6
            let row = 40 + tick * 17
            let key = WorkspacesListModel.rowID("w\(row)")
            titles[row] = "busy \(tick)"
            order.removeAll { $0 == key }
            order.insert(key, at: 0)
            var next = Self.model(300, titles: titles, version: version + 1)
            next.sections[0].items = order
            next.patchedFrom = version
            next.patchedItems = [key]
            next.patchedMoves = [key]
            version += 1
            host.list.update(model: next, actions: host.actions, animated: false, membershipKey: 0)
            turn()
        }
        #expect(host.list.movedApplyCount == moves, "a move applied while scrolling")
        #expect(host.list.applyCount == snapshots)
        #expect(host.list.deferredReorderCount >= 12)
        #expect(host.list.shownItemIDs(inSection: "recent") == Self.model(300).sections[0].items,
                "the shown order changed during the scroll")
        let anchor = try #require(host.list.readingAnchor()?.ids.first)
        // The scroll rests: the moving window passes with no new offset.
        RunLoop.current.run(until: Date().addingTimeInterval(WorkspacesListController.movingWindow + 0.2))
        host.view.layoutIfNeeded()
        #expect(host.list.restedApplyCount == 1, "one apply at rest")
        #expect(host.list.applyCount == snapshots + 1)
        #expect(host.list.shownItemIDs(inSection: "recent") == order, "the order a live apply shows")
        let after = try #require(host.list.readingAnchor()?.ids.first { $0.id == anchor.id })
        #expect(abs(after.delta - anchor.delta) <= 0.5, "the row being read moved \(after.delta - anchor.delta) pt at rest")
    }

    /// Rows coming or going, and a row into Needs You, apply at once even mid-scroll.
    @Test func membershipChangesApplyAtOnceWhileScrolling() {
        let host = host()
        defer {
            host.window.isHidden = true
            ListApplyProbe.shared.codeDrivenScroll = false
        }
        host.list.update(model: Self.model(100), actions: host.actions, animated: false, membershipKey: 0)
        turn()
        host.view.contentOffset.y = 1500
        ListApplyProbe.shared.codeDrivenScroll = true
        host.view.contentOffset.y += 6
        var needs = Self.model(100)
        let key = WorkspacesListModel.rowID("w50")
        needs.sections[0].items.removeAll { $0 == key }
        needs.sections.insert(ListSectionIDs(id: "needs", items: [key]), at: 0)
        host.list.update(model: needs, actions: host.actions, animated: false, membershipKey: 1)
        turn()
        #expect(host.list.shownItemIDs(inSection: "needs") == [key], "Needs You waited for the scroll")
        #expect(host.list.deferredReorderCount == 0)
    }

    /// The list model's move edit puts each moved row at its place in the inbox's new order
    /// (random jumps, several at once, with and without a title row).
    @Test func theModelsMoveEditMatchesTheNewOrder() {
        var random = WorkspaceInboxPatchTests.Generator(state: 11)
        for round in 0..<300 {
            let count = 2 + random.next(40)
            var list = (0..<count).map { Workspace(id: "w\($0)", macID: "m", title: "", directory: "", tabs: [], lastActivityAt: Self.now) }
            let titled = round % 2 == 0
            var section = ListSectionIDs(id: "recent", items: (titled ? ["title.recent"] : []) + list.map { WorkspacesListModel.rowID($0.id) })
            var rows: Set<String> = []
            for _ in 0..<(1 + random.next(3)) {
                let from = random.next(list.count)
                let ws = list.remove(at: from)
                list.insert(ws, at: random.next(list.count + 1))
                rows.insert(ws.id)
            }
            var moved: Set<String> = []
            #expect(WorkspacesList.move(rows: rows, in: &section, to: list, moved: &moved))
            let expected = (titled ? ["title.recent"] : []) + list.map { WorkspacesListModel.rowID($0.id) }
            #expect(section.items == expected, "round \(round)")
            if section.items != expected { return }
        }
    }

    /// Mid-list, rows above the one being read leave without animation (a busy Mac closed them):
    /// the row being read stays where it was on screen.
    @Test func rowsRemovedAboveTheRowBeingReadLeaveItInPlace() throws {
        let host = host()
        defer { host.window.isHidden = true }
        host.list.update(model: Self.model(200), actions: host.actions, animated: false, membershipKey: 0)
        turn()
        host.view.layoutIfNeeded()
        host.view.contentOffset.y = 2000
        host.view.layoutIfNeeded()
        let anchor = try #require(host.list.readingAnchor()?.ids.first)
        var fewer = Self.model(200)
        fewer.sections[0].items.removeFirst(5)
        host.list.update(model: fewer, actions: host.actions, animated: false, membershipKey: 1)
        turn()
        host.view.layoutIfNeeded()
        let after = try #require(host.list.readingAnchor()?.ids.first { $0.id == anchor.id })
        #expect(abs(after.delta - anchor.delta) <= 0.5, "the row being read moved \(after.delta - anchor.delta) pt")
    }
}
#endif
