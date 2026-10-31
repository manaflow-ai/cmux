#if DEBUG
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextSettings
import Foundation
import Testing

/// `debug.closed_ids` (HistoryControl.closedIDs), the every-action sweep's read of the closed
/// history: it answers after a sync barrier (an identify round trip, then the store applied every
/// event the daemon emitted before that reply), so a close the daemon committed before the call
/// is in the list. The sweep reopens by these ids exactly the groups a measured input closed; a
/// list read before the close's event landed would make it reopen nothing and rebuild the session.
/// Through the app against a same-tree daemon, with no wait between the close and the read.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct DebugClosedIDsTests {
    @Test func aCloseCommittedBeforeTheReadIsInTheList() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let window = try #require(services.windows.active)
            let first = try #require(window.workspaceContent?.panes.values.first?.pane)
            _ = try await connection.split(first.handle, direction: .right)
            let screen = { store.workspaces.flatMap(\.screens).first { $0.panes.contains { $0 === first } } }
            try await PinnedPageTests.until({ screen()?.panes.filter { !$0.tabs.isEmpty }.count == 2 }, within: .seconds(30),
                                            report: { "\(screen()?.panes.count ?? 0) panes" })
            let other = try #require(screen()?.panes.first { $0 !== first })
            let seen = Set(store.closedItems.map(\.id))

            // The close's reply returns before the store applies its event: the read's barrier is the only wait.
            try await connection.closePane(other.handle)
            let reply = try await HistoryControl.closedIDs(services.daemon)

            let listed = reply["closed_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let fresh = store.closedItems.filter { !seen.contains($0.id) }.map { DaemonClosedHistory.historyID($0.id) }
            #expect(fresh.count == 1, "the close stored \(fresh.count) closed groups before the read answered")
            #expect(fresh.allSatisfy { listed.contains($0) }, "listed \(listed), fresh \(fresh)")
            #expect(listed.count == store.closedItems.count, "the read hides closed groups: \(listed.count) of \(store.closedItems.count)")
        }
    }
}
#endif
