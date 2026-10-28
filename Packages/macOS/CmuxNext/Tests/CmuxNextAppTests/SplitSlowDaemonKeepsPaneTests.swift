import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Darwin
import Foundation
import Testing

/// Cmd-D's new pane shows at the press, and its `split` runs behind it under the pane's client keys.
/// A daemon that answered after the deadline (a busy Mac) made the app take the shown pane back,
/// while the daemon still made the split: the person saw the new pane appear, then vanish (#26689).
/// The same for a split that opens the New Tab page (`new-conversation-tab` with a split). A late
/// reply is not a refusal: the same request again replays what the daemon committed.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct SplitSlowDaemonKeepsPaneTests {
    @Test func cmdDKeepsItsPaneWhenTheDaemonAnswersAfterTheDeadline() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let content = try #require(services.windows.active?.workspaceContent)
            let daemon = services.daemon
            try #require(daemon.supports(DaemonCapability.splitClientKeys.rawValue), "the optimistic split needs client keys")
            // A terminal split: a terminal pane splits to a terminal (no New Tab page).
            try await keepsPane(services, content, past: DaemonConnection.defaultSpawnTimeout) {
                _ = services.registry.perform("splitRight", invocation: ActionInvocation(origin: .user))
            }
        }
    }

    @Test func aNewTabPageSplitKeepsItsPaneWhenTheDaemonAnswersAfterTheDeadline() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            // This Mac hosts the New Tab page, so the split opens it in its own pane.
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-split-slow")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            try #require(services.daemon.supports(DaemonCapability.conversationTabSplit.rawValue), "the daemon makes no page split")
            let content = try #require(services.windows.active?.workspaceContent)
            let source = try #require(content.focusedPane ?? content.panes.values.first)
            try await keepsPane(services, content, past: DaemonConnection.defaultRequestTimeout) {
                #expect(NewTabPage.split(source, edge: .right))
            }
        }
    }

    /// Stops the daemon, runs `press` (a creation that shows a new pane at once), keeps the daemon
    /// stopped past `deadline`, resumes it, and expects the shown pane to stay and become the daemon's.
    private func keepsPane(_ services: AppServices, _ content: WorkspaceContentController, past deadline: Duration,
                           _ press: () -> Void) async throws {
        let pid = try #require(services.daemon.identity?.pid)
        let before = Set(content.panes.keys)
        #expect(kill(pid, SIGSTOP) == 0)
        let work = services.registry.capturingWork(press)
        let shown = Set(content.panes.keys).subtracting(before)
        try? await Task.sleep(for: deadline + .seconds(1)) // test-only: past the reply deadline
        #expect(kill(pid, SIGCONT) == 0)
        var failures: [String] = []
        for task in work { if let failure = await task.value { failures.append(failure.message) } }

        @MainActor func confirmed() -> Bool {
            content.panes.contains { !before.contains($0.key) && $0.value.pane.tabs.contains { !ProvisionalTab.isProvisional(surface: $0.surface) } }
        }
        try? await PasswordManagerRouteTests.until({ confirmed() }, within: .seconds(20))
        // A pane taken back late would leave here.
        try? await Task.sleep(for: .seconds(1)) // test-only
        let new = Set(content.panes.keys).subtracting(before)

        #expect(shown.count == 1, "the press showed \(shown.count) panes")
        #expect(confirmed(), "the new pane left: \(new)")
        #expect(new.count == 1, "panes after the press: \(new)")
        #expect(failures.isEmpty, "failed: \(failures)")
    }
}
