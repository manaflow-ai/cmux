import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// cx-x15rz: closing a workspace tore its panes down, which only hid their terminals. Each closed
/// tab kept its Ghostty surface in the warm set until the LRU took it, and its preview image in
/// the preview cache: churning workspace opens and closes grew the app by about 1.5 MB a cycle.
/// A terminal whose tab its daemon's tree no longer lists now goes, preview and all; one the
/// tree still lists stays.
@MainActor struct ClosedWorkspaceTerminalTests {
    /// AppServices reads `NSApp` (an implicitly unwrapped Optional) from its observers and services;
    /// a suite run in its own process has no shared application until something makes it.
    init() { _ = NSApplication.shared }

    private static func tree(_ workspaces: [UInt64]) -> DaemonTree {
        DaemonTree(workspaces: workspaces.map { id in
            let pane = PaneSnapshot(id: PaneID(rawValue: id), tabs: [TabSnapshot(surface: SurfaceID(rawValue: id), title: "~")])
            let screen = ScreenSnapshot(id: ScreenID(rawValue: id), layout: .leaf(PaneID(rawValue: id)), panes: [pane])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: id), key: nil, name: "w\(id)", screens: [screen])
        })
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"closed-workspace-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    private static func preview() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(context.makeImage())
    }

    private static func until(_ condition: () -> Bool, within timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func aClosedWorkspacesTerminalAndItsPreviewGo() async throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let cache = services.cache
        let daemon = DaemonService()
        let store = daemon.store
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.tree([1, 2]))
        let kept = try #require(store.tab(surface: SurfaceID(rawValue: 1)))
        let closed = try #require(store.tab(surface: SurfaceID(rawValue: 2)))
        _ = cache.terminal(for: kept, daemon: daemon)
        _ = cache.terminal(for: closed, daemon: daemon)
        // Hidden once (its pane closed): the preview a hidden terminal leaves.
        cache.previews.insert(try Self.preview(), for: closed.id)

        // Workspace 2 closes: the tree no longer lists its tab.
        store.apply(snapshot: Self.tree([1]))
        await Self.until { cache.existingTerminal(closed.id) == nil }

        #expect(cache.existingTerminal(closed.id) == nil, "a closed workspace's terminal stayed")
        #expect(cache.previews.image(for: closed.id) == nil, "a closed workspace's terminal preview stayed")
        #expect(cache.existingTerminal(kept.id) != nil, "a listed tab's terminal went")
    }
}
