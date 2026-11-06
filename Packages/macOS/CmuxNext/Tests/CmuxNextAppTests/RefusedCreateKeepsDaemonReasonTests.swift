import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation
import Testing

/// FC-1 (fuzz catalog, 2026-11-01): right after launch, a New Terminal Tab from Home's dock failed in 3 of 4 bench
/// launches with "new-tab: the daemon refused the new tab". The optimistic create threw a fixed `NewTerminalTabFailure`
/// for every failure of its `new-tab`, so the refusal named no cause: a lost connection, the daemon's own error and a
/// timeout all read the same, and the cause was only in the app's unified log. Cmd-D, New Column and New Row did the
/// same with "the daemon refused the split". The failure a person (and the control socket) gets must be the real one.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct RefusedCreateKeepsDaemonReasonTests {
    /// A daemon-range pane id no daemon pane has: cmux-tui answers its own error ("unknown pane").
    private static let missingPane = PaneID(rawValue: 987_654)

    /// The daemon's own answer (`ok:false`), not a fixed text that hides it.
    private static func isDaemonAnswer(_ error: (any Error)?) -> Bool {
        if case .command = error as? DaemonError { return true }
        return false
    }

    @Test func aRefusedNewTerminalTabCarriesTheDaemonsReason() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let daemon = services.daemon
            #expect(Self.missingPane.rawValue < ProvisionalPane.firstHandle)
            let pending = NewTerminalTabCommand(pane: Self.missingPane, options: SpawnOptions()).intendNow(on: daemon)
            var failure: (any Error)?
            do { _ = try await pending.send() } catch { failure = error }
            #expect(failure != nil, "a new tab in a pane the daemon does not have was made")
            #expect(Self.isDaemonAnswer(failure),
                    "the new tab's failure hides the daemon's answer: \(String(describing: failure))")
            // The stand-in is gone with the refusal.
            #expect(!daemon.store.panesByHandle.values.flatMap(\.tabs).contains { $0.surface == pending.surface })
        }
    }

    @Test func aRefusedSplitNewColumnAndNewRowCarryTheDaemonsReason() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let daemon = services.daemon
            let creates: [(String, @MainActor () async throws -> SurfaceCreated)] = [
                ("split", PaneSplitCommand(pane: Self.missingPane, direction: .right, options: SpawnOptions(), swapTowards: nil)
                    .intendNow(on: daemon, provisional: ProvisionalPane())),
                ("new column", NewColumnCommand(pane: Self.missingPane, width: 400, options: SpawnOptions())
                    .intendNow(on: daemon, provisional: ProvisionalPane(columnWidth: 400))),
                ("new row", NewRowCommand(pane: Self.missingPane, height: 200, options: SpawnOptions())
                    .intendNow(on: daemon, provisional: ProvisionalPane(rowHeight: 200))),
            ]
            for (name, send) in creates {
                var failure: (any Error)?
                do { _ = try await send() } catch { failure = error }
                #expect(failure != nil, "\(name): a pane beside a pane the daemon does not have was made")
                #expect(Self.isDaemonAnswer(failure), "\(name): the failure hides the daemon's answer: \(String(describing: failure))")
            }
        }
    }
}
