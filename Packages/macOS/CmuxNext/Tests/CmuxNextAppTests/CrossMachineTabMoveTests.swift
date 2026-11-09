import AppKit
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextSettings
@testable import CmuxNextDaemon
import Foundation
import Testing

/// A browser, agent chat or page tab moved to a workspace on another machine (unimplemented audit
/// row 11): it reopens there on the same page (browser: same URL and profile; chat: the same
/// session; page: the same page and route) and the original closes, as a terminal moves by
/// reference. It was refused ("Browser tabs cannot move to a workspace on another machine yet.").
/// This Mac is a real cmux-tui daemon; the other machine is a second real daemon reached as the app
/// reaches a machine's link socket (`DaemonService.start(remote:)`), as in ``CloudMoveTests``.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CrossMachineTabMoveTests {
    @Test func aBrowserTabReopensOnTheOtherMachineOnTheSamePage() async throws {
        try await Self.withMachines { world in
            let browserTabs = world.services.cache.browserTabs
            guard case .open(let choice) = browserTabs.resolve(requested: "webkit") else {
                Issue.record("no WebKit engine choice")
                return
            }
            let url = "https://example.com/moved?q=1"
            let surface = try await browserTabs.open(choice, in: world.macPane, url: url, profile: nil)
            let tab = try await world.macTab { $0.surface == surface }
            let moved = await world.move(tab)
            #expect(moved, "the move was refused")
            let landed = try await world.machineTab { $0.kind == .browser && $0.url == url }
            #expect(landed.browserEngine == tab.browserEngine, "the tab changed engine: \(String(describing: landed.browserEngine))")
            #expect(await world.macTabGone(tab.id), "this Mac's tab stayed after the move")
        }
    }

    @Test func anAgentChatTabReopensOnTheOtherMachineOnTheSameSession() async throws {
        try await Self.withMachines { world in
            let record = AgentSessionRef(host: AgentSessionRef.host(installID: "cn-xmove-test"), hostName: "This Mac", session: "chat-live", harness: "claude")
            let created = try await world.macConnection.request(NewConversationTabRequest(agentSession: record, pane: world.macPane.handle))
            let tab = try await world.macTab { $0.surface == created.surface }
            let moved = await world.move(tab)
            #expect(moved, "the move was refused")
            let landed = try await world.machineTab { $0.agentSession != nil }
            #expect(landed.agentSession == record, "the chat lost its session: \(String(describing: landed.agentSession))")
            #expect(await world.macTabGone(tab.id), "this Mac's chat tab stayed after the move")
        }
    }

    @Test func aPageTabReopensOnTheOtherMachineOnTheSamePage() async throws {
        try await Self.withMachines { world in
            let created = try await world.macConnection.request(NewConversationTabRequest(page: "settings", route: "appearance", pane: world.macPane.handle))
            let tab = try await world.macTab { $0.surface == created.surface }
            let moved = await world.move(tab)
            #expect(moved, "the move was refused")
            let landed = try await world.machineTab { $0.page != nil }
            #expect(landed.page == "settings" && landed.pageRoute == "appearance", "\(String(describing: landed.page)) \(String(describing: landed.pageRoute))")
            #expect(await world.macTabGone(tab.id), "this Mac's page tab stayed after the move")
        }
    }

    /// A terminal still moves by reference (the shared landing step): the other machine shows a
    /// remote-terminal tab on this Mac's terminal, with its name, and this Mac's tab closes.
    @Test func aTerminalTabStillMovesByReference() async throws {
        try await Self.withMachines { world in
            let created = try await world.macConnection.newTab(in: world.macPane.handle)
            try await world.macConnection.renameTab(created.surface, to: "build")
            let tab = try await world.macTab { $0.surface == created.surface && $0.kind == .pty && $0.terminalID != nil && $0.name == "build" }
            let terminal = try #require(tab.terminalID)
            let moved = await world.move(tab)
            #expect(moved, "the terminal did not move")
            let landed = try await world.machineTab { $0.kind == .remoteTerminal }
            #expect(landed.remote?.terminalID == terminal, "the reference names another terminal")
            #expect(landed.name == "build", "the tab's name did not come along: \(String(describing: landed.name))")
            #expect(await world.macTabGone(tab.id), "this Mac's terminal tab stayed after the move")
        }
    }

    /// A terminal whose keep fails does not move: closing this Mac's tab would leave the terminal
    /// with no tab on a daemon that reaps tabless terminals, and it would end after the grace while
    /// the other machine still shows it. The move fails and this Mac's tab stays. The keep fails
    /// here because the tab names a terminal the daemon does not have (`terminal_not_found`).
    @Test func aTerminalWhoseKeepFailsDoesNotMove() async throws {
        try await Self.withMachines { world in
            let created = try await world.macConnection.newTab(in: world.macPane.handle)
            let tab = try await world.macTab { $0.surface == created.surface && $0.kind == .pty && $0.terminalID != nil }
            tab.terminalID = TerminalID.generate()
            let moved = await world.move(tab)
            #expect(!moved, "the terminal moved although its keep failed")
            // Read once the store applied every event before the move's last reply, so a close the
            // daemon already committed shows.
            #expect(await world.services.daemon.appliedThroughReply(on: world.macConnection, after: "move"))
            #expect(world.services.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).contains { $0.id == tab.id },
                    "this Mac's terminal tab closed although its keep failed")
            // The other machine's new tab closed again with the failed keep.
            let vmConnection = try #require(world.machine.daemon.connection)
            #expect(await world.machine.daemon.appliedThroughReply(on: vmConnection, after: "move"))
            let target = world.target
            #expect(!target.screens.flatMap(\.panes).flatMap(\.tabs).contains { $0.kind == .remoteTerminal },
                    "the other machine kept a tab for a terminal whose keep failed")
        }
    }

    /// A terminal whose new tab on the other machine fails to open is not left kept: the keep comes
    /// after the new tab, so once its last tab here closes this Mac's owner reaps it (grace 1 s). A
    /// keep made first and left behind kept the shell running with no tab anywhere.
    @Test func aTerminalWhoseNewTabFailsIsNotLeftKept() async throws {
        try await Self.withMachines(macReapGraceSeconds: 1) { world in
            let created = try await world.macConnection.newTab(in: world.macPane.handle)
            let tab = try await world.macTab { $0.surface == created.surface && $0.kind == .pty && $0.terminalID != nil }
            let terminal = try #require(tab.terminalID)
            let host = try #require(TerminalHostExit.hostPID(of: terminal, state: world.macState), "no host record for the terminal")
            // The other machine's pane, as this app last saw it, is gone there: its new tab fails.
            for pane in world.target.screens.flatMap(\.panes) { pane.handle = PaneID(rawValue: 1 << 40) }
            let moved = await world.move(tab)
            #expect(!moved, "the terminal moved although the other machine could not open its tab")
            try await world.macConnection.closeTab(created.surface)
            #expect(await TerminalHostExit.exits(host, within: .seconds(20)), "the shell outlived its last tab: the failed move left it kept")
        }
    }

    /// A tab whose original cannot close (the first tab of a pinned column, which the daemon keeps)
    /// still moves from the menu, keyboard or a drag: the other machine shows it, the move reports
    /// success, the original stays beside it, and the person sees one notice that says so. The
    /// notice was returned as the run's failure, which such a run never shows.
    @Test func aTabWhoseOriginalCannotCloseStillMoves() async throws {
        try await Self.withMachines { world in
            let tab = try await world.pinnedFirstTab()
            let shown = world.notices()
            let moved = await world.move(tab)
            #expect(moved, "the tab opened on the other machine, yet the move reported a failure")
            let landed = try await world.machineTab { $0.kind == .remoteTerminal }
            #expect(landed.remote?.terminalID == tab.terminalID, "the other machine's tab names another terminal")
            #expect(world.services.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).contains { $0.id == tab.id },
                    "the pinned original closed")
            #expect(world.notices() == shown + 1, "the original-stayed notice showed \(world.notices() - shown) times")
        }
    }

    /// The same move from the CLI (`cmux tab move-to-workspace`) answers success: the tab
    /// landed, so a script must not retry it (a retry made a second tab there). The person still
    /// sees the one notice. It answered an error for a move that landed.
    @Test func aCLIMoveWhoseOriginalCannotCloseAnswersSuccess() async throws {
        try await Self.withMachines { world in
            let tab = try await world.pinnedFirstTab()
            let shown = world.notices()
            let error = await CloudCLIActionRun(services: world.services)([
                "action": .string("tab move-to-workspace"), "cli": .bool(true), "origin": .string("cli"), "wait": .bool(true),
                "target": .string("tab:" + tab.id), "args": .object(["workspace": .string("workspace:" + world.target.id)]),
            ])
            #expect(error == nil, "the CLI got an error for a move that landed: \(String(describing: error))")
            let landed = try await world.machineTab { $0.kind == .remoteTerminal }
            #expect(landed.remote?.terminalID == tab.terminalID, "the other machine's tab names another terminal")
            #expect(world.notices() == shown + 1, "the original-stayed notice showed \(world.notices() - shown) times")
        }
    }

    // MARK: The harness

    @MainActor
    final class World {
        let services: AppServices
        let machine: CloudMachineSession
        let macConnection: DaemonConnection
        let macPane: PaneModel
        let target: WorkspaceModel
        /// This Mac's owner's state directory (its terminal host records, ``TerminalHostExit``).
        let macState: URL

        init(services: AppServices, machine: CloudMachineSession, macConnection: DaemonConnection, macPane: PaneModel, target: WorkspaceModel,
             macState: URL) {
            self.services = services
            self.machine = machine
            self.macConnection = macConnection
            self.macPane = macPane
            self.target = target
            self.macState = macState
        }

        /// A new terminal tab here, made the first tab of a pinned column, so the daemon refuses to close it.
        func pinnedFirstTab() async throws -> TabModel {
            let surface = try await macConnection.newTab(in: macPane.handle).surface
            let tab = try await macTab { $0.surface == surface && $0.kind == .pty && $0.terminalID != nil }
            // Another column scrolls, so this pane's column can be the pinned one, with this tab first.
            _ = try await macConnection.newColumn(rightOf: macPane.handle)
            _ = try await macConnection.moveTab(surface, to: macPane.handle, index: 0)
            _ = try await macConnection.request(SetColumnDockRequest(pane: macPane.handle, dock: DockSnapshot(edge: .left, mode: .docked), pinned: true))
            await #expect(throws: (any Error).self, "the pinned column's first tab closed") { try await self.macConnection.closeTab(surface) }
            return tab
        }

        /// How many original-stayed notices the app showed so far.
        func notices() -> Int { services.refusalHUD.history.filter { $0 == RemoteStrings.originalTabStayed }.count }

        /// Moves `tab` to the other machine's workspace as the tab menu and a drag do; whether it moved.
        func move(_ tab: TabModel) async -> Bool {
            await withCheckedContinuation { continuation in
                TabMoves.toWorkspace(tab, workspace: target, services: services) { continuation.resume(returning: $0) }
            }
        }

        /// This Mac's tab matching `match`, once the store shows it.
        func macTab(_ match: @escaping @MainActor @Sendable (TabModel) -> Bool) async throws -> TabModel {
            try await poll("this Mac's tab did not appear") { self.services.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first(where: match) }
        }

        /// The other machine's tab matching `match` in the target workspace, once its store shows it.
        func machineTab(_ match: @escaping @MainActor @Sendable (TabModel) -> Bool) async throws -> TabModel {
            let deadline = ContinuousClock.now + .seconds(20)
            // A move's reply can precede the store applying its rename. Read after the
            // daemon's barrier so the creation event alone cannot satisfy this lookup.
            // The barrier and lookup share one deadline. Leaving the group cancels and
            // joins the observation wait or deadline task, including on caller cancellation.
            let daemon = self.machine.daemon
            try await withThrowingTaskGroup(of: Void.self) { group in
                defer { group.cancelAll() }
                group.addTask {
                    try Task.checkCancellation()
                    try await daemon.appliedThroughSyncBarrier()
                    try Task.checkCancellation()
                }
                group.addTask {
                    try await ContinuousClock().sleep(until: deadline)
                    throw DaemonError.timedOut("the other machine's store did not reach the move's reply")
                }
                _ = try await group.next()
            }
            return try await poll("no matching tab on the other machine", until: deadline) {
                self.machine.daemon.store.workspaces.first { $0.id == self.target.id }?.screens.flatMap(\.panes).flatMap(\.tabs).first(where: match)
            }
        }

        /// Whether this Mac's tab `id` is gone (waits up to 20 s for the store to drop it).
        func macTabGone(_ id: String) async -> Bool {
            let services = services
            let gone = await CrossMachineTabMoveTests.observed(until: ContinuousClock.now + .seconds(20)) {
                services.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).contains { $0.id == id } ? nil : true
            }
            return gone == true
        }

        private func poll<T: Sendable>(_ message: String, until deadline: ContinuousClock.Instant = ContinuousClock.now + .seconds(20),
                                       _ value: @escaping @MainActor @Sendable () -> T?) async throws -> T {
            try #require(await CrossMachineTabMoveTests.observed(until: deadline, value), Comment(rawValue: message))
        }
    }

    /// The first non-nil value of `value`, read again after each change of the observable state it
    /// reads (``ObservationStream``), or nil once `deadline` passes: a store change is the signal,
    /// and the deadline only bounds a value that never comes.
    static func observed<T: Sendable>(until deadline: ContinuousClock.Instant,
                                      _ value: @escaping @MainActor @Sendable () -> T?) async -> T? {
        // task-owner: the wait is joined below and cancelled by the deadline or the caller's cancellation.
        let watch = Task { @MainActor () -> T? in
            for await current in ObservationStream(value) where current != nil { return current }
            return nil
        }
        // A deadline, not a poll: it ends the wait for a value that never comes.
        let bound = Task { try? await ContinuousClock().sleep(until: deadline); watch.cancel() }
        defer { bound.cancel() }
        return await withTaskCancellationHandler { await watch.value } onCancel: { watch.cancel() }
    }

    /// Runs `body` with this Mac's daemon (a workspace with a pane) and another machine's daemon
    /// with a workspace of its own, both connected to one app (StashTests reuses it).
    /// `macReapGraceSeconds` is this Mac's owner's reap grace (the app's 30 s by default).
    static func withMachines(macReapGraceSeconds: UInt32 = 30, _ body: (World) async throws -> Void) async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = URL(fileURLWithPath: "/private/tmp/cn-xmove-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        var reaped = false
        defer { if reaped { try? FileManager.default.removeItem(at: root) } }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let environment: @Sendable () -> [String: String] = {
            ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"]
        }
        let mac = DaemonLauncher(configuration: .init(binary: binary, session: "cn-xmove-mac-\(UUID().uuidString.prefix(6).lowercased())",
                                                      stateDirectory: root.appendingPathComponent("mac-state"), terminalReapGraceSeconds: macReapGraceSeconds, exitWithProcess: ProcessInfo.processInfo.processIdentifier), environment: environment)
        let vm = DaemonLauncher(configuration: .init(binary: binary, session: "cn-xmove-vm-\(UUID().uuidString.prefix(6).lowercased())",
                                                     stateDirectory: root.appendingPathComponent("vm-state"), exitWithProcess: ProcessInfo.processInfo.processIdentifier), environment: environment)
        let macOwner = AppTestDaemonOwner(mac)
        let vmOwner = AppTestDaemonOwner(vm)
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let machine = CloudMoveTests.machine(services, cli: URL(fileURLWithPath: "/usr/bin/false"), root: root)
        services.machines.add(machine)
        defer {
            for controller in services.windows.controllers { controller.window?.close() }
            for key in Array(services.cache.browsers.keys) { services.cache.release(key) }
            let panels = NSApp.windows.filter { services.palette.owns($0) }
            services.palette.hide()
            for panel in panels { panel.close() }
            AppHarnessWindows.closeThoseThisTestOpened()
        }

        let result: Result<Void, any Error>
        do {
            let vmSocket = try await vmOwner.endpointProvider().socketPath
            try Task.checkCancellation()
            services.daemon.start {
                DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: macOwner.endpointProvider)
            }
            services.windows.restoreWhenLoaded()
            machine.daemon.start(remote: { vmSocket })
            let deadline = ContinuousClock.now + .seconds(60)
            func macPane() -> PaneModel? { services.daemon.store.workspaces.first?.screens.first?.panes.first }
            while macPane() == nil || machine.daemon.connection == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
            let pane = try #require(macPane(), "this Mac's daemon has no pane")
            let macConnection = try #require(services.daemon.connection)
            let vmConnection = try #require(machine.daemon.connection, "the other machine did not connect")
            // A workspace with its terminal (so a pane), as a person's new workspace on that machine.
            let created = try await vmConnection.state.createWorkspace(name: "There", ephemeral: false, terminal: true, focus: false)
            func target() -> WorkspaceModel? {
                machine.daemon.store.workspaces.first { $0.resourceID == created.workspaceID && $0.screens.contains { !$0.panes.isEmpty } }
            }
            while target() == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
            let workspace = try #require(target(), "the other machine's workspace has no pane")
            try await body(World(services: services, machine: machine, macConnection: macConnection, macPane: pane, target: workspace,
                                 macState: root.appendingPathComponent("mac-state")))
            result = .success(())
        } catch {
            result = .failure(error)
        }
        // task-owner: joined teardown survives cancellation, stops both reconnect loops before
        // closing windows, and reaps each owner even when startup never exposed a connection.
        reaped = await Task { @MainActor in
            await machine.daemon.shutdownConnectionAndWait()
            let macReaped = await macOwner.stop(services)
            let vmReaped = await vmOwner.reap()
            return macReaped && vmReaped
        }.value
        try result.get()
    }
}
