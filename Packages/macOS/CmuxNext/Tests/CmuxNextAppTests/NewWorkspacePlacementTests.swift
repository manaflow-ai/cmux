import AppKit
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp

/// `workspaces.newPlacement` end to end (cx-plf5, Lawrence 2026-10-08: "new
/// workspace should default go to the top ... cmd n go to top"): Cmd-N (the
/// `newTab` action a person runs) and `cmux workspace new` (the same action
/// from the CLI, which shows nothing) make the workspace, and once the
/// daemon reports it the app writes its place into the daemon's order, the
/// order a relaunched app reads back. Windows are never put on screen.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct NewWorkspacePlacementTests {
    static let second = "2a4f6c1e-8b3d-4e5f-9a7b-1c2d3e4f5a02"
    static let third = "2a4f6c1e-8b3d-4e5f-9a7b-1c2d3e4f5a03"
    static let listed = [TopologyDaemon.firstKey, second, third]

    private struct Fixture {
        let daemon: TopologyDaemon
        let services: AppServices
        let window: WindowController

        /// The daemon's durable workspace order, by key.
        var order: [String] { daemon.state.tree.withLock { $0.workspaces.map(\.key) } }

        func stop() {
            for controller in services.windows.controllers { controller.window?.close() }
            services.daemon.shutdownConnection()
            daemon.stop()
        }
    }

    private static func waitUntil(_ what: String, sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        try await waitForCondition(what, timeout: .seconds(15), sourceLocation: sourceLocation, condition)
    }

    /// Bound services whose cmux.json sets `workspaces.newPlacement` (nil:
    /// no key, the default).
    private static func services(_ placement: NewWorkspacePlacement?) async throws -> AppServices {
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-newplacement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        let json = placement.map { #"{"workspaces": {"newPlacement": "\#($0.rawValue)"}}"# } ?? "{}"
        try Data(json.utf8).write(to: url)
        let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(.empty), managedWatchFiles: [])
        services.settings = settings
        await settings.reload()
        return services
    }

    /// Three workspaces in one window, which shows the second.
    private func start(_ placement: NewWorkspacePlacement?) async throws -> Fixture {
        let daemon = try TopologyDaemon()
        daemon.state.tree.withLock { tree in
            for (offset, key) in [Self.second, Self.third].enumerated() {
                let base = 40 + offset * 10
                tree.workspaces.append(TopologyDaemon.Workspace(id: base, key: key, screens: [
                    TopologyDaemon.Screen(id: base + 1, layout: .leaf(base + 2), panes: [TopologyDaemon.Pane(id: base + 2, tabs: [base + 3])]),
                ]))
            }
        }
        let services = try await Self.services(placement)
        services.daemon.start(makeConnection: { daemon.connection() })
        try await Self.waitUntil("the daemon's workspaces are mirrored") {
            services.daemon.store.isLoaded && services.daemon.store.workspaces.count == 3
        }
        let window = try #require(services.windows.openWindow(workspaces: Self.listed))
        services.windows.didActivate(window)
        services.windows.reconcileMembership()
        services.windows.show(workspaceID: Self.second, in: window.state)
        try await Self.waitUntil("the window lists every workspace and shows the second") {
            window.sidebar.model.allWorkspaces.count == 3 && window.state.workspaceID == Self.second
        }
        return Fixture(daemon: daemon, services: services, window: window)
    }

    private func run(_ fixture: Fixture, origin: String, focus: Bool) {
        let run = RegistryControlBridge(registry: fixture.services.registry).performActionTracked(ControlActionRequest(
            actionID: "newTab", origin: origin, focus: focus
        ))
        #expect(run.outcome == .ran, "New Workspace: \(run.outcome)")
    }

    /// The key of the workspace the action made, once the daemon has it.
    private func created(_ fixture: Fixture) async throws -> String {
        try await Self.waitUntil("the new workspace is created") { fixture.order.count == 4 }
        return try #require(fixture.order.first { !Self.listed.contains($0) })
    }

    @Test func cmdNPutsTheNewWorkspaceAtTheTopByDefault() async throws {
        let fixture = try await start(nil)
        defer { fixture.stop() }
        run(fixture, origin: "user", focus: true)
        let new = try await created(fixture)
        try await Self.waitUntil("the new workspace moves to the top") { fixture.order.first == new }
        #expect(fixture.order == [new] + Self.listed)
    }

    @Test func cmdNWithAfterCurrentPutsItAfterTheShownWorkspace() async throws {
        let fixture = try await start(.afterCurrent)
        defer { fixture.stop() }
        run(fixture, origin: "user", focus: true)
        let new = try await created(fixture)
        try await Self.waitUntil("the new workspace moves after the second") { fixture.order.dropFirst(2).first == new }
        #expect(fixture.order == [TopologyDaemon.firstKey, Self.second, new, Self.third])
    }

    @Test func cmdNWithBottomLeavesItLast() async throws {
        let fixture = try await start(.bottom)
        defer { fixture.stop() }
        run(fixture, origin: "user", focus: true)
        let new = try await created(fixture)
        try await Self.waitUntil("the window lists the new workspace") {
            fixture.window.sidebar.model.allWorkspaces.contains { $0.id.rawValue == new }
        }
        #expect(fixture.order == Self.listed + [new])
        #expect(!fixture.daemon.commands.names.withLock { $0.contains("move-workspace") })
    }

    /// `cmux workspace new`: the CLI's run shows nothing, and the most
    /// recent window, which lists it, still puts it at the top.
    @Test func theCLIsNewWorkspaceGoesToTheTopToo() async throws {
        let fixture = try await start(nil)
        defer { fixture.stop() }
        run(fixture, origin: "cli", focus: false)
        let new = try await created(fixture)
        try await Self.waitUntil("the new workspace moves to the top") { fixture.order.first == new }
        #expect(fixture.window.state.workspaceID == Self.second, "the CLI's run does not switch the window")
    }

    /// An explicit place wins over the setting: New Workspace at Bottom.
    @Test func anExplicitSlotWinsOverTheSetting() async throws {
        let fixture = try await start(nil)
        defer { fixture.stop() }
        let run = RegistryControlBridge(registry: fixture.services.registry).performActionTracked(ControlActionRequest(
            actionID: "workspace.newAtBottom", target: ControlTargetRef(kind: "workspace", id: Self.second), origin: "user", focus: true
        ))
        #expect(run.outcome == .ran, "New Workspace at Bottom: \(run.outcome)")
        let new = try await created(fixture)
        try await Self.waitUntil("the window lists the new workspace") {
            fixture.window.sidebar.model.allWorkspaces.contains { $0.id.rawValue == new }
        }
        #expect(fixture.order == Self.listed + [new])
    }

    /// The place is the daemon's, not the window's: a new app on the same
    /// daemon (a relaunch) lists the workspace at the top.
    @Test func theTopPlaceSurvivesARelaunch() async throws {
        let fixture = try await start(nil)
        defer { fixture.stop() }
        run(fixture, origin: "user", focus: true)
        let new = try await created(fixture)
        try await Self.waitUntil("the new workspace moves to the top") { fixture.order.first == new }

        let relaunched = try await Self.services(nil)
        relaunched.daemon.start(makeConnection: { fixture.daemon.connection() })
        defer { relaunched.daemon.shutdownConnection() }
        try await Self.waitUntil("the relaunched app mirrors the daemon") {
            relaunched.daemon.store.isLoaded && relaunched.daemon.store.workspaces.count == 4
        }
        #expect(relaunched.daemon.store.workspaces.compactMap(\.key?.rawValue) == [new] + Self.listed)
    }
}
