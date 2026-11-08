@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation
import Testing

/// A classic workspace whose terminal's shell exits at once (its folder is gone, its rc file fails) lost that tab
/// before the import named it: the rename failed with "unknown surface", the whole workspace counted as not opened
/// and its other terminals were never parked. Through the app against a same-tree daemon.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct EndedTabRenameTests {
    /// The tab that went is skipped; a tab still there is named.
    @Test func renamingATabWhoseTerminalEndedIsNotAnError() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let key = try #require(store.workspaces.compactMap(\.key).first)
            let live = try #require(try await connection.createTerminal(in: key).surface)
            let ended = try #require(try await connection.createTerminal(in: key).surface)
            try await connection.closeTab(ended)
            await #expect(throws: Never.self) { try await services.daemon.renameTab(ended, to: "gone", in: key, on: connection) }
            try await services.daemon.renameTab(live, to: "kept", in: key, on: connection)
            try await PinnedPageTests.until({ store.tab(surface: live)?.name == "kept" },
                                            report: { "the live tab was not named: \(String(describing: store.tab(surface: live)?.name))" })
        }
    }
}
