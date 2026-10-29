import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextTerminal
import Foundation
import Testing

/// The daemon's tab of a New Terminal Tab (Ctrl-`) adopts its stand-in's terminal: the same entry, view, session and
/// input lane (review of 107f5da1ac6). Keys typed into the stand-in go to the daemon by its terminal id; a new view
/// for the daemon's tab closed the stand-in's lane with keys still in it, or sent its keys after the new view's.
@MainActor @Suite(.serialized)
struct StandInTerminalAdoptionTests {
    @Test func theDaemonsTabKeepsTheStandInsTerminal() throws {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let services = AppServices(environment: AppEnvironment.current([:]))
        let terminal = TerminalID.generate()
        let standIn = TabModel(ProvisionalTab().terminal(terminal, cwd: nil))
        let entry = services.cache.terminal(for: standIn, daemon: services.daemon)
        #expect(entry.gate != nil, "the stand-in's terminal attached before the daemon made it")

        let made = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 42), tabResourceID: ResourceID(rawValue: "tab_adopted42"),
                                        terminalID: terminal, kind: .pty))
        let adopted = services.cache.terminal(for: made, daemon: services.daemon)
        #expect(adopted === entry, "the daemon's tab made a new terminal instead of keeping the stand-in's")
        #expect(services.cache.existingTerminal(standIn.id) == nil, "the stand-in's entry stayed beside the daemon tab's")
        #expect(services.cache.existingTerminal(made.id) === entry)

        // Another tab (no stand-in chose its terminal id) gets its own terminal.
        let other = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 43), tabResourceID: ResourceID(rawValue: "tab_other43"),
                                         terminalID: TerminalID.generate(), kind: .pty))
        #expect(services.cache.terminal(for: other, daemon: services.daemon) !== entry)
        for key in [made.id, other.id] { services.cache.release(key) }
    }

    private final class Presenter: SurfacePresenter {
        var displaced: [String] = []
        func surfaceWasDisplaced(_ key: String) { displaced.append(key) }
        var presentingWindow: NSWindow? { nil }
        var presentedContentSize: CGSize? { nil }
    }

    /// The pane withdraws the stand-in before it asks for the daemon tab's content (showSelectionNow): the withdraw
    /// adopts it then, so a warm-set eviction on that withdraw cannot close the stand-in's lane with keys in it (review
    /// of a8acc611977, finding C).
    @Test func aWithdrawnStandInWhoseDaemonTabExistsIsAdoptedNotWithdrawn() throws {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        let terminal = TerminalID.generate()
        let standIn = TabModel(ProvisionalTab().terminal(terminal, cwd: nil))
        let entry = services.cache.terminal(for: standIn, daemon: services.daemon)
        // The daemon's tab arrives in the store.
        let made = TabSnapshot(surface: SurfaceID(rawValue: 9), tabResourceID: ResourceID(rawValue: "tab_daemon9"), terminalID: terminal, kind: .pty)
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [made])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "adopt-ws"), name: "adopt",
                              screens: [ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(pane.id), panes: [pane])]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "adopt-ws"), index: 0)])
        store.apply(snapshot: tree)
        let daemonTab = try #require(store.tab(terminal: terminal))
        let presenter = Presenter()
        services.cache.withdraw(standIn.id, by: presenter)
        #expect(services.cache.existingTerminal(daemonTab.id) === entry, "the withdraw did not hand the stand-in's terminal to its daemon tab")
        services.cache.release(daemonTab.id)
    }
}
