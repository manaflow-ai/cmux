import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing

/// cmux-ad i7: Close Other Tabs, Close Tabs to the Left and Close Tabs to the Right started from a
/// tab that is NOT selected select that tab: it is the tab the person acted on, and it stays.
/// From the selected tab nothing changes; a plain close of one tab keeps the tab-before rule
/// (`TabCloseSelectsBeforeTests`). Each case runs the app's own action (the tab menu, the palette,
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

    /// A plain close of one tab keeps its rule: an unselected close keeps the selection, and the
    /// selected tab's close selects the tab before it.
    @Test func aPlainCloseKeepsTheTabBeforeRule() async throws {
        try await Self.run("closeTab", pinned: false, selected: 2, actedOn: 3, closed: [3], selects: 2)
        try await Self.run("closeTab", pinned: true, selected: 2, actedOn: 2, closed: [2], selects: 1)
    }
}
