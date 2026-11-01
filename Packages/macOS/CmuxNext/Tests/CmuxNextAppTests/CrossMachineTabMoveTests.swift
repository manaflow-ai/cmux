import AppKit
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextDaemon
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

    // MARK: The harness

    @MainActor
    final class World {
        let services: AppServices
        let machine: CloudMachineSession
        let macConnection: DaemonConnection
        let macPane: PaneModel
        let target: WorkspaceModel

        init(services: AppServices, machine: CloudMachineSession, macConnection: DaemonConnection, macPane: PaneModel, target: WorkspaceModel) {
            self.services = services
            self.machine = machine
            self.macConnection = macConnection
            self.macPane = macPane
            self.target = target
        }

        /// Moves `tab` to the other machine's workspace as the tab menu and a drag do; whether it moved.
        func move(_ tab: TabModel) async -> Bool {
            await withCheckedContinuation { continuation in
                TabMoves.toWorkspace(tab, workspace: target, services: services) { continuation.resume(returning: $0) }
            }
        }

        /// This Mac's tab matching `match`, once the store shows it.
        func macTab(_ match: (TabModel) -> Bool) async throws -> TabModel {
            try await poll("this Mac's tab did not appear") { self.services.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first(where: match) }
        }

        /// The other machine's tab matching `match` in the target workspace, once its store shows it.
        func machineTab(_ match: (TabModel) -> Bool) async throws -> TabModel {
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

        /// Whether this Mac's tab `id` is gone (waits up to 20 s).
        func macTabGone(_ id: String) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(20)
            func present() -> Bool { services.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).contains { $0.id == id } }
            while present(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            return !present()
        }

        private func poll<T>(_ message: String, until deadline: ContinuousClock.Instant = ContinuousClock.now + .seconds(20), _ value: () -> T?) async throws -> T {
            try Task.checkCancellation()
            while value() == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
            try Task.checkCancellation()
            return try #require(value(), Comment(rawValue: message))
        }
    }

    /// Runs `body` with this Mac's daemon (a workspace with a pane) and another machine's daemon
    /// with a workspace of its own, both connected to one app (StashTests reuses it).
    static func withMachines(_ body: (World) async throws -> Void) async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = URL(fileURLWithPath: "/private/tmp/cn-xmove-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        var reaped = false
        defer { if reaped { try? FileManager.default.removeItem(at: root) } }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let environment: @Sendable () -> [String: String] = {
            ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"]
        }
        let mac = DaemonLauncher(configuration: .init(binary: binary, session: "cn-xmove-mac-\(UUID().uuidString.prefix(6).lowercased())",
                                                      stateDirectory: root.appendingPathComponent("mac-state"), exitWithProcess: ProcessInfo.processInfo.processIdentifier), environment: environment)
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
            try await body(World(services: services, machine: machine, macConnection: macConnection, macPane: pane, target: workspace))
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
