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
    static let zoom = 1.154

    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, tabResourceID: "tab_1", title: "~")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])])
    }

    /// A daemon handshake that serves state resources (tab records).
    private static func identity() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"font-zoom-relaunch-test","generation":"g1","capabilities":["\#(DaemonCapabilities.shared.stateResources)"]}"#
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
