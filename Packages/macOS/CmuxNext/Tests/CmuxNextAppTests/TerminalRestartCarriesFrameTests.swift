import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextTerminal
import Foundation
import Testing

/// Restore (bench-restore n=600 restart and cold, 2026-10-28): a visible terminal showed its last
/// frame from the first launch frame through the whole wait for its daemon. Then the new daemon
/// answered with a new generation, the cache replaced the terminal's session for the same tab
/// (`TabContentCache.terminal(for:daemon:)` validity), and the new session had nothing to show:
/// the pane was empty for 0.6-4.8 s, until the new attach replayed. The replacement session keeps
/// showing what the pane showed.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct TerminalRestartCarriesFrameTests {
    /// AppServices reads `NSApp`; a suite run in its own process has no shared application until something makes it.
    init() { _ = NSApplication.shared }

    private static func tree(generation: String, surface: UInt64 = 1) -> DaemonTree {
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: SurfaceID(rawValue: surface), title: "~")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        return DaemonTree(generation: DaemonGeneration(rawValue: generation),
                          workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])])
    }

    private static func connected(_ generation: String) -> DaemonIdentity {
        DaemonIdentity(generation: DaemonGeneration(rawValue: generation))
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
        store.connectionState = .connected(Self.connected("g1"))
        store.apply(snapshot: Self.tree(generation: "g1"))
        let tab = try #require(store.tab(surface: 1))
        let first = cache.terminal(for: tab, daemon: daemon)
        // The launch shows the terminal's frame from the last quit while it waits for its daemon.
        #expect(TerminalLaunchFrame(try Self.frame()).show(on: first.session))
        #expect(first.session.frameHold.isHolding)

        // The daemon restarts (a new generation) before the attach replayed: the tab's view is replaced.
        store.connectionState = .connected(Self.connected("g2"))
        store.apply(snapshot: Self.tree(generation: "g2"))
        let again = try #require(store.tab(surface: 1))
        let second = cache.terminal(for: again, daemon: daemon)
        try #require(second !== first, "the cache kept the old view across a new generation")
        #expect(second.session.frameHold.isHolding,
                "the new view of the terminal shows an empty pane: the last frame went with the old view")
    }

    /// A view replaced because the tab now shows ANOTHER terminal (a new generation and another
    /// terminal id under the same tab id) must not show the old terminal's frame over the new one.
    @Test func anotherTerminalInTheTabDoesNotShowTheOldTerminalsFrame() throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let cache = services.cache
        let daemon = DaemonService()
        let store = daemon.store
        let tabID = "tab_0123456789abcdef0123456789abcdef" as ResourceID
        func tree(_ generation: String, surface: UInt64, terminal: ResourceID) -> DaemonTree {
            let tab = TabSnapshot(surface: SurfaceID(rawValue: surface), tabResourceID: tabID, contentResourceID: terminal,
                                  terminalResourceID: terminal, title: "~")
            let pane = PaneSnapshot(id: 1, tabs: [tab])
            let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
            return DaemonTree(generation: DaemonGeneration(rawValue: generation),
                              workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])])
        }
        store.connectionState = .connected(Self.connected("g1"))
        store.apply(snapshot: tree("g1", surface: 1, terminal: "term_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
        let tab = try #require(store.tab(surface: 1))
        let first = cache.terminal(for: tab, daemon: daemon)
        #expect(TerminalLaunchFrame(try Self.frame()).show(on: first.session))

        // The daemon restarts and the tab now shows another terminal.
        store.connectionState = .connected(Self.connected("g2"))
        store.apply(snapshot: tree("g2", surface: 2, terminal: "term_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"))
        let moved = try #require(store.tab(surface: 2))
        try #require(moved.id == tab.id, "the tab record changed its id: the view would never be replaced")
        let second = cache.terminal(for: moved, daemon: daemon)
        try #require(second !== first)
        #expect(!second.session.frameHold.isHolding, "another terminal shows the old terminal's frame")
    }

    /// bench-restore n=600 restart: while the new daemon adopts the terminal, it lists the tab with no
    /// runtime surface: no `terminal_resource_id` and another surface handle, only the tab's
    /// `content_resource_id` (server/tree_json.rs). The view of the same terminal must still carry its frame.
    @Test func aTerminalStillAdoptingKeepsItsLastFrame() throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let cache = services.cache
        let daemon = DaemonService()
        let store = daemon.store
        let term = "term_0123456789abcdef0123456789abcdef" as ResourceID
        let tabID = "tab_0123456789abcdef0123456789abcdef" as ResourceID
        func tree(_ generation: String, surface: UInt64, live: Bool) -> DaemonTree {
            let tab = TabSnapshot(surface: SurfaceID(rawValue: surface), tabResourceID: tabID, contentResourceID: term,
                                  terminalResourceID: live ? term : nil, title: "~")
            let pane = PaneSnapshot(id: 1, tabs: [tab])
            let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
            return DaemonTree(generation: DaemonGeneration(rawValue: generation),
                              workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])])
        }
        store.connectionState = .connected(Self.connected("g1"))
        store.apply(snapshot: tree("g1", surface: 7, live: true))
        let first = cache.terminal(for: try #require(store.tab(surface: 7)), daemon: daemon)
        #expect(TerminalLaunchFrame(try Self.frame()).show(on: first.session))

        // The restarted daemon lists the tab while it adopts the terminal: no runtime surface yet.
        store.connectionState = .connected(Self.connected("g2"))
        store.apply(snapshot: tree("g2", surface: 9, live: false))
        let adopting = try #require(store.tab(surface: 9))
        let second = cache.terminal(for: adopting, daemon: daemon)
        try #require(second !== first)
        #expect(second.session.frameHold.isHolding, "the adopting terminal's new view shows an empty pane")
    }
}
