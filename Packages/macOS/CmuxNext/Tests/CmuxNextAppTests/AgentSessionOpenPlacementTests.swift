import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Darwin
import Foundation
import Testing

/// `cmux agent open SESSION --name N` (no `--group`), run the way the CLI runs it (`action.run` under the
/// run's idempotency key), on the real daemon and the app's launch window, whose focused workspace already
/// shows a chat. Leo, 2026-11-04: "idk why these randomly appeared? in our current session. just new tabs
/// of... yourself?" The open must make the session's own workspace, named N, holding that one chat tab:
/// - no tab is added to the focused workspace, or to any other workspace that was there before;
/// - no session-less chat tab sits beside the session's tab;
/// - the session's tab is bound to the session it names, not to the focused chat.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct AgentSessionOpenPlacementTests {
    private static func agentTabs(_ services: AppServices) -> AgentTabStore {
        let tabs = services.agentTabs
        tabs.localHost = tabs.localHost ?? AgentSessionRef.host(installID: "open-placement-test")
        tabs.holdsTabs = { _ in true }
        return tabs
    }

    /// Each workspace's daemon tabs (never a stand-in), by workspace key, as `surface:session` strings.
    private static func daemonTabs(_ store: DaemonStore) -> [String: [String]] {
        var tabs: [String: [String]] = [:]
        for workspace in store.workspaces {
            let listed = workspace.screens.flatMap(\.panes).flatMap(\.tabs).filter { !ProvisionalTab.isProvisional(surface: $0.surface) }
            tabs[workspace.key?.rawValue ?? workspace.id] = listed.map { "\($0.surface.rawValue):\($0.agentSession?.session ?? "-")" }
        }
        return tabs
    }

    private static func tabs(on session: String, in store: DaemonStore) -> [(workspace: WorkspaceModel, tab: TabModel)] {
        store.workspaces.flatMap { workspace in
            workspace.screens.flatMap(\.panes).flatMap(\.tabs)
                .filter { $0.agentSession?.session == session && !ProvisionalTab.isProvisional(surface: $0.surface) }
                .map { (workspace, $0) }
        }
    }

    private static func caughtUp(_ services: AppServices) async {
        guard let connection = services.daemon.connection, let barrier = await connection.eventSequence() else { return }
        await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { services.daemon.store.appliedSequence >= barrier }
    }

    /// Runs `cmux agent open` twice under one idempotency key (the incident's retry), the daemon stopped for
    /// `stall` while the first is in flight, and checks the session's own workspace.
    private static func openTwice(stall: Duration) async throws {
        let launched = try await RapidWorkspaceCreateTests.launch()
        let services = launched.services
        let tabs = Self.agentTabs(services)
        try #require(tabs.canHostChat, "this build has no agent page")
        let store = services.daemon.store
        let pid = try #require(services.daemon.identity?.pid)
        let pane = try #require(store.workspaces.first?.screens.first?.panes.first, "the launch window shows no pane")
        // The focused workspace shows a chat of another session (the coordinator's own chat in the incident).
        let focusedSession = "s-focused-\(UUID().uuidString.prefix(8).lowercased())"
        _ = try await tabs.open(in: pane.handle, of: services.daemon, session: focusedSession, linked: true).value()
        await RapidWorkspaceCreateTests.wait(within: .seconds(20)) { !Self.tabs(on: focusedSession, in: store).isEmpty }
        await Self.caughtUp(services)
        let before = Self.daemonTabs(store)
        let focusedTitles = Set(Self.tabs(on: focusedSession, in: store).map(\.tab.title))

        let name = "Rail & sidebar"
        let session = "s-open-\(UUID().uuidString.prefix(8).lowercased())"
        let idempotencyKey = "mutation_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
        let invocation = ActionInvocation(arguments: ["session": .string(session), "name": .string(name)], origin: .script)
        let run = {
            DaemonCommandScope.$current.withValue(DaemonCommandScope(idempotencyKey: idempotencyKey)) {
                services.registry.perform("agent.openSessionWorkspace", invocation: invocation)
            }
        }
        #expect(kill(pid, SIGSTOP) == 0)
        defer { kill(pid, SIGCONT) } // a throw before the SIGCONT below never leaves the daemon stopped
        var first = false
        let firstWork = services.registry.capturingWork { first = run() }
        // The retry comes `stall` into the first open, which waits on the stopped daemon unless it ends first.
        let firstEnded = await AgentSessionOpenLateDaemonTests.ends(within: stall) { for task in firstWork { _ = await task.value } }
        let second = run()
        #expect(kill(pid, SIGCONT) == 0)
        await RapidWorkspaceCreateTests.wait(within: .seconds(30)) { !Self.tabs(on: session, in: store).isEmpty }
        // Long enough for any late create, repair or second tab to land too.
        try await Task.sleep(for: .seconds(5))
        await Self.caughtUp(services)
        let onSession = Self.tabs(on: session, in: store)
        let after = Self.daemonTabs(store)
        let own = onSession.first?.workspace
        let ownKey = own?.key?.rawValue ?? own?.id ?? ""
        let ownTabs = after[ownKey] ?? []
        let ownName = own?.name
        let title = onSession.first?.tab.title
        await launched.stop()

        #expect(first && second, "a run was refused")
        #expect(!firstEnded, "the first open ended while the daemon was stopped")
        #expect(onSession.count == 1, "tabs on the session: \(onSession.map { "\($0.workspace.key?.rawValue ?? $0.workspace.id) \($0.tab.surface)" })")
        #expect(before[ownKey] == nil, "the session's tab went into workspace \(ownKey), which was there before the open")
        #expect(ownName == name, "the session's workspace is named \(ownName ?? "nothing"), not \(name)")
        #expect(ownTabs.count == 1, "the session's workspace holds \(ownTabs), not only the session's tab")
        for (workspace, listed) in before {
            #expect(after[workspace] == listed, "workspace \(workspace) changed: \(listed) -> \(after[workspace] ?? [])")
        }
        let added = after.filter { before[$0.key] == nil && $0.key != ownKey }
        #expect(added.isEmpty, "the open made other workspaces too: \(added)")
        // Both test sessions are unknown to acpmux and show its same placeholder title, so the title is only
        // recorded here; what ties it to the session is its binding, checked above through `agentSession`.
        print("AgentSessionOpenPlacementTests: session tab title \(title ?? "-"), focused chat titles \(focusedTitles)")
    }

    /// The daemon answers at once.
    @Test func aCliOpenMakesTheSessionsOwnNamedWorkspace() async throws {
        try await Self.openTwice(stall: .milliseconds(1))
    }

    /// The incident: the daemon answers past the old ten-second budget, and the retry comes with the same key.
    @Test func aCliOpenOnALateDaemonMakesTheSessionsOwnNamedWorkspace() async throws {
        try await Self.openTwice(stall: .seconds(12))
    }
}
