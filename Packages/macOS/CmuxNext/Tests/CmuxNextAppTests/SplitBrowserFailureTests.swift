import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Split Browser Right/Down whose browser tab cannot open gives its caller the failure (review 2 of
/// pl-instant-swift, 920125e5024 had no runtime test): the open goes through the browser service's `create`
/// seam, which this test makes fail, against a same-tree cmux-tui.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct SplitBrowserFailureTests {
    private struct Refused: Error, CustomStringConvertible {
        var description: String { "the test refused the browser tab" }
    }

    @Test(arguments: ["splitBrowserRight", "splitBrowserDown"])
    func aFailedOpenGivesTheCallerTheFailure(action: String) async throws {
        try await PinnedPageTests.withApp { services, _ in
            let browserTabs = services.cache.browserTabs
            browserTabs.create = { _, _, _, _, _, _, _ in throw Refused() }
            let model = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
            let panes = services.daemon.store.workspaces.first?.screens.first?.panes.count ?? 0
            let invocation = ActionInvocation(target: ActionTargetRef(kind: .pane, id: model.id), origin: .cli)
            var work: [ActionWork] = []
            let refusal = services.registry.capturingRefusal {
                work = services.registry.capturingWork {
                    _ = services.registry.perform(ActionID(rawValue: action), invocation: invocation)
                }
            }
            #expect(refusal == nil, "the split was refused before the open: \(refusal ?? "")")
            try #require(!work.isEmpty, "the action reported no work to its caller")
            var failures: [String] = []
            for task in work { if let failure = await task.value { failures.append(failure.message) } }
            let text = failures.joined(separator: " | ")
            #expect(text.contains("split-browser"), "no failure for the failed open: \(text)")
            #expect(text.contains("the test refused the browser tab"), "the open's reason is not in the failure: \(text)")
            #expect(services.daemon.store.workspaces.first?.screens.first?.panes.count == panes, "a split appeared without its tab")
        }
    }
}
