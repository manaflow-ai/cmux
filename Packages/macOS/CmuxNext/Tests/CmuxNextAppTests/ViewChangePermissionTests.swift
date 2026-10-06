import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextDaemon
import Foundation
import Testing

/// plans/cmux-next/OWNERSHIP-PRINCIPLES.md: only a user's run, a run that
/// asks (`focus: true`), or an action whose purpose is focus may change this
/// client's focus, selection, shown workspace or key window. A CLI, script,
/// agent or remote run still does its work (creates, moves) in the
/// background. End to end: the real handlers, a scripted daemon that makes
/// what they ask for, and a window that shows the daemon's workspace.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct ViewChangePermissionTests {
    /// Everything a run may not change, for every window.
    struct View: Equatable {
        var workspaces: [String: String?] = [:]
        var focusedPanes: [String: String?] = [:]
        var selectedTabs: [String: String?] = [:]
        var keyWindow: ObjectIdentifier?
    }

    final class Harness {
        let daemon: TopologyDaemon
        let services: AppServices
        let window: WindowController

        init(daemon: TopologyDaemon, services: AppServices, window: WindowController) {
            self.daemon = daemon
            self.services = services
            self.window = window
        }

        var pane: PaneController? { window.content?.panes.values.first { $0.paneKey == window.focus.state.pane } ?? window.content?.panes.values.first }

        var view: View {
            var view = View(keyWindow: NSApp.keyWindow.map(ObjectIdentifier.init))
            for controller in services.windows.controllers {
                let id = controller.state.id
                view.workspaces[id] = controller.state.workspaceID
                view.focusedPanes[id] = controller.focus.state.pane
                for pane in controller.content?.panes.values ?? [:].values {
                    view.selectedTabs[pane.paneKey] = pane.stripModel.selectedID?.rawValue
                }
            }
            return view
        }

        var tabCount: Int { services.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).count }

        func stop() {
            for controller in services.windows.controllers { controller.window?.close() }
            services.daemon.shutdownConnection()
            daemon.stop()
        }
    }

    /// Waits up to 15 s; a timeout records an Issue at the caller (``waitForCondition``).
    static func waitUntil(_ what: String? = nil, sourceLocation: SourceLocation = #_sourceLocation,
                          _ condition: () -> Bool) async throws {
        try await waitForCondition(what, timeout: .seconds(15), sourceLocation: sourceLocation, condition)
    }

    /// One window showing the daemon's workspace: one pane, tab 11 selected
    /// and focused.
    static func harness(daemon: TopologyDaemon? = nil) async throws -> Harness {
        let daemon = try daemon ?? TopologyDaemon()
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        services.daemon.start(makeConnection: { daemon.connection() })
        try await waitUntil { services.daemon.store.isLoaded && services.daemon.store.workspaces.count == 1 }
        let window = try #require(services.windows.openWindow(workspaces: [TopologyDaemon.firstKey]))
        services.windows.didActivate(window)
        // Installs the store hooks that file new workspaces into windows.
        services.windows.reconcileMembership()
        try await waitUntil { window.content?.panes.values.first?.stripModel.selectedID != nil && window.focus.state.pane != nil }
        let harness = Harness(daemon: daemon, services: services, window: window)
        #expect(harness.pane?.stripModel.selectedID?.rawValue != nil)
        return harness
    }

    /// Runs `id` as `action.run` would, waits for its work and for the
    /// store to mirror what the daemon made.
    static func run(_ harness: Harness, _ id: String, origin: String, focus: Bool = false, target: ActionTargetRef? = nil,
                    arguments: [String: ControlValue] = [:]) async throws {
        let bridge = RegistryControlBridge(registry: harness.services.registry)
        let run = bridge.performActionTracked(ControlActionRequest(
            actionID: id, target: target.map { ControlTargetRef(kind: $0.kind.rawValue, id: $0.id) }, arguments: arguments,
            origin: origin, focus: focus))
        #expect(run.outcome == .ran, "\(id): \(run.outcome)")
        for task in run.work { #expect(await task.value == nil, "\(id)") }
        await harness.services.daemon.store.refresh()
        for _ in 0..<50 { await Task.yield() }
    }

    // MARK: Creating actions from automation change nothing in view

    @Test(arguments: ["cli", "script", "mcp"])
    func aNewTabFromAutomationIsMadeInTheBackground(origin: String) async throws {
        let harness = try await Self.harness()
        defer { harness.stop() }
        let before = harness.view, tabs = harness.tabCount
        try await Self.run(harness, "newSurface", origin: origin)
        #expect(harness.tabCount == tabs + 1)
        try await Self.waitUntil { harness.pane?.stripModel.tabs.count == 3 }
        #expect(harness.view == before)
    }

    @Test func aNewSplitFromTheCLIDoesNotTakeFocus() async throws {
        let harness = try await Self.harness()
        defer { harness.stop() }
        let before = harness.view
        try await Self.run(harness, "splitRight", origin: "cli")
        try await Self.waitUntil { harness.window.content?.panes.count == 2 }
        #expect(harness.window.content?.panes.count == 2)
        var after = harness.view
        after.selectedTabs = after.selectedTabs.filter { before.selectedTabs[$0.key] != nil }
        #expect(after == before)
    }

    @Test func aNewWorkspaceFromTheCLIIsFiledAwayNotShown() async throws {
        let harness = try await Self.harness()
        defer { harness.stop() }
        let before = harness.view
        try await Self.run(harness, "newTab", origin: "cli")
        try await Self.waitUntil { harness.services.windows.registry.members(of: harness.window.state.id).count == 2 }
        #expect(harness.services.daemon.store.workspaces.count == 2)
        #expect(harness.services.windows.registry.members(of: harness.window.state.id).count == 2)
        #expect(harness.view == before)
    }

    @Test func movingATabToANewWorkspaceFromTheCLIKeepsTheView() async throws {
        let harness = try await Self.harness()
        defer { harness.stop() }
        let before = harness.view
        let moved = try #require(harness.services.daemon.store.workspaces.first?.screens.first?.panes.first?.tabs.last)
        try await Self.run(harness, "palette.moveTabToNewWorkspace", origin: "cli", target: ActionTargetRef(kind: .tab, id: moved.id))
        try await Self.waitUntil { harness.services.daemon.store.workspaces.count == 2 && harness.pane?.stripModel.tabs.count == 1 }
        #expect(harness.services.daemon.store.workspaces.count == 2)
        var after = harness.view
        after.selectedTabs = after.selectedTabs.filter { before.selectedTabs[$0.key] != nil }
        #expect(after.workspaces == before.workspaces)
        #expect(after.focusedPanes == before.focusedPanes)
    }

    @Test func aBrowserOpenedFromTheCLIIsNotSelected() async throws {
        let harness = try await Self.harness()
        defer { harness.stop() }
        let before = harness.view
        let pane = try #require(harness.pane)
        try await Self.run(harness, "openBrowser", origin: "cli", arguments: ["url": .string("https://example.com")])
        #expect(harness.window.state.localBrowserTabs[pane.paneKey]?.count == 1)
        #expect(harness.view == before)
    }

    // MARK: Asked, by purpose, or the user's

    @Test func aNewTabFromTheCLIWithFocusIsSelected() async throws {
        let harness = try await Self.harness()
        defer { harness.stop() }
        let before = harness.pane?.stripModel.selectedID
        try await Self.run(harness, "newSurface", origin: "cli", focus: true)
        try await Self.waitUntil { harness.pane?.stripModel.selectedID != before }
        #expect(harness.pane?.stripModel.selectedID != before)
    }

    @Test func aNewWorkspaceFromTheCLIWithFocusIsShown() async throws {
        let harness = try await Self.harness()
        defer { harness.stop() }
        try await Self.run(harness, "newTab", origin: "cli", focus: true)
        try await Self.waitUntil { harness.window.state.workspaceID != TopologyDaemon.firstKey }
        #expect(harness.window.state.workspaceID != TopologyDaemon.firstKey)
    }

    @Test func aSplitByTheUserFocusesTheNewPane() async throws {
        let harness = try await Self.harness()
        defer { harness.stop() }
        let before = harness.window.focus.state.pane
        try await Self.run(harness, "splitRight", origin: "user")
        try await Self.waitUntil { harness.window.content?.panes.count == 2 && harness.window.focus.state.pane != before }
        #expect(harness.window.focus.state.pane != before)
    }

    @Test func aBrowserOpenedByTheUserIsSelected() async throws {
        let harness = try await Self.harness()
        defer { harness.stop() }
        let before = harness.pane?.stripModel.selectedID
        try await Self.run(harness, "openBrowser", origin: "user", arguments: ["url": .string("https://example.com")])
        try await Self.waitUntil { harness.pane?.stripModel.selectedID != before }
        #expect(harness.pane?.stripModel.selectedID?.rawValue.hasPrefix(LocalBrowserTab.prefix) == true)
    }

    @Test func tabFocusFocusesFromTheCLIByPurpose() async throws {
        let harness = try await Self.harness()
        defer { harness.stop() }
        let pane = try #require(harness.pane)
        let other = try #require(pane.stripModel.orderedTabs.map(\.id).first { $0 != pane.stripModel.selectedID })
        try await Self.run(harness, "tab.focus", origin: "cli", target: ActionTargetRef(kind: .tab, id: other.rawValue))
        try await Self.waitUntil { pane.stripModel.selectedID == other }
        #expect(pane.stripModel.selectedID == other)
    }

    // MARK: The permission travels with the run

    /// A handler that selects a tab after awaiting a daemon reply: the
    /// continuation keeps its run's permission (the CLI's: none; the CLI's
    /// with `focus: true`: yes), whatever runs in between.
    @Test func anAsyncContinuationKeepsItsRunsPermission() async throws {
        let harness = try await Self.harness()
        defer { harness.stop() }
        let services = harness.services
        services.registry.register(Action(id: "test.selectAfterReply", title: "Select After Reply") { [weak harness] in
            guard let harness, let pane = harness.pane else { return }
            let other = pane.stripModel.orderedTabs.map(\.id).first { $0 != pane.stripModel.selectedID }
            services.registry.track(Task {
                await services.daemon.store.refresh()
                if let other { pane.select(other) }
                return nil
            })
        })
        let first = harness.pane?.stripModel.selectedID
        try await Self.run(harness, "test.selectAfterReply", origin: "cli")
        #expect(harness.pane?.stripModel.selectedID == first)
        try await Self.run(harness, "test.selectAfterReply", origin: "cli", focus: true)
        try await Self.waitUntil { harness.pane?.stripModel.selectedID != first }
        #expect(harness.pane?.stripModel.selectedID != first)
    }
}
