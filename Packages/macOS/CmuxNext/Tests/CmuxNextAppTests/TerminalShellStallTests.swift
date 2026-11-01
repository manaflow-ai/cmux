import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextTerminal
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

    /// What the terminal's status label says for the tab the store holds now.
    private func label(_ store: DaemonStore) -> String? {
        let banner = TerminalStatusBanner()
        let tab = store.tab(surface: SurfaceID(rawValue: 1))
        banner.show(tab?.dead == true ? .exited : .connected, stall: TerminalLinkWatch.shellStall(tab))
        return banner.isHidden ? nil : banner.accessibilityLabel()
    }

    @Test func aShellTheDaemonCannotReachIsNeverASilentCursor() {
        let store = store()
        push(store, state: "running")
        #expect(label(store) == nil)

        push(store, state: "reconnecting")
        #expect(label(store) == "Reconnecting to the shell…")
        push(store, state: "adopting")
        #expect(label(store) == "Reconnecting to the shell…")

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

    /// Seconds until the banner's held label starts to fade in; nil when it shows at once.
    private func revealWait(_ banner: TerminalStatusBanner) -> CFTimeInterval? {
        guard let layer = banner.layer, layer.animation(forKey: TerminalStatusBanner.revealHoldKey) != nil,
              let fade = layer.animation(forKey: TerminalStatusBanner.revealFadeKey) else { return nil }
        return fade.beginTime - layer.convertTime(CACurrentMediaTime(), from: nil)
    }

    /// After every update handoff the new daemon marks each tab `adopting`
    /// until it takes the shell's host back, and every visible terminal said
    /// "Reconnecting to the shell…" at once. A transient reconnect now waits
    /// out a grace that covers a normal adopt (a slow host: 1 s of connect
    /// retries, 2 s of handshake, after up to 2 s for the owner to say ready),
    /// and never shows if it clears within it. Lasting states show at once.
    @Test func aHandoffAdoptionStaysQuietUnlessItLasts() throws {
        let grace = TerminalStatusBanner.reconnectingRevealDelay
        #expect(grace >= 5)
        #expect(TerminalStatusBanner.revealDelay(for: .connected, stall: .reconnecting) == grace)
        #expect(TerminalStatusBanner.revealDelay(for: .disconnected(.connectionLost, reconnecting: true), stall: nil) == grace)
        #expect(TerminalStatusBanner.revealDelay(for: .restoring, stall: nil) == TerminalStatusBanner.restoringRevealDelay)
        #expect(TerminalStatusBanner.revealDelay(for: .restoring, stall: .reconnecting) == grace)
        // Lasting: the quiet retries ran out, the daemon gave up, another build owns the shell, it ended.
        #expect(TerminalStatusBanner.revealDelay(for: .disconnected(.connectionLost, reconnecting: false), stall: nil) == nil)
        #expect(TerminalStatusBanner.revealDelay(for: .connected, stall: .linkLost) == nil)
        #expect(TerminalStatusBanner.revealDelay(for: .connected, stall: .otherBuild) == nil)
        #expect(TerminalStatusBanner.revealDelay(for: .exited, stall: .reconnecting) == nil)
        #expect(TerminalStatusBanner.revealDelay(for: .disconnected(.turnedOffByOrganization, reconnecting: true), stall: nil) == nil)

        let store = store()
        let banner = TerminalStatusBanner()
        func show() {
            let tab = store.tab(surface: SurfaceID(rawValue: 1))
            banner.show(tab?.dead == true ? .exited : .connected, stall: TerminalLinkWatch.shellStall(tab))
        }
        push(store, state: "adopting")
        show()
        let wait = try #require(revealWait(banner), "the adopting label is held, not shown at once")
        #expect(wait > grace - 1 && wait <= grace)
        // Adopted within the grace: the label never showed and nothing stays held.
        push(store, state: "running")
        show()
        #expect(banner.isHidden)
        #expect(banner.layer?.animationKeys()?.isEmpty ?? true)

        // A lasting failure shows at once.
        push(store, state: "failed")
        show()
        #expect(!banner.isHidden)
        #expect(revealWait(banner) == nil)

        // "Restoring…" turning into a reconnecting stall keeps the longer wait.
        banner.show(.connected)
        banner.show(.restoring)
        let restoring = try #require(revealWait(banner))
        #expect(restoring <= TerminalStatusBanner.restoringRevealDelay)
        banner.show(.connected, stall: .reconnecting)
        let stalled = try #require(revealWait(banner))
        #expect(stalled > grace - 1)

        // A dropped view's "Reconnecting…" waits too; its lasting "Disconnected" does not.
        banner.show(.connected)
        banner.show(.disconnected(.connectionLost, reconnecting: true))
        let dropped = try #require(revealWait(banner))
        #expect(dropped > grace - 1)
        banner.show(.disconnected(.connectionLost, reconnecting: false))
        #expect(revealWait(banner) == nil)
        #expect(banner.accessibilityLabel() == "Disconnected: connection lost · Click or type to reconnect")
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
