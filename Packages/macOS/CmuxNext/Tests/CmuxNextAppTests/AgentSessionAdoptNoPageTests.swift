import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation
import Testing

/// `cmux agent open S --host <machine>` in a build without the agent page is refused the way the
/// same open on this Mac is, before anything is made. It made a workspace on that machine and bound
/// the session into an agent tab that could not show it. The other machine is a real cmux-tui
/// daemon reached as the app reaches a machine's link socket, as in ``CrossMachineTabMoveTests``.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct AgentSessionAdoptNoPageTests {
    /// Every workspace id the other machine's store listed while the open ran.
    @MainActor final class Seen {
        var ids: Set<String> = []
        /// When the watch stops: set once the open's work has finished.
        var until: ContinuousClock.Instant?
    }

    /// Runs `body` with this app's services (`pane`: the agent page's environment) and another
    /// machine, a same-tree cmux-tui reached as the app reaches a machine's link socket (its path the
    /// last argument), connected; ends both after, whatever `body` throws.
    static func withMachine(pane: [String: String] = ["CMUX_NEXT_AGENT_PANE_MOCK": "1"],
                            _ body: (AppServices, CloudMachineSession, String) async throws -> Void) async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = URL(fileURLWithPath: "/private/tmp/cn-adopt-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let environment: @Sendable () -> [String: String] = {
            ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"]
        }
        let vm = DaemonLauncher(configuration: .init(binary: binary, session: "cn-adopt-vm-\(UUID().uuidString.prefix(6).lowercased())",
                                                     stateDirectory: root.appendingPathComponent("vm-state")), environment: environment)
        _ = NSApplication.shared
        let vmSocket = try await vm.endpointProvider().socketPath
        let services = AppServices(environment: AppEnvironment.current([:]), agentPaneEnvironment: pane)
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let machine = CloudMoveTests.machine(services, cli: URL(fileURLWithPath: "/usr/bin/false"), root: root)
        services.machines.add(machine)
        machine.daemon.start(remote: { vmSocket })
        let result: Result<Void, any Error>
        do {
            let deadline = ContinuousClock.now + .seconds(60)
            while !machine.daemon.isLive || machine.daemon.identity == nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            try #require(machine.daemon.connection != nil, "the other machine did not connect")
            try await body(services, machine, vmSocket)
            result = .success(())
        } catch {
            result = .failure(error)
        }
        await CloudMoveTests.end(machine.daemon)
        for controller in services.windows.controllers { controller.window?.close() }
        try result.get()
    }

    @Test func anotherMachinesChatIsRefusedWithoutTheAgentPageAndMakesNoWorkspace() async throws {
        // A build without the agent page (and no dev server): no chat can show here. The mock host starts no acpmux.
        try await Self.withMachine(pane: ["CMUX_NEXT_AGENT_PANE_NONE": "1", "CMUX_NEXT_AGENT_PANE_MOCK": "1"]) { services, machine, _ in
            try #require(!services.agentTabs.canHostChat, "this test build has the agent page")
            try #require(services.machines.remoteDaemon(named: machine.machineID) === machine.daemon, "the host names no machine")
            let before = Set(machine.daemon.store.workspaces.map(\.id))

            // Every workspace the other machine lists while the open runs, even one closed again.
            let seen = Seen()
            let store = machine.daemon.store
            let watch = Task { @MainActor in
                while seen.until.map({ ContinuousClock.now < $0 }) ?? true {
                    seen.ids.formUnion(store.workspaces.map(\.id))
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
            var work: [ActionWork] = []
            let refusal = services.registry.capturingRefusal {
                work = services.registry.capturingWork {
                    _ = services.registry.perform("agent.openSessionWorkspace", invocation: ActionInvocation(arguments: [
                        "session": .string("lane-1"), "host": .string(machine.machineID), "key": .string(UUID().uuidString.lowercased()),
                    ]))
                }
            }
            var failures: [String] = []
            for task in work { if let failure = await task.value { failures.append(failure.message) } }
            // The watch runs 500 ms more: a late tree event would land in that window.
            seen.until = ContinuousClock.now + .milliseconds(500)
            await watch.value
            seen.ids.formUnion(store.workspaces.map(\.id))

            #expect(refusal?.contains(MiscHandlerStrings.quickChatUnavailable) == true,
                    "the open was not refused for the missing agent page: \(String(describing: refusal)) \(failures)")
            #expect(work.isEmpty, "the refused open still started work: \(failures)")
            #expect(seen.ids.subtracting(before).isEmpty, "the other machine made a workspace: \(seen.ids.subtracting(before))")
        }
    }

    /// With the agent page, an adopt the other machine refuses (no acpmux there lists the session)
    /// leaves nothing behind on it: the workspace the open made for the chat, its terminal and its
    /// unbound agent tab, closes again. Base's half-created close only closes an EMPTY workspace,
    /// and this one already held both tabs, so it stayed.
    @Test func aRefusedAdoptClosesTheWorkspaceItMade() async throws {
        // The mock host starts no acpmux, so the other machine lists no session to adopt.
        try await Self.withMachine { services, machine, _ in
            try #require(services.agentTabs.canHostChat, "this test build has no agent page")
            try #require(services.machines.remoteDaemon(named: machine.machineID) === machine.daemon, "the host names no machine")
            let store = machine.daemon.store
            let before = Set(store.workspaces.map(\.id))
            let key = UUID().uuidString.lowercased()

            var work: [ActionWork] = []
            let refusal = services.registry.capturingRefusal {
                work = services.registry.capturingWork {
                    _ = services.registry.perform("agent.openSessionWorkspace", invocation: ActionInvocation(arguments: [
                        "session": .string("lane-missing"), "host": .string(machine.machineID), "key": .string(key),
                    ]))
                }
            }
            #expect(refusal == nil, "the open was refused before it reached the other machine: \(String(describing: refusal))")
            var failures: [String] = []
            for task in work { if let failure = await task.value { failures.append(failure.message) } }
            #expect(!failures.isEmpty, "the other machine adopted a session no acpmux lists")

            // The close is a daemon commit; the store mirrors it once the tree event lands, and the
            // repair, which observes the store, lets the key go after that.
            let repair = services.machines.emptyWorkspaceRepair(machine.daemon.machineID, local: services.emptyWorkspaces)
            let settleDeadline = ContinuousClock.now + .seconds(10)
            while Set(store.workspaces.map(\.id)) != before || repair.isSettling(WorkspaceKey(rawValue: key)), ContinuousClock.now < settleDeadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            let left = Set(store.workspaces.map(\.id)).subtracting(before)
            #expect(left.isEmpty, "the refused adopt left a workspace on the other machine: \(left) \(failures)")
            #expect(services.machines.workspace(id: key) == nil, "the refused adopt's workspace is still listed")
            // Its repair claim goes with it: a failed adopt never leaves the key settling.
            #expect(!repair.isSettling(WorkspaceKey(rawValue: key)), "the refused adopt's workspace is still settling in the repair")
        }
    }

    /// A failed adopt's close is sent again on the next connection after a dropped link, never after
    /// the daemon's own answer (a refusal, or a workspace already gone) or a reply still missing past
    /// the late-reply budget (a live daemon that never answers would otherwise keep it going).
    @Test func aFailedAdoptsCloseRetriesOnlyALostLink() {
        #expect(AgentSessionWorkspace.closeRetries(after: .notConnected))
        #expect(AgentSessionWorkspace.closeRetries(after: .connectionClosed(reason: "eof")))
        #expect(AgentSessionWorkspace.closeRetries(after: .daemonShutdown))
        #expect(!AgentSessionWorkspace.closeRetries(after: .timedOut("close-workspace")))
        #expect(!AgentSessionWorkspace.closeRetries(after: .command(cmd: "close-workspace", message: "no such workspace", code: "not_found")))
        #expect(!AgentSessionWorkspace.closeRetries(after: .malformedResponse("x")))
    }

    /// After a send the link dropped under, the close waits for the link to connect again, and an
    /// in-place reconnect of the same transport counts (the store's connection epoch moves).
    @Test func aFailedAdoptsCloseWaitsForAReconnectEvenInPlace() {
        #expect(AgentSessionWorkspace.closeMaySend(live: true, epoch: 4, dropped: nil))
        #expect(!AgentSessionWorkspace.closeMaySend(live: false, epoch: 4, dropped: nil))
        // Dropped at epoch 4: still the same link, so no second send yet.
        #expect(!AgentSessionWorkspace.closeMaySend(live: true, epoch: 4, dropped: 4))
        // Disconnected (5), then connected again in place (6).
        #expect(!AgentSessionWorkspace.closeMaySend(live: false, epoch: 5, dropped: 4))
        #expect(AgentSessionWorkspace.closeMaySend(live: true, epoch: 6, dropped: 4))
    }

    /// A failed adopt whose failure is the other machine's link dropping still closes the workspace
    /// it made there: the close waits for the link to come back, never runs on the dead connection.
    @Test func aFailedAdoptsWorkspaceClosesOnceTheMachineReconnects() async throws {
        try await Self.withMachine { _, machine, vmSocket in
            let daemon = machine.daemon
            let connection = try #require(daemon.connection, "the other machine did not connect")
            // The workspace an adopt made there: a terminal, as the adopt's first step leaves it.
            let key = WorkspaceKey.generate()
            _ = try await connection.createWorkspaceRetryingLateReplies(name: "adopt", key: key)
            try await connection.createTerminal(in: key, cwd: nil)

            // The link drops (the adopt's failure), then comes back while the close is under way.
            daemon.shutdownConnection()
            #expect(!daemon.isLive)
            let closing = Task { @MainActor in
                try await AgentSessionWorkspace.closeFailedAdopt(key, on: daemon, present: { true })
            }
            daemon.start(remote: { vmSocket })
            let closeResult = await closing.result
            #expect((try? closeResult.get()) != nil, "the close failed: \(closeResult)")

            let reconnectDeadline = ContinuousClock.now + .seconds(60)
            while !daemon.isLive, ContinuousClock.now < reconnectDeadline { try? await Task.sleep(for: .milliseconds(100)) }
            let live = try #require(daemon.connection, "the other machine did not reconnect")
            await daemon.store.applied(through: await live.eventSequence())
            #expect(!daemon.store.workspaces.contains { $0.key == key }, "the failed adopt's workspace stayed on the other machine")
        }
    }
}

