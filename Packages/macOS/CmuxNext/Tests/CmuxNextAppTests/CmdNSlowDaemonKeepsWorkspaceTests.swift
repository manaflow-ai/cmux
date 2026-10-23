import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Darwin
import Foundation
import Testing

/// Cmd-N's workspace shows at the press, and its pin, `create-workspace` and first tab run behind
/// it, each with the 2 s control deadline. A daemon that answered one of them late (a busy Mac)
/// made the app take the shown workspace back and close the one the daemon made: the person saw
/// the new workspace appear, then disappear a few seconds later. A late reply is not a refusal:
/// the same request again replays what the daemon committed.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CmdNSlowDaemonKeepsWorkspaceTests {
    @Test func cmdNKeepsItsWorkspaceWhenTheDaemonAnswersAfterTheDeadline() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            // This Mac hosts the New Tab page, so Cmd-N takes the instant path.
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-cmdn-slow")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let pid = try #require(services.daemon.identity?.pid)
            let window = try #require(services.windows.active?.state.id)
            let store = services.daemon.store
            let before = Set(store.workspaces.map(\.id))

            // The daemon stops answering for longer than a request's deadline, from the press.
            #expect(kill(pid, SIGSTOP) == 0)
            let work = services.registry.capturingWork {
                _ = services.registry.perform("newTab", invocation: ActionInvocation(origin: .user))
            }
            let shown = store.workspaces.filter { !before.contains($0.id) }.map(\.id)
            try? await Task.sleep(for: .seconds(3)) // test-only: past the 2 s deadline
            #expect(kill(pid, SIGCONT) == 0)
            var failures: [String] = []
            for task in work { if let failure = await task.value { failures.append(failure.message) } }

            // The shown workspace is the daemon's now, with its New Tab page, in the window.
            @MainActor func confirmed() -> WorkspaceModel? {
                store.workspaces.first { shown.contains($0.id) && !$0.isProvisional && $0.screens.contains { $0.panes.contains { !$0.tabs.isEmpty } } }
            }
            try? await PasswordManagerRouteTests.until({ confirmed() != nil && services.windows.registry.members(of: window).contains(shown.first ?? "") },
                                                       within: .seconds(20))
            // A workspace taken back late would leave here.
            try? await Task.sleep(for: .seconds(1)) // test-only
            let new = store.workspaces.filter { !before.contains($0.id) }

            #expect(shown.count == 1, "Cmd-N showed \(shown.count) workspaces at the press")
            #expect(confirmed() != nil, "the workspace left: \(new.map { "\($0.id) provisional=\($0.isProvisional)" })")
            #expect(new.count == 1, "workspaces after the press: \(new.map(\.id))")
            #expect(services.windows.registry.members(of: window).contains(shown.first ?? ""), "not in the window")
            #expect(failures.isEmpty, "failed: \(failures)")
        }
    }
}
