import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Go Forward / Go Back / Go to Last Location with nowhere to go, and Copy Notification Text with no
/// notification, say why (unimpl-audit-actions.md rows 43, 44) instead of reporting success.
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct HistoryAndNotificationNothingToDoTests {
    @Test func goForwardWithNothingAheadSaysWhy() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let refusal = services.registry.capturingRefusal {
                _ = services.registry.perform("focusHistoryForward", invocation: ActionInvocation(origin: .cli))
            }
            #expect(refusal != nil, "Go Forward with nothing ahead reports success and goes nowhere")
        }
    }

    @Test func copyNotificationWithNoNotificationSaysWhy() async throws {
        try await PinnedPageTests.withApp { services, connection in
            try #require(try await connection.notificationLedger(limit: 1).isEmpty, "the ledger starts with a notification")
            var work: [ActionWork] = []
            let refusal = services.registry.capturingRefusal {
                work = services.registry.capturingWork {
                    _ = services.registry.perform("notificationCopy", invocation: ActionInvocation(origin: .cli))
                }
            }
            var failures: [String] = []
            for task in work { if let failure = await task.value { failures.append(failure.message) } }
            #expect(refusal != nil || !failures.isEmpty, "Copy Notification Text with an empty ledger reports success and copies nothing")
        }
    }
}