/// The adopt's checks that need no other machine running.
@MainActor @Suite(.serialized)
struct AgentSessionAdoptChecksTests {
    /// A machine whose cmux-tui does not serve the adopt, or cannot batch-close (a failed adopt's
    /// cleanup must take a terminal whose start answer was lost), is refused before anything is made.
    @Test func aMachineThatCannotAdoptOrBatchCloseIsRefusedFirst() {
        #expect(AgentSessionWorkspace.adoptRefusal(supportsAdopt: true, supportsBatchClose: true, machine: "huge-blue") == nil)
        let refusal = AgentRemoteStartRefusal.startUnsupported(machine: "huge-blue").userMessage
        #expect(AgentSessionWorkspace.adoptRefusal(supportsAdopt: false, supportsBatchClose: true, machine: "huge-blue") == refusal)
        #expect(AgentSessionWorkspace.adoptRefusal(supportsAdopt: true, supportsBatchClose: false, machine: "huge-blue") == refusal)
    }

    /// A failed adopt's close ends every terminal the workspace shows, not only the one the adopt
    /// made: a daemon that lost batch close since the adopt's check closes them one by one, and a
    /// terminal whose start answer was lost is in no list of the adopt's.
    @Test func aFailedAdoptsCloseEndsEveryTerminalTheWorkspaceShows() throws {
        let made = TerminalID(rawValue: "made"), late = TerminalID(rawValue: "late")
        let key = WorkspaceKey.generate()
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: key, name: "adopt", screens: [
            ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [
                TabSnapshot(surface: 1, terminalID: made), TabSnapshot(surface: 2, terminalID: late),
                TabSnapshot(surface: 3, kind: .conversation, title: "lane", url: "about:blank"),
            ])]),
        ])]))
        let shown = AgentSessionWorkspace.shownTerminals(of: key, in: store)
        #expect(shown.map(\.id) == [made, late])
        #expect(AgentSessionWorkspace.shownTerminals(of: .generate(), in: store).isEmpty)
        #expect(AgentSessionWorkspace.closeList([(made, nil)], mirrored: shown).map(\.id) == [made, late])
        #expect(AgentSessionWorkspace.closeList([], mirrored: shown).map(\.id) == [made, late], "the lost terminal is not closed")
    }

    /// The adopted chat is the tab's before the store echoes the bind (the adopt answers on a
    /// connection of its own): the page shows it, and its first send starts no new chat on the
    /// bound tab (which the daemon would refuse as `agent_session.bound`).
    @Test func anAdoptedChatIsTheTabsBeforeTheStoreEchoesTheBind() async throws {
        var chat = TabSnapshot(surface: 2, kind: .conversation, title: "lane", url: "about:blank")
        let unbound = AgentSessionRef(host: "registry:huge-blue", hostName: "huge-blue")
        chat.conversation = ConversationTabRef(agentSession: unbound)
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "lane", screens: [
            ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [chat])]),
        ])]))
        let key = try #require(store.tab(surface: 2)?.id)
        let tabs = AgentTabStore(build: nil, registry: ActionRegistry(), environment: [:], showcase: true)
        tabs.lookup = { $0 == key ? (unbound, store) : nil }
        let endpoint: AgentSessionAttachClient.EndpointProvider = { throw DaemonError.notConnected }

        // Without the bind seen, a send would start a chat (here it stops at the missing folder).
        await #expect(throws: AgentRemoteStartRefusal.folderNeeded(machine: "huge-blue")) {
            _ = try await tabs.startRemoteChat(key, machine: "huge-blue", endpoint: endpoint)
        }
        tabs.noteRemoteBound(key, session: "lane-1")
        #expect(tabs.session(of: key) == "lane-1")
        let started = try await tabs.startRemoteChat(key, machine: "huge-blue", endpoint: endpoint)
        #expect(started == AgentTabRemoteStart.Started(surface: 2, session: "lane-1"))
    }
}
