import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextDaemon
@testable import CmuxNextDaemonService
@testable import CmuxNextTerminal
import Foundation
import Testing

/// A kept terminal whose restart failed says "Terminal stopped: it could not restart" in its view.
/// Two holes. A restart that found no free PTY said the same words as each other failed launch,
/// with nothing the person can do about it. And each show of the tab's workspace starts the restart
/// again (`DaemonService.wakeParkedTabs`), while the view still said that the restart failed.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct TerminalRestartFailedTextTests {
    /// AppServices reads `NSApp`; a suite run in its own process has no shared application until something makes it.
    init() { _ = NSApplication.shared }

    private static let general = "Terminal stopped: it could not restart"
    private static let noFreeTerminal = "Terminal stopped: out of terminals. Close some, then restart."

    /// Tab `end`s of a failed restart, as the daemon sends them: a launch that found no free PTY,
    /// another failed launch, and a cause that this build does not know.
    private static let noPtyEnd = """
    {"kind":"host_lost","reason":"restart_failed","launch_failure":"pty_capacity_exhausted",\
    "detail":"respawn-failed: pty_capacity_exhausted: spawn the terminal host: PTY capacity exhausted"}
    """
    private static let otherEnd = """
    {"kind":"host_lost","reason":"restart_failed","detail":"respawn-failed: spawn the terminal host: No such file or directory"}
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

    /// Waits until the watch of `entry` gave its session a host loss that `matches`: the observed change
    /// of the surface model's `hostLoss`, no poll. A change that never comes ends at the suite's time limit.
    private func hostLoss(of entry: TerminalEntry, _ matches: (TerminalHostLoss?) -> Bool) async {
        let session = entry.session
        for await loss in ObservationStream({ session.model.hostLoss }) where matches(loss) { break }
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

    @Test func aKeptTabThatWakesDoesNotSayThatItsRestartFailed() async throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let daemon = makeDaemon(), store = daemon.store
        let first = SurfaceID(rawValue: 1), second = SurfaceID(rawValue: 2)
        pushDead(store, surface: 1, end: Self.otherEnd)
        pushDead(store, surface: 2, end: Self.otherEnd)

        // The show of the workspace started the restart of tab 1: a view made now does not say that the restart failed.
        daemon.wakingParkedTabs.formUnion([first])
        let waking = services.cache.terminal(for: try #require(store.tab(surface: 1)), daemon: daemon)
        #expect(label(waking) == "Process exited")
        // Tab 2 is not in the set: it keeps the words.
        let resting = services.cache.terminal(for: try #require(store.tab(surface: 2)), daemon: daemon)
        #expect(label(resting) == Self.general)

        // A later show starts the restart of tab 2, whose view is there already: the words go.
        daemon.wakingParkedTabs.formUnion([second])
        await hostLoss(of: resting) { $0 == nil }
        #expect(label(resting) == "Process exited")

        // The restart of tab 1 got its answer and the tab is still dead (a refused restart): the words are back.
        daemon.wakingParkedTabs.remove(first)
        await hostLoss(of: waking) { $0 != nil }
        #expect(label(waking) == Self.general)
        // The launch of tab 2 found no free PTY after its answer: the words are back, with that cause.
        daemon.wakingParkedTabs.remove(second)
        pushDead(store, surface: 2, end: Self.noPtyEnd)
        await hostLoss(of: resting) { $0 == .restartFailedNoFreeTerminal }
        #expect(label(resting) == Self.noFreeTerminal)
    }
}
