import AppKit
import CmuxNextBridge
import CmuxNextCompat
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextTerminal
import Foundation
import Testing

/// restore-perf (2026-10-28, bench-restore n=600 restart and cold on the frame-hold build): a
/// visible terminal showed its last frame from the first launch frame through the whole wait for
/// its daemon. Then the new daemon answered with a new generation, the cache replaced the
/// terminal's session for the same tab (`TabContentCache.terminal(for:daemon:)` validity), and the
/// new session had nothing to show: the pane was empty for 0.6-4.8 s, until the new attach
/// replayed. The replacement session keeps showing what the pane showed.
@MainActor struct TerminalRestartCarriesFrameTests {
    private static func tree(generation: String, surface: UInt64 = 1) -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: surface), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [pane])
        return DaemonTree(generation: DaemonGeneration(rawValue: generation),
                          workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w", screens: [screen])])
    }

    private static func connected(_ generation: String) throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"restart-carry-test","generation":"\#(generation)"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    private static func frame() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(context.makeImage())
    }

    @Test func aDaemonRestartKeepsTheTerminalsLastFrameOnScreen() throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let cache = services.cache
        let daemon = DaemonService()
        let store = daemon.store
        store.connectionState = .connected(try Self.connected("g1"))
        store.apply(snapshot: Self.tree(generation: "g1"))
        let tab = try #require(store.tab(surface: SurfaceID(rawValue: 1)))
        let first = cache.terminal(for: tab, daemon: daemon)
        // The launch shows the terminal's frame from the last quit while it waits for its daemon.
        #expect(TerminalLaunchFrame(try Self.frame()).show(on: first.session))
        #expect(first.session.frameHold.isHolding)

        // The daemon restarts (a new generation) before the attach replayed: the tab's view is replaced.
        store.connectionState = .connected(try Self.connected("g2"))
        store.apply(snapshot: Self.tree(generation: "g2"))
        let again = try #require(store.tab(surface: SurfaceID(rawValue: 1)))
        let second = cache.terminal(for: again, daemon: daemon)
        try #require(second !== first, "the cache kept the old view across a new generation")
        #expect(second.session.frameHold.isHolding,
                "the new view of the terminal shows an empty pane: the last frame went with the old view")
    }

    /// Review of b09da9e2f45: a view replaced because the tab now shows ANOTHER terminal (its surface changed)
    /// must not show the old terminal's frame over the new one.
    @Test func anotherTerminalInTheTabDoesNotShowTheOldTerminalsFrame() throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let cache = services.cache
        let daemon = DaemonService()
        let store = daemon.store
        store.connectionState = .connected(try Self.connected("g1"))
        store.apply(snapshot: Self.tree(generation: "g1"))
        let tab = try #require(store.tab(surface: SurfaceID(rawValue: 1)))
        let first = cache.terminal(for: tab, daemon: daemon)
        #expect(TerminalLaunchFrame(try Self.frame()).show(on: first.session))

        // Same daemon, same tab id: the tab now shows another terminal (another surface).
        store.apply(snapshot: Self.tree(generation: "g1", surface: 2))
        let moved = try #require(store.tab(surface: SurfaceID(rawValue: 2)))
        guard moved.id == tab.id else { return }  // a store that gives the tab a new id never replaces the view
        let second = cache.terminal(for: moved, daemon: daemon)
        try #require(second !== first)
        #expect(!second.session.frameHold.isHolding, "another terminal shows the old terminal's frame")
    }

    /// bench-restore n=600 restart on the carry build (9ddfb4ee, cmux24): the carry worked after a cold start but
    /// not after a daemon restart. While the new daemon adopts the terminal, it lists the tab with no runtime
    /// surface: no `terminal_resource_id` and another surface handle, only the tab's `content_resource_id`
    /// (server/tree_json.rs). The view of the same terminal must still carry its frame.
    @Test func aTerminalStillAdoptingKeepsItsLastFrame() throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let cache = services.cache
        let daemon = DaemonService()
        let store = daemon.store
        let term = ResourceID(rawValue: "term_0123456789abcdef0123456789abcdef")
        let tabID = ResourceID(rawValue: "tab_0123456789abcdef0123456789abcdef")
        func tree(_ generation: String, surface: UInt64, live: Bool) -> DaemonTree {
            let tab = TabSnapshot(surface: SurfaceID(rawValue: surface), tabResourceID: tabID, contentResourceID: term,
                                  terminalResourceID: live ? term : nil, title: "~")
            let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [tab])
            let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [pane])
            return DaemonTree(generation: DaemonGeneration(rawValue: generation),
                              workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w", screens: [screen])])
        }
        store.connectionState = .connected(try Self.connected("g1"))
        store.apply(snapshot: tree("g1", surface: 7, live: true))
        let first = cache.terminal(for: try #require(store.tab(surface: SurfaceID(rawValue: 7))), daemon: daemon)
        #expect(TerminalLaunchFrame(try Self.frame()).show(on: first.session))

        // The restarted daemon lists the tab while it adopts the terminal: no runtime surface yet.
        store.connectionState = .connected(try Self.connected("g2"))
        store.apply(snapshot: tree("g2", surface: 9, live: false))
        let adopting = try #require(store.tab(surface: SurfaceID(rawValue: 9)))
        let second = cache.terminal(for: adopting, daemon: daemon)
        try #require(second !== first)
        #expect(second.session.frameHold.isHolding, "the adopting terminal's new view shows an empty pane")
    }
}
