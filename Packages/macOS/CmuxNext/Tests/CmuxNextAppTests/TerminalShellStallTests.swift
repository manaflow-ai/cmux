import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSidebar
@testable import CmuxNextTerminal
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// A terminal whose shell the daemon can no longer reach (its host link is
/// reconnecting, given up, or from a build this daemon cannot adopt) kept a
/// "connected" view with no label: the last screen, often a lone block
/// cursor, and keys that went nowhere. The daemon's tab push now reaches the
/// view as a visible stopped state; a running or exited shell keeps its own.
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
    /// any, has ended: ``aHandoffAdoptionStaysQuietUnlessItLasts`` checks the wait).
    private func label(_ store: DaemonStore) -> String? {
        let tab = store.tab(surface: SurfaceID(rawValue: 1))
        return TerminalStatusBanner.text(for: tab?.dead == true ? .exited : .connected, stall: TerminalLinkWatch.shellStall(tab))
    }

    @Test func aShellTheDaemonCannotReachIsNeverASilentCursor() {
        let store = store()
        push(store, state: "running")
        #expect(label(store) == nil)

        // A redial on its way says nothing (Leo, 2026-11-24: "let's just keep optimistically connecting").
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

    /// After every update handoff the new daemon marks each tab `adopting` until it takes the shell's host
    /// back. That said "Reconnecting to the shell…" once it lasted 10 s; now it never does, at any age (Leo,
    /// 2026-11-24: "all the connecting... indicators and the graying out of workspaces, nah let's not do that").
    /// Lasting states a person can act on still show.
    @Test func aHandoffAdoptionNeverSaysReconnecting() async throws {
        #expect(TerminalStatusBanner.revealDelay(for: .restoring, stall: nil) == TerminalStatusBanner.restoringRevealDelay)
        #expect(TerminalStatusBanner.revealDelay(for: .restoring, stall: .reconnecting) == TerminalStatusBanner.restoringRevealDelay)
        #expect(TerminalStatusBanner.revealDelay(for: .disconnected(.connectionLost, reconnecting: false), stall: nil)
            == TerminalStatusBanner.disconnectedRevealDelay)
        #expect(!TerminalStatusBanner.isInBetween(.disconnected(.connectionLost, reconnecting: false), stall: nil))
        #expect(TerminalStatusBanner.revealDelay(for: .connected, stall: .linkLost) == nil)
        #expect(TerminalStatusBanner.revealDelay(for: .connected, stall: .otherBuild) == nil)
        #expect(TerminalStatusBanner.text(for: .connected, stall: .reconnecting) == nil)
        #expect(TerminalStatusBanner.text(for: .disconnected(.connectionLost, reconnecting: true)) == nil)
        #expect(TerminalStatusBanner.text(for: .disconnected(.turnedOffByOrganization, reconnecting: true)) == "Turned off by your organization")

        let store = store()
        let clock = ManualClock()
        let view = TerminalHostView(clock: clock)
        func show() {
            let tab = store.tab(surface: SurfaceID(rawValue: 1))
            view.showStatus(tab?.dead == true ? .exited : .connected)
            view.showShellStall(TerminalLinkWatch.shellStall(tab))
        }
        push(store, state: "adopting")
        show()
        #expect(view.statusText == nil)
        #expect(!view.statusLabelWaits, "no wait that could end in a label")
        clock.advance(by: .seconds(3_600))
        for _ in 0..<1_000 { await Task.yield() }
        #expect(view.statusText == nil, "an adoption that lasts an hour still says nothing")

        // A lasting failure shows at once.
        push(store, state: "failed")
        show()
        #expect(view.statusText == "cmux lost its link to the shell · Still retrying")
        #expect(!view.statusLabelWaits)

        // A dropped view's reattach says nothing; its "Disconnected" waits its delay, then says its words.
        view.showShellStall(nil)
        view.showStatus(.connected)
        view.showStatus(.disconnected(.connectionLost, reconnecting: true))
        #expect(view.statusText == nil)
        #expect(!view.statusLabelWaits)
        view.showStatus(.disconnected(.connectionLost, reconnecting: false))
        #expect(view.statusText == nil, "a drop that heals within the delay never shows")
        #expect(view.statusLabelWaits)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(TerminalStatusBanner.disconnectedRevealDelay))
        try await Self.until { view.statusText != nil }
        #expect(view.statusText == "Disconnected: connection lost · Click or type to reconnect")
        #expect(view.statusLabel.banner?.showsMark == false)
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

    /// A daemon restart, a handoff or a drop puts no "Reconnecting…" mark on any pane, however long it lasts: the
    /// pane keeps its last screen and comes back by itself (Leo, 2026-11-24: "let's just keep optimistically
    /// connecting and reinforcing the connection and sync-ups can be satisfying instead of making the user think
    /// they're constsntly suspended in a state of connection limbo"). The mark showed at 10 s.
    @Test func aReconnectNeverShowsAMark() async throws {
        let clock = ManualClock()
        let view = TerminalHostView(clock: clock)
        view.showStatus(.connected)
        view.showStatus(.disconnected(.connectionLost, reconnecting: true))
        clock.advance(by: .seconds(3_600))
        for _ in 0..<1_000 { await Task.yield() }
        #expect(view.statusText == nil, "a reconnect says nothing, at any age")
        #expect(!view.statusLabelWaits)

        // The daemon's own word that it re-adopts the shell says nothing either.
        view.showShellStall(.reconnecting)
        clock.advance(by: .seconds(3_600))
        for _ in 0..<1_000 { await Task.yield() }
        #expect(view.statusText == nil, "a re-adoption says nothing, at any age")
        #expect(!view.statusLabelWaits)
    }

    /// Leo, 2026-11-14: "i also want all our connectivity stuff to shut the f*** up". "Disconnected" over the
    /// last frame (a daemon restart, a hidden pane's drop, quiet re-attaches that ran out) waits the same 10 s
    /// as "Reconnecting…": it showed after 1.5 s on every pane a daemon restart dropped.
    @Test func aDisconnectThatHealsWithinTenSecondsShowsNothing() async throws {
        let clock = ManualClock()
        let view = TerminalHostView(clock: clock)
        view.showStatus(.connected)
        view.showStatus(.disconnected(.connectionLost, reconnecting: false))
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(9_900))
        for _ in 0..<1_000 { await Task.yield() }
        #expect(view.statusText == nil, "a drop under 10 s shows no Disconnected")
        #expect(view.statusLabelWaits)
        view.showStatus(.connected)
        #expect(view.statusText == nil)
        #expect(!view.statusLabelWaits)

        // One that lasts says its words (not the mark), once.
        view.showStatus(.disconnected(.streamEnded, reconnecting: false))
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(9_900))
        for _ in 0..<1_000 { await Task.yield() }
        #expect(view.statusText == nil)
        clock.advance(by: .milliseconds(100))
        try await Self.until { view.statusText != nil }
        #expect(view.statusText == "Disconnected: the stream ended · Click or type to reconnect")
        #expect(view.statusLabel.banner?.showsMark == false)
    }

    /// Every connection label that still shows waits one shared quiet time instead of picking its own.
    @Test func connectionLabelsShareOneQuietTime() {
        #expect(QuietHold.connectionDelay == .seconds(10))
        #expect(TerminalStatusBanner.disconnectedRevealDelay == QuietHold.connectionDelaySeconds)
        #expect(SidebarPlaceholderGrace.connectingDelay == QuietHold.connectionDelay)
    }

    /// Quiet re-attaches that run out turn a silent reattach into "Disconnected": the label waits its full
    /// delay from that change (the reattach before it said nothing and started no wait).
    @Test func aDisconnectAfterReconnectingWaitsItsDelay() async throws {
        let clock = ManualClock()
        let view = TerminalHostView(clock: clock)
        view.showStatus(.connected)
        view.showStatus(.disconnected(.connectionLost, reconnecting: true))
        clock.advance(by: .seconds(5))
        view.showStatus(.disconnected(.connectionLost, reconnecting: false))
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(9_900))
        for _ in 0..<1_000 { await Task.yield() }
        #expect(view.statusText == nil)
        clock.advance(by: .milliseconds(100))
        try await Self.until { view.statusText != nil }
        #expect(view.statusText == "Disconnected: connection lost · Click or type to reconnect")
    }

    /// A state the app knows is final waits for nothing: the session ended (its shell exited, its host was
    /// lost, the session shut down) or an administrator turned the link off.
    @Test func aFinalStateShowsAtOnce() {
        let view = TerminalHostView(clock: ManualClock())
        view.showStatus(.connected)
        view.showStatus(.exited)
        #expect(view.statusText == "Process exited")
        #expect(!view.statusLabelWaits)

        let lost = TerminalHostView(clock: ManualClock())
        lost.showStatus(.connected)
        lost.showHostLoss(.sessionShutdown, cause: nil)
        lost.showStatus(.exited)
        #expect(lost.statusText == "Terminal lost: the session shut down")
        #expect(!lost.statusLabelWaits)

        let off = TerminalHostView(clock: ManualClock())
        off.showStatus(.connected)
        off.showStatus(.disconnected(.turnedOffByOrganization, reconnecting: false))
        #expect(off.statusText == "Turned off by your organization")
        #expect(!off.statusLabelWaits)
    }

    /// "Restoring…" under a reconnecting stall says "Restoring…" after its own short delay, never "Reconnecting
    /// to the shell…".
    @Test func aRestoreUnderARedialSaysOnlyRestoring() async throws {
        let clock = ManualClock()
        let view = TerminalHostView(clock: clock)
        view.showStatus(.restoring)
        view.showShellStall(.reconnecting)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(TerminalStatusBanner.restoringRevealDelay))
        try await Self.until { view.statusText != nil }
        #expect(view.statusText == "Restoring…")
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
