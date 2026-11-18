import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextDaemonService
@testable import CmuxNextTerminal
import Foundation
import Testing

/// A kept terminal whose restart failed says "Terminal stopped: it could not restart" in its view.
/// A restart that found no free PTY said the same words as each other failed launch, with nothing
/// the person can do about it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct TerminalRestartFailedTextTests {
    /// AppServices reads `NSApp`; a suite run in its own process has no shared application until something makes it.
    init() { _ = NSApplication.shared }

    private static let general = "Terminal stopped: it could not restart"
    private static let noFreeTerminal = "Terminal stopped: out of terminals. Close some, then restart."

    /// Tab `end`s of a failed restart, as the daemon sends them: a launch that found no free PTY,
    /// and a cause that this build does not know.
    private static let noPtyEnd = """
    {"kind":"host_lost","reason":"restart_failed","launch_failure":"pty_capacity_exhausted",\
    "detail":"respawn-failed: pty_capacity_exhausted: spawn the terminal host: PTY capacity exhausted"}
    """
    private static let unknownCauseEnd = """
    {"kind":"host_lost","reason":"restart_failed","launch_failure":"a_cause_of_a_newer_daemon","detail":"respawn-failed: a_cause_of_a_newer_daemon: x"}
    """

    /// A daemon service whose store holds one pane with the terminal tabs 1 and 2.
    private func makeDaemon() -> DaemonService {
        let daemon = DaemonService()
        let generation = DaemonGeneration(rawValue: "g1")
        daemon.store.connectionState = .connected(DaemonIdentity(generation: generation))
        let surfaces: [UInt64] = [1, 2]
        let tabs = surfaces.map { TabSnapshot(surface: SurfaceID(rawValue: $0), title: "~") }
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: tabs)])
        daemon.store.apply(snapshot: DaemonTree(generation: generation,
                                                workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        return daemon
    }

    /// The daemon's `tab-changed` push for a dead tab with `end`, as the subscribe stream sends it.
    private func pushDead(_ store: DaemonStore, surface: UInt64, end: String) {
        let line = """
        {"event":"tab-changed","workspace":1,"screen":1,"pane":1,"surface":\(surface),"index":\(surface - 1),\
        "entity":{"surface":\(surface),"kind":"pty","title":"~","dead":true,"terminal_state":"exited","end":\(end)}}
        """
        _ = store.apply(DaemonEvent.decode(name: "tab-changed", line: Data(line.utf8)))
    }

    /// What the status label of an ended terminal says for the host loss that the tab's watch gave its session.
    private func label(_ entry: TerminalEntry) -> String? {
        TerminalStatusBanner.text(for: .exited, hostLoss: entry.session.hostLoss)
    }

    @Test func aRestartThatFoundNoFreeTerminalSaysWhatToDo() throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let daemon = makeDaemon(), store = daemon.store
        pushDead(store, surface: 1, end: Self.noPtyEnd)
        pushDead(store, surface: 2, end: Self.unknownCauseEnd)

        let noPty = services.cache.terminal(for: try #require(store.tab(surface: 1)), daemon: daemon)
        #expect(label(noPty) == Self.noFreeTerminal)
        // A cause that this build does not know keeps the general words (and the tab still decodes).
        let unknown = services.cache.terminal(for: try #require(store.tab(surface: 2)), daemon: daemon)
        #expect(label(unknown) == Self.general)
    }
}
