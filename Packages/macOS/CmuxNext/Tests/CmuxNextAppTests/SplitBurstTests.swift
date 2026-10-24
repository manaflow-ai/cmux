import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Lawrence 2026-10-23: "spamming a bunch of cmd shift d and cmd d etc is laggy ish". Every split
/// press in a burst shows its pane in the key's turn and the daemon makes every one of them: a press
/// on a pane still being created (its stand-in) splits that pane, never a pane the daemon does not
/// know. Runs the app's Split Right against a same-tree cmux-tui daemon.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct SplitBurstTests {
    /// Cmd-D, then at once (same turn) Cmd-D on the pane it is creating: the second split goes to the
    /// daemon's pane for that stand-in, so both new panes stay. Before: the second command named the
    /// stand-in's handle, the daemon refused it, and its pane vanished (a lost press).
    @Test func cmdDOnAPaneStillBeingCreatedSplitsIt() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let content = try #require(services.windows.active?.workspaceContent)
            let before = Set(content.panes.keys)
            #expect(services.registry.perform("splitRight", invocation: ActionInvocation(origin: .user)))
            let creating = try #require(content.panes.first { !before.contains($0.key) }?.value, "the split showed no pane in its turn")
            #expect(creating.pane.tabs.allSatisfy { ProvisionalTab.isProvisional(surface: $0.surface) }, "the first split is still being created")
            let onStandIn = ActionInvocation(target: ActionTargetRef(kind: .pane, id: creating.pane.id), origin: .user)
            #expect(services.registry.perform("splitRight", invocation: onStandIn))
            func confirmed() -> Int {
                content.panes.values.filter { $0.pane.tabs.contains { !ProvisionalTab.isProvisional(surface: $0.surface) } }.count
            }
            try await PinnedPageTests.until({ confirmed() == before.count + 2 && content.panes.count == before.count + 2 },
                                            report: { "\(content.panes.count) panes, \(confirmed()) made by the daemon; wanted \(before.count + 2)" })
            // And they stay: no refusal takes one back after its echo.
            try await Task.sleep(for: .milliseconds(300))
            #expect(content.panes.count == before.count + 2)
        }
    }
}
