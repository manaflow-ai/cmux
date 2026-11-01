import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextTerminal
import Foundation
import Testing

/// cx-mer6v: a person zooms a terminal twice (Cmd-+), quits cmux and opens it again. The tab
/// record keeps the zoom (1.154), but the reopened terminal drew at the configured size (scale 1,
/// a larger grid). A relaunch draws the launch window from the daemon's launch snapshot before
/// the daemon answers, so the terminal view is made while the store knows no tab records; the
/// record's zoom arrives later with the session stream, and the view must take it then.
/// The boundary: the app's terminal cache with real Ghostty surfaces on a store fed the
/// relaunch's events in order (launch snapshot, handshake, live tree, session snapshot).
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct TerminalFontZoomRelaunchTests {
    /// AppServices reads `NSApp` (an implicitly unwrapped Optional) from its observers and services;
    /// a suite run in its own process has no shared application until something makes it.
    init() { _ = NSApplication.shared }

    static let zoom = 1.154

    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, tabResourceID: "tab_1", title: "~")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])])
    }

    /// A daemon handshake that serves state resources (tab records).
    private static func identity() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"font-zoom-relaunch-test","generation":"g1","capabilities":["\#(DaemonCapability.stateResources.rawValue)"]}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    /// The session stream's first snapshot: tab_1's record saves the zoom.
    private static func records(_ store: DaemonStore) throws {
        let line = #"{"type":"stream_item","item":{"kind":"snapshot","snapshot":{"tabs":[{"id":"tab_1","extra":{"zoom":\#(zoom)}}],"extra":{"state":{}}}}}"#
        store.apply(.sessionState(try #require(SessionStreamItem.decode(Data(line.utf8)))))
    }

    private static func scale(_ entry: TerminalEntry) -> Double {
        TerminalFontScale(entry.session.surfaceView).current ?? 1
    }

    private static func until(_ condition: () -> Bool, within timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// The relaunch: the launch window draws the terminal from the launch snapshot, then the
    /// daemon answers and its session stream brings the tab record. The view draws at the zoom.
    @Test func aTerminalDrawnFromTheLaunchSnapshotTakesItsRecordsZoom() async throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let daemon = DaemonService()
        let store = daemon.store
        store.applyProvisional(snapshot: Self.tree())
        let launchTab = try #require(store.tab(surface: 1))
        let entry = services.cache.terminal(for: launchTab, daemon: daemon)

        store.apply(.connected(try Self.identity(), generationChanged: false))
        store.apply(snapshot: Self.tree())
        try Self.records(store)
        let tab = try #require(store.tab(surface: 1))
        #expect(tab.zoom == Self.zoom, "the record's zoom did not reach the tab")
        _ = services.cache.terminal(for: tab, daemon: daemon)

        await Self.until { abs(Self.scale(entry) - Self.zoom) < 0.01 }
        #expect(abs(Self.scale(entry) - Self.zoom) < 0.01, "the reopened terminal draws at scale \(Self.scale(entry))")
    }

    /// The person changes the launch view's font (a zoom, or a zoom then Cmd-0 back to the
    /// configured size) before the records arrive: their size wins over the record's zoom.
    @Test(arguments: [1.3, nil] as [Double?])
    func aFontChangeBeforeTheRecordsArriveWins(_ size: Double?) async throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let daemon = DaemonService()
        let store = daemon.store
        store.applyProvisional(snapshot: Self.tree())
        let entry = services.cache.terminal(for: try #require(store.tab(surface: 1)), daemon: daemon)
        let fontScale = TerminalFontScale(entry.session.surfaceView)
        #expect(fontScale.apply(1.5), "Ghostty refused the zoom")
        #expect(fontScale.apply(size), "Ghostty refused the person's size")

        store.apply(.connected(try Self.identity(), generationChanged: false))
        store.apply(snapshot: Self.tree())
        try Self.records(store)
        _ = services.cache.terminal(for: try #require(store.tab(surface: 1)), daemon: daemon)

        let want = size ?? 1
        await Self.until({ abs(Self.scale(entry) - want) >= 0.01 }, within: .seconds(1))
        #expect(abs(Self.scale(entry) - want) < 0.01, "the person's size \(want) became \(Self.scale(entry))")
    }

    /// cx-1bauj: the daemon reconnects and replays the screen into a terminal that already has
    /// content, so the session swaps in a fresh surface. The zoom survives the swap, and a later
    /// Cmd-+ on the fresh surface still saves to the tab record.
    @Test func aZoomSurvivesAReconnectReplayAndKeepsSaving() async throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let daemon = DaemonService()
        let store = daemon.store
        store.apply(.connected(try Self.identity(), generationChanged: false))
        store.apply(snapshot: Self.tree())
        try Self.records(store)
        var saves = 0
        daemon.workTracker = { _ in saves += 1 }
        let io = ScriptedTerminalIO()
        let session = services.cache.makeSession(io: io, tab: try #require(store.tab(surface: 1)), daemon: daemon)
        defer { session.close(); io.finish() }
        let first = session.surfaceView
        #expect(TerminalFontScale(first).apply(1.3), "Ghostty refused the zoom")
        await Self.until { saves > 0 }
        #expect(saves == 1, "the zoom was not saved before the reconnect")

        io.send(.output(Data("before\r\n".utf8)))
        io.send(.replay(Data("after\r\n".utf8)))
        await Self.until { session.surfaceView !== first }
        try #require(session.surfaceView !== first, "the reconnect replay did not swap the surface")
        let kept = TerminalFontScale(session.surfaceView).current ?? 1
        #expect(abs(kept - 1.3) < 0.01, "after the reconnect the terminal draws at scale \(kept)")

        saves = 0
        #expect(TerminalFontScale(session.surfaceView).apply(1.5), "Ghostty refused the second zoom")
        await Self.until { saves > 0 }
        #expect(saves == 1, "a zoom after the reconnect was not saved to the tab record")
    }

    /// The control: a terminal made once the record is known starts at its zoom.
    @Test func aTerminalMadeAfterItsRecordStartsAtItsZoom() async throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let daemon = DaemonService()
        let store = daemon.store
        store.apply(.connected(try Self.identity(), generationChanged: false))
        store.apply(snapshot: Self.tree())
        try Self.records(store)
        let entry = services.cache.terminal(for: try #require(store.tab(surface: 1)), daemon: daemon)

        await Self.until { abs(Self.scale(entry) - Self.zoom) < 0.01 }
        #expect(abs(Self.scale(entry) - Self.zoom) < 0.01, "the terminal draws at scale \(Self.scale(entry))")
    }
}
