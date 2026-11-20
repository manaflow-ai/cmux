import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing

/// cmux-ad i7: Close Other Tabs, Close Tabs to the Left and Close Tabs to the Right started from a
/// tab that is NOT selected select that tab: it is the tab the person acted on, and it stays.
/// From the selected tab nothing changes; a plain close of one tab uses the one close-selection rule
/// (/work/wt/handoff/tasks/close-selection-rule.md; `TabCloseSelectsBeforeTests`). Each case runs the app's own action (the tab menu, the palette,
/// the shortcut, the app's action run) or the strip's intent against a same-tree cmux-tui daemon.
/// The pinned cases put a pinned tab first: the close selected that pinned tab before.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CloseSeveralSelectsActedOnTabTests {
    private enum Entry { case action, strip }

    /// Strip T b0 b1 b2 (T pinned when `pinned`): selects `selected`, runs `action` on `actedOn`
    /// (indexes into the strip), and waits until `closed` are gone and `selects` is selected.
    private static func run(_ action: ActionID, entry: Entry = .action, pinned: Bool, selected: Int, actedOn: Int,
                            closed: [Int], selects: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await PinnedPageTests.withApp { services, connection in
            let (pane, ids, surface) = try await TabCloseSelectsBeforeTests.pane(services, connection, browsers: 3)
            if pinned {
                try await connection.setTabPinned(try #require(surface[ids[0]]), true)
                try await PinnedPageTests.until({ pane.stripModel.orderedTabs.first?.isPinned == true && pane.orderedIDs.map(\.rawValue) == ids })
            }
            try await TabCloseSelectsBeforeTests.select(ids[selected], in: pane)
            let target = TabID(ids[actedOn])
            switch entry {
            case .action:
                // The tab menu's row on the right-clicked tab: that tab is the target.
                #expect(services.registry.perform(action, invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: target.rawValue), origin: .user)),
                        "\(action) did not run", sourceLocation: sourceLocation)
            case .strip:
                pane.stripModel.send(action == "closeTabsToRight" ? .closeToRight(of: target) : .closeOthers(keeping: target))
            }
            try await TabCloseSelectsBeforeTests.expect(pane, services, closed: closed.map { ids[$0] }, selects: ids[selects],
                                                       "\(action) on \(actedOn) with \(selected) selected\(pinned ? ", T pinned" : "")",
                                                       sourceLocation: sourceLocation)
        }
    }

    /// Close Other Tabs on b2 while b0 is selected selects b2; with T pinned first it selected T.
    @Test func closeOthersFromAnUnselectedTabSelectsIt() async throws {
        try await Self.run("closeOtherTabsInPane", pinned: false, selected: 1, actedOn: 3, closed: [0, 1, 2], selects: 3)
    }

    @Test func closeOthersFromAnUnselectedTabAfterAPinnedTabSelectsIt() async throws {
        try await Self.run("closeOtherTabsInPane", pinned: true, selected: 1, actedOn: 3, closed: [1, 2], selects: 3)
    }

    /// The strip's own Close Other Tabs intent takes the same path.
    @Test func theStripsCloseOthersSelectsTheKeptTab() async throws {
        try await Self.run("closeOtherTabsInPane", entry: .strip, pinned: true, selected: 1, actedOn: 3, closed: [1, 2], selects: 3)
    }

    /// Close Tabs to the Left of b1 while b2 (it stays) is selected selects b1.
    @Test func closeToTheLeftFromAnUnselectedTabSelectsIt() async throws {
        try await Self.run("closeTabsToLeft", pinned: false, selected: 3, actedOn: 2, closed: [0, 1], selects: 2)
    }

    /// Close Tabs to the Left of b2 while b0 (it closes) is selected selects b2, not the pinned T before b0.
    @Test func closeToTheLeftFromAnUnselectedTabAfterAPinnedTabSelectsIt() async throws {
        try await Self.run("closeTabsToLeft", pinned: true, selected: 1, actedOn: 3, closed: [1, 2], selects: 3)
    }

    /// Close Tabs to the Right of b0 while T (it stays) is selected selects b0.
    @Test func closeToTheRightFromAnUnselectedTabSelectsIt() async throws {
        try await Self.run("closeTabsToRight", pinned: false, selected: 0, actedOn: 1, closed: [2, 3], selects: 1)
    }

    /// Close Tabs to the Right of b0 while the pinned T is selected selects b0.
    @Test func closeToTheRightFromAnUnselectedTabAfterAPinnedTabSelectsIt() async throws {
        try await Self.run("closeTabsToRight", pinned: true, selected: 0, actedOn: 1, closed: [2, 3], selects: 1)
    }

    /// The strip's own Close Tabs to the Right intent takes the same path.
    @Test func theStripsCloseToTheRightSelectsTheTabItStartedFrom() async throws {
        try await Self.run("closeTabsToRight", entry: .strip, pinned: false, selected: 0, actedOn: 1, closed: [2, 3], selects: 1)
    }

    /// From the selected tab nothing changes: it stays selected.
    @Test func fromTheSelectedTabTheSelectionStays() async throws {
        try await Self.run("closeOtherTabsInPane", pinned: true, selected: 2, actedOn: 2, closed: [1, 3], selects: 2)
        try await Self.run("closeTabsToLeft", pinned: false, selected: 2, actedOn: 2, closed: [0, 1], selects: 2)
        try await Self.run("closeTabsToRight", pinned: false, selected: 2, actedOn: 2, closed: [3], selects: 2)
    }

    /// A plain close of one tab uses the one close-selection rule
    /// (/work/wt/handoff/tasks/close-selection-rule.md R0, R1 rank 4; it was the tab before): an
    /// unselected close keeps the selection, and the selected tab's close selects the next tab.
    @Test func aPlainCloseUsesTheOneCloseSelectionRule() async throws {
        try await Self.run("closeTab", pinned: false, selected: 2, actedOn: 3, closed: [3], selects: 2)
        try await Self.run("closeTab", pinned: true, selected: 2, actedOn: 2, closed: [2], selects: 3)
    }

    /// Live terminals leave in the gesture's turn while the daemon reads what they run (`TabCloseGuard`'s hide): the kept
    /// tab is selected in that same turn. Before, the pinned tab before the closing one showed for the whole read.
    @Test func closeOthersOnLiveTerminalsSelectsTheKeptTabInTheGesturesTurn() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let model = try #require(store.workspaces.first?.screens.first?.panes.first)
            let pane = try #require(services.paneController(for: model))
            for _ in 0..<2 { _ = try await connection.newTab(in: model.handle) }
            try await PinnedPageTests.until({ pane.orderedIDs.count == 3 }, report: { "the pane holds \(pane.orderedIDs.map(\.rawValue))" })
            let ids = pane.orderedIDs.map(\.rawValue) // T t1 t2, all terminals
            try await connection.setTabPinned(try #require(store.tab(id: ids[0])).surface, true)
            try await PinnedPageTests.until({ pane.stripModel.orderedTabs.first?.isPinned == true && pane.orderedIDs.map(\.rawValue) == ids })
            try await TabCloseSelectsBeforeTests.select(ids[1], in: pane)
            let closing = try #require(store.tab(id: ids[1]))
            try #require(TabCloseGuard.asks([closing], services: services), "the terminal close warning does not apply")
            let hold = services.daemon.closeReadHold
            hold.arm()
            defer { hold.release() }
            #expect(services.registry.perform("closeOtherTabsInPane", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: ids[2]), origin: .user)))
            #expect(!pane.orderedIDs.map(\.rawValue).contains(ids[1]), "the closing terminal did not leave in the gesture's turn")
            #expect(pane.stripModel.selectedID?.rawValue == ids[2], "in the gesture's turn the pane selects \(pane.stripModel.selectedID?.rawValue ?? "none"), not the kept tab")
            hold.release()
            try await TabCloseSelectsBeforeTests.expect(pane, services, closed: [ids[1]], selects: ids[2], "Close Others on live terminals")
        }
    }
}
