import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Move Tab to New Column that the daemon refuses gives its caller the daemon's reason (review 2 of
/// pl-instant-swift, b428a205b48): a CLI run's reply and the sweep's row said "see the app log". Runs the action
/// against a same-tree cmux-tui, which refuses to move a pane's only tab out of it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct TabMoveToNewColumnReasonTests {
    @Test func aRefusedMoveGivesTheCallerTheDaemonsReason() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let store = services.daemon.store
            let model = try #require(store.workspaces.first?.screens.first?.panes.first)
            try #require(model.tabs.count == 1, "the base pane has \(model.tabs.count) tabs; the daemon refuses only a pane's only tab")
            let tab = try #require(model.tabs.first)
            let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.id), origin: .cli)
            let work = services.registry.capturingWork {
                #expect(services.registry.perform("tab.moveToNewColumn", invocation: invocation))
            }
            try #require(!work.isEmpty, "the action reported no work to its caller")
            var failures: [ActionWorkFailure] = []
            for task in work { if let failure = await task.value { failures.append(failure) } }
            let text = failures.map(\.message).joined(separator: " | ")
            #expect(text.contains("move-tab-to-column"), "no failure for the refused move: \(text)")
            #expect(!text.contains("see the app log"), "the caller got no reason: \(text)")
            #expect(text.lowercased().contains("only tab"), "the daemon's reason is not in the failure: \(text)")
        }
    }
}
