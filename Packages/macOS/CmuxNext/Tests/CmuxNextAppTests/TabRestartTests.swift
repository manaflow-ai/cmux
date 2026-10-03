import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// `tab.restart` (plans/cmux-next/ownership.md 3.2): which tabs offer it,
/// the idempotency key every client derives from the dead terminal, the
/// automatic restart's candidates, and the action's gate on the daemon's
/// `tab-restart-v1`.
@MainActor
@Suite struct TabRestartTests {
    static let workspaceKey = "0b8a2f1e-5a51-4c55-9f0e-6e2f6a4f9c11"

    static func services(_ tabs: [TabSnapshot]) -> AppServices {
        let services = ActionBindingCoverageTests.boundServices()
        let pane = PaneSnapshot(id: 3, tabs: tabs)
        let workspace = WorkspaceSnapshot(id: 1, key: WorkspaceKey(rawValue: workspaceKey), name: "w",
                                          screens: [ScreenSnapshot(id: 4, layout: .leaf(3), panes: [pane])])
        services.daemon.store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [workspace]))
        return services
    }

    static var mixedTabs: [TabSnapshot] {
        var kept = TabSnapshot(surface: 8, tabResourceID: "tab_kept", terminalResourceID: "term_kept", dead: true)
        kept.relaunch = TabRelaunch(cwd: "/tmp")
        return [
            TabSnapshot(surface: 5, tabResourceID: "tab_dead", terminalResourceID: "term_dead", dead: true, cwd: "/src"),
            TabSnapshot(surface: 6, tabResourceID: "tab_live", terminalResourceID: "term_live"),
            TabSnapshot(surface: 7, tabResourceID: "tab_page", kind: .browser, dead: true),
            kept,
        ]
    }

    @Test func onlyADeadLocalTerminalTabRestarts() throws {
        let store = Self.services(Self.mixedTabs).daemon.store
        #expect(TabRestart.isRestartable(try #require(store.tab(surface: 5))))
        #expect(TabRestart.isRestartable(try #require(store.tab(surface: 8))))
        #expect(!TabRestart.isRestartable(try #require(store.tab(surface: 6))))
        #expect(!TabRestart.isRestartable(try #require(store.tab(surface: 7))))
    }

    /// Two clients derive the same key for one dead terminal; once the tab
    /// shows a new terminal that dies too, the key is new.
    @Test func theKeyNamesTheDeadTerminalAndChangesWithIt() throws {
        let services = Self.services(Self.mixedTabs)
        let tab = try #require(services.daemon.store.tab(surface: 5))
        #expect(TabRestart.idempotencyKey(tab) == "tab-restart:tab_dead:term_dead")
        let restarted = TabSnapshot(surface: 5, tabResourceID: "tab_dead", terminalResourceID: "term_next", dead: true)
        let pane = PaneSnapshot(id: 3, tabs: [restarted])
        services.daemon.store.apply(snapshot: DaemonTree(workspaceRevision: 2, workspaces: [
            WorkspaceSnapshot(id: 1, key: WorkspaceKey(rawValue: Self.workspaceKey), name: "w",
                              screens: [ScreenSnapshot(id: 4, layout: .leaf(3), panes: [pane])]),
        ]))
        let next = try #require(services.daemon.store.tab(surface: 5))
        #expect(next === tab, "the tab keeps its record across the restart")
        #expect(TabRestart.idempotencyKey(next) == "tab-restart:tab_dead:term_next")
    }

    /// The automatic restart tries dead terminal tabs only, leaves kept
    /// tabs to the kept-layout relaunch, and does nothing while the setting
    /// is off or no connected daemon serves the capability.
    @Test func automaticRestartCandidates() {
        let services = Self.services(Self.mixedTabs)
        let tabs = services.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
        let candidates = LostTerminalRestarter.candidates(machine: "local", tabs: tabs)
        #expect(candidates == [LostTerminalRestarter.Candidate(machine: "local", surface: 5, key: "tab-restart:tab_dead:term_dead", cwd: "/src")])
        #expect(LostTerminalRestarter.candidates(enabled: false, daemons: services.machines.daemons).isEmpty)
        // Not connected (and no tab-restart-v1): nothing to send.
        #expect(LostTerminalRestarter.candidates(enabled: true, daemons: services.machines.daemons).isEmpty)
    }

    @Test func theActionNeedsTheDaemonCapability() {
        let services = Self.services(Self.mixedTabs)
        #expect(services.registry.unavailableReason(for: TabRestart.action) != nil)
        let descriptor = services.registry.descriptor(for: TabRestart.action)
        #expect(descriptor?.cliName == "tab restart")
        #expect(descriptor?.targets == [.tab])
    }
}
