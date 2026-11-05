import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Darwin
import Foundation
import Testing

/// An agent's open of an existing session (`cmux agent open`, `cmux agent open-tab`, the Chief's
/// subagents) on a daemon that answers late, on the real daemon and the app's launch window.
/// Leo, 2026-11-04: "idk why these randomly appeared? in our current session. just new tabs of...
/// yourself?" Two `cmux agent open` runs, the second with the first's idempotency key, each failed
/// with "timed out: new-conversation-tab (no reply within 2.0 seconds)" and each still left a tab.
/// - a reply that misses its deadline never abandons the open: the open finishes in its own
///   workspace (or pane), on the session it names, and no other workspace gains or changes a tab;
/// - the same idempotency key twice opens one tab.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct AgentSessionOpenLateDaemonTests {
    private static func agentTabs(_ services: AppServices) -> AgentTabStore {
        let tabs = services.agentTabs
        tabs.localHost = tabs.localHost ?? AgentSessionRef.host(installID: "open-late-daemon-test")
        tabs.holdsTabs = { _ in true }
        return tabs
    }

    /// Each workspace's daemon tabs (never a stand-in) by workspace key, as (surface, session) pairs.
    private static func daemonTabs(_ store: DaemonStore) -> [String: [String]] {
        var tabs: [String: [String]] = [:]
        for workspace in store.workspaces {
            let listed = workspace.screens.flatMap(\.panes).flatMap(\.tabs).filter { !ProvisionalTab.isProvisional(surface: $0.surface) }
            tabs[workspace.key?.rawValue ?? workspace.id] = listed.map { "\($0.surface.rawValue):\($0.agentSession?.session ?? "-")" }
        }
        return tabs
    }

    private static func tabs(on session: String, in store: DaemonStore) -> [(workspace: String, tab: TabModel)] {
        store.workspaces.flatMap { workspace in
            workspace.screens.flatMap(\.panes).flatMap(\.tabs)
                .filter { $0.agentSession?.session == session && !ProvisionalTab.isProvisional(surface: $0.surface) }
                .map { (workspace.key?.rawValue ?? workspace.id, $0) }
        }
    }

    @MainActor private final class Ended { var value = false }

    /// Runs `work` (an open's own work, awaited) while the daemon is stopped, for at most `limit`, and says
    /// whether it ended in that time. Waiting on the open itself, not a fixed sleep: an open that gives up on
    /// the stopped daemon ends the wait at once, and one that waits it out holds it to `limit`, the stall.
    static func ends(within limit: Duration, _ work: @escaping @MainActor () async -> Void) async -> Bool {
        let ended = Ended()
        Task { @MainActor in
            await work()
            ended.value = true
        }
        return await RapidWorkspaceCreateTests.wait(within: limit) { ended.value }
    }

    /// Waits until the store applied every event the daemon sent so far.
    private static func caughtUp(_ services: AppServices) async {
        guard let connection = services.daemon.connection, let barrier = await connection.eventSequence() else { return }
        await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { services.daemon.store.appliedSequence >= barrier }
    }

    /// `agent.openSessionWorkspace` while the daemon is stopped past the old ten-second budget of the shown
    /// stand-in (#30961): the open gave up while its creates were still queued, and the daemon made them
    /// after. Now it waits them out and binds the session in its own new workspace.
    @Test func aWorkspaceOpenOutlivesALateDaemon() async throws {
        let launched = try await RapidWorkspaceCreateTests.launch()
        let services = launched.services
        let tabs = Self.agentTabs(services)
        try #require(tabs.canHostChat, "this build has no agent page")
        let store = services.daemon.store
        let pid = try #require(services.daemon.identity?.pid)
        let before = Self.daemonTabs(store)
        let key = WorkspaceKey.generate()
        let session = "s-late-ws-\(UUID().uuidString.prefix(8).lowercased())"

        #expect(kill(pid, SIGSTOP) == 0)
        defer { kill(pid, SIGCONT) } // a throw before the SIGCONT below never leaves the daemon stopped
        let work = try AgentSessionWorkspace.open(session: session, name: "late lane", key: key, cwd: nil, services: services)
        // Every request misses its 2 s deadline, past the old ten-second budget: the daemon stays stopped
        // while the open waits, for that budget and two seconds more, unless the open ends first.
        let endedStopped = await Self.ends(within: NewFrontendBrowserTabRequest.lateReplyBudget + .seconds(2)) { _ = await work.value }
        #expect(kill(pid, SIGCONT) == 0)
        let failure = await work.value?.message
        await RapidWorkspaceCreateTests.wait(within: .seconds(20)) { !Self.tabs(on: session, in: store).isEmpty }
        try await Task.sleep(for: .seconds(1))
        await Self.caughtUp(services)
        let onSession = Self.tabs(on: session, in: store)
        let after = Self.daemonTabs(store)
        await launched.stop()

        #expect(!endedStopped, "the open ended while the daemon was stopped")
        #expect(failure == nil, "the open gave up on the late daemon: \(failure ?? "")")
        #expect(onSession.count == 1, "tabs on the session: \(onSession.map { "\($0.workspace) \($0.tab.surface)" })")
        #expect(onSession.first?.workspace == key.rawValue, "the session's tab is not in its own new workspace")
        for (workspace, listed) in before {
            #expect(after[workspace] == listed, "workspace \(workspace) changed: \(listed) -> \(after[workspace] ?? [])")
        }
    }

    /// `agent.openSessionTab` (and the predecessor-row branch of `agent.openSessionWorkspace`) into the
    /// launch window's pane while the daemon is stopped: one send with the 2 s control deadline gave up,
    /// dropped the stand-in and the tab's session binding, and the daemon's tab came in later without
    /// them. Now the keyed create waits for its reply and the tab it gets is bound to the session.
    @Test func aTabOpenOutlivesALateDaemon() async throws {
        let launched = try await RapidWorkspaceCreateTests.launch()
        let services = launched.services
        let tabs = Self.agentTabs(services)
        try #require(tabs.canHostChat, "this build has no agent page")
        let store = services.daemon.store
        let pid = try #require(services.daemon.identity?.pid)
        let pane = try #require(store.workspaces.first?.screens.first?.panes.first, "the launch window shows no pane")
        let before = Self.daemonTabs(store)
        let session = "s-late-tab-\(UUID().uuidString.prefix(8).lowercased())"

        #expect(kill(pid, SIGSTOP) == 0)
        defer { kill(pid, SIGCONT) } // a throw before the SIGCONT below never leaves the daemon stopped
        let pending = try tabs.open(in: pane.handle, of: services.daemon, session: session, linked: true)
        // Past two 2 s control deadlines, unless the open ends first (it gave up on the stopped daemon).
        let endedStopped = await Self.ends(within: .seconds(4)) { _ = try? await pending.value() }
        #expect(kill(pid, SIGCONT) == 0)
        var failure: String?
        var created: AgentTabCreated?
        do { created = try await pending.value() } catch { failure = String(describing: error) }
        await RapidWorkspaceCreateTests.wait(within: .seconds(20)) { !Self.tabs(on: session, in: store).isEmpty }
        try await Task.sleep(for: .seconds(1))
        await Self.caughtUp(services)
        let onSession = Self.tabs(on: session, in: store)
        let linked = created.map { tabs.linkedSessions.contains($0.key) } ?? false
        let bound = created.flatMap { tabs.sessions[$0.key] }
        let after = Self.daemonTabs(store)
        await launched.stop()

        #expect(!endedStopped, "the open ended while the daemon was stopped")
        #expect(failure == nil, "the open gave up on the late daemon: \(failure ?? "")")
        #expect(onSession.count == 1, "tabs on the session: \(onSession.map { "\($0.workspace) \($0.tab.surface)" })")
        #expect(linked, "the daemon's tab lost its session link")
        #expect(bound == session, "the daemon's tab is bound to \(bound ?? "nothing"), not \(session)")
        for (workspace, listed) in before {
            let grown = (after[workspace] ?? []).filter { !listed.contains($0) && !$0.hasSuffix(":\(session)") }
            #expect(grown.isEmpty, "workspace \(workspace) gained tabs not on the session: \(grown)")
        }
    }

    /// The same idempotency key twice, the second while the first open is still in flight (its stand-in shown,
    /// the daemon not answered): one workspace with one tab. The workspace key is derived from the idempotency
    /// key, but the stand-in was not checked and the first tab's mutation id was fresh, so the second run
    /// made a second stand-in and the daemon a second tab in the same workspace.
    @Test func theSameIdempotencyKeyTwiceOpensOneTab() async throws {
        let launched = try await RapidWorkspaceCreateTests.launch()
        let services = launched.services
        let tabs = Self.agentTabs(services)
        try #require(tabs.canHostChat, "this build has no agent page")
        let store = services.daemon.store
        let pid = try #require(services.daemon.identity?.pid)
        let idempotencyKey = "open-twice-\(UUID().uuidString.lowercased())"
        let session = "s-twice-\(UUID().uuidString.prefix(8).lowercased())"
        let invocation = ActionInvocation(arguments: ["session": .string(session), "name": .string("twice")], origin: .script)
        let run = {
            DaemonCommandScope.$current.withValue(DaemonCommandScope(idempotencyKey: idempotencyKey)) {
                services.registry.perform("agent.openSessionWorkspace", invocation: invocation)
            }
        }

        // The daemon holds both runs' requests, so the second comes while the first is in flight.
        #expect(kill(pid, SIGSTOP) == 0)
        defer { kill(pid, SIGCONT) } // a throw before the SIGCONT below never leaves the daemon stopped
        var first = false, second = false
        let work = services.registry.capturingWork {
            first = run()
            second = run()
        }
        // Both runs' work waits on the stopped daemon for a second, unless it ends first.
        let endedStopped = await Self.ends(within: .seconds(1)) { for task in work { _ = await task.value } }
        #expect(kill(pid, SIGCONT) == 0)
        await RapidWorkspaceCreateTests.wait(within: .seconds(20)) { !Self.tabs(on: session, in: store).isEmpty }
        // Long enough for a second create to land as well.
        try await Task.sleep(for: .seconds(4))
        await Self.caughtUp(services)
        let onSession = Self.tabs(on: session, in: store)
        let workspaces = Set(onSession.map(\.workspace))
        await launched.stop()

        #expect(first && second, "a run was refused")
        #expect(!endedStopped, "an open ended while the daemon was stopped")
        #expect(onSession.count == 1, "the same key made \(onSession.count) tabs: \(onSession.map { "\($0.workspace) \($0.tab.surface)" })")
        #expect(workspaces.count == 1)
    }

    /// A tab a person opens (Cmd-T, a split, an import: no control run's scope) on a stopped daemon gives up
    /// within the short late-reply budget, as Cmd-N's workspace does, instead of holding its provisional tab
    /// for the two minutes a scripted open waits.
    @Test func aPersonsTabGivesUpWithinTheShortBudget() async throws {
        let launched = try await RapidWorkspaceCreateTests.launch()
        let services = launched.services
        let tabs = Self.agentTabs(services)
        try #require(tabs.canHostChat, "this build has no agent page")
        let store = services.daemon.store
        let pid = try #require(services.daemon.identity?.pid)
        let pane = try #require(store.workspaces.first?.screens.first?.panes.first, "the launch window shows no pane")

        #expect(DaemonCommandScope.current == nil)
        #expect(kill(pid, SIGSTOP) == 0)
        defer { kill(pid, SIGCONT) } // a throw before the SIGCONT below never leaves the daemon stopped
        let started = ContinuousClock.now
        let pending = try tabs.open(in: pane.handle, of: services.daemon)
        var failed = false
        do { _ = try await pending.value() } catch { failed = true }
        let waited = ContinuousClock.now - started
        #expect(kill(pid, SIGCONT) == 0)
        await launched.stop()

        #expect(failed, "a person's tab on a stopped daemon never gave up")
        #expect(waited < .seconds(20), "a person's tab waited \(waited) on a stopped daemon")
    }
}
