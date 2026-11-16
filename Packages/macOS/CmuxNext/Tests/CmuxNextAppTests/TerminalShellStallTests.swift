import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextTerminal
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The daemon's stopped states offer recovery; automatic adoption and reconnect
/// keep the last screen without a status line or loading mark.
@MainActor struct TerminalShellStallTests {
    private func store() -> DaemonStore {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w", screens: [screen]),
        ]))
        return store
    }

    /// The daemon's `tab-changed` push for the tab, as the subscribe stream sends it.
    private func push(_ store: DaemonStore, state: String, dead: Bool = false) {
        let line = """
        {"event":"tab-changed","workspace":1,"screen":1,"pane":1,"surface":1,"index":0,\
        "entity":{"surface":1,"kind":"pty","title":"~","dead":\(dead),"terminal_state":"\(state)"}}
        """
        _ = store.apply(DaemonEvent.decode(name: "tab-changed", line: Data(line.utf8)))
    }

    /// What the terminal's status label says for the tab the store holds now (once its wait, if
    /// any, has ended).
    private func label(_ store: DaemonStore) -> String? {
        let tab = store.tab(surface: SurfaceID(rawValue: 1))
        return TerminalStatusBanner.text(for: tab?.dead == true ? .exited : .connected, stall: TerminalLinkWatch.shellStall(tab))
    }

    @Test func onlyAStoppedShellNeedsARecoveryLabel() {
        let store = store()
        push(store, state: "running")
        #expect(label(store) == nil)

        push(store, state: "reconnecting")
        #expect(label(store) == nil)
        push(store, state: "adopting")
        #expect(label(store) == nil)

        // The shell may still run and the daemon keeps retrying: no
        // "Close the tab to end it" dead end (Oct 30, an ssh tab).
        push(store, state: "failed")
        #expect(label(store) == "cmux lost its link to the shell · Still retrying")
        push(store, state: "unadoptable")
        #expect(label(store) == "Terminal stopped: another cmux build owns its shell · Close the tab to end it")

        // Back to running: the label goes away.
        push(store, state: "running")
        #expect(label(store) == nil)

        // An ended shell keeps the exit label (and its Restart button).
        push(store, state: "exited", dead: true)
        #expect(label(store) == "Process exited")
    }

    /// Automatic restore, handoff adoption, and reconnect have no user action and remain silent.
    @Test func automaticRecoveryStaysQuietEvenPastTheBound() {
        let clock = ManualClock()
        let view = TerminalHostView(clock: clock)
        for status in [TerminalConnectionStatus.restoring, .disconnected(.connectionLost, reconnecting: true), .connected] {
            view.showStatus(status)
            view.showShellStall(.reconnecting)
            clock.advance(by: .seconds(60))
            view.showShellStall(.reconnecting)
            #expect(view.statusText == nil)
            #expect(!view.statusLabelWaits, "no timer schedules automatic chatter")
            #expect(view.statusLabel.banner == nil)
        }
        view.showShellStall(.linkLost)
        #expect(view.statusText == "cmux lost its link to the shell · Still retrying", "Recover is still available")
    }

    /// A pane whose link drops and comes back within ``TerminalStatusBanner/disconnectedRevealDelay``
    /// (a daemon restart, a re-attach on a click) never shows "Disconnected"; one that lasts does.
    @Test func aDropThatHealsAtOnceShowsNothing() async throws {
        let clock = ManualClock()
        let view = TerminalHostView(clock: clock)
        view.showStatus(.connected)
        view.showStatus(.disconnected(.streamEnded, reconnecting: false))
        #expect(view.statusText == nil)
        #expect(view.statusLabelWaits)
        clock.advance(by: .seconds(TerminalStatusBanner.disconnectedRevealDelay / 2))
        view.showStatus(.connected)
        #expect(view.statusText == nil)
        #expect(!view.statusLabelWaits)

        view.showStatus(.disconnected(.streamEnded, reconnecting: false))
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(TerminalStatusBanner.disconnectedRevealDelay))
        try await Self.until { view.statusText != nil }
        #expect(view.statusText == "Disconnected: the stream ended · Click or type to reconnect")
    }

    /// Waits (a few main-actor turns) until `condition` holds: the reveal runs in the task the
    /// manual clock woke.
    private static func until(_ condition: () -> Bool) async throws {
        var turns = 0
        while !condition(), turns < 10_000 { await Task.yield(); turns += 1 }
        try #require(condition())
    }

    /// What the terminal offers above its label for the tab the store holds now.
    private func button(_ store: DaemonStore) -> String? {
        let view = TerminalHostView()
        view.onRestart = {}
        let tab = store.tab(surface: SurfaceID(rawValue: 1))
        view.showStatus(tab?.dead == true ? .exited : .connected)
        view.showShellStall(TerminalLinkWatch.shellStall(tab))
        return view.restartButtonTitle
    }

    /// A lost link offers Recover (the daemon rehosts the still running
    /// shell), an ended shell offers Restart, and a shell that runs or is
    /// still reconnecting offers neither.
    @Test func aLostLinkOffersRecover() {
        let store = store()
        push(store, state: "running")
        #expect(button(store) == nil)
        push(store, state: "reconnecting")
        #expect(button(store) == nil)
        push(store, state: "failed")
        #expect(button(store) == "Recover")
        #expect(TabRestart.isRestartable(store.tab(surface: SurfaceID(rawValue: 1))!))
        push(store, state: "exited", dead: true)
        #expect(button(store) == "Restart Shell Here")
    }
}
