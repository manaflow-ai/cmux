import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Chips shown for a held Cmd, Ctrl or Option sit on their rows, tabs and panes. Scrolling moves
/// those without a window layout, so the chips must be placed again, or they stay behind
/// (user: "if we scroll, the pills fail to scroll along, same as in sidebar").
@MainActor @Suite(.serialized)
struct ShortcutHintScrollTests {
    private static func tree(workspaces count: Int) -> DaemonTree {
        var tree = DaemonTree(registryID: "s-local", workspaces: (1...count).map {
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64($0)), key: WorkspaceKey(rawValue: "ws-\($0)"), name: "workspace \($0)")
        })
        tree.personal = PersonalState(workspaces: (1...count).map {
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "ws-\($0)"), index: $0 - 1)
        })
        return tree
    }

    private static func scrollEvent() throws -> NSEvent {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -40, wheel2: 0, wheel3: 0))
        return try #require(NSEvent(cgEvent: cg))
    }

    @Test func sidebarChipsFollowAScroll() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree(workspaces: 60))
        let controller = try #require(services.windows.openWindow(workspaces: (1...60).map { "ws-\($0)" }, frame: CGRect(x: 200, y: 200, width: 1200, height: 500)))
        defer { controller.window?.close() }
        let sidebar = controller.sidebar.container.sidebarView
        let hints = try #require(controller.shortcutHints)
        func workspaceChips() -> Int { hints.hints(held: [.command]).filter { $0.target?.hasPrefix("workspace:") == true }.count }
        for _ in 0..<300 where workspaceChips() < 5 {
            sidebar.layoutSubtreeIfNeeded()
            sidebar.list.reload(animated: false)
            sidebar.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(workspaceChips() >= 5, "the sidebar never showed rows to put chips on: \(workspaceChips())")
        hints.debugShow([.command])
        let before = hints.shownHints
        try #require(!before.isEmpty, "no chips for a Command hold")

        // A real scroll sets no layout of the window root, the other thing that re-places chips.
        controller.root.onHintGeometryChange = nil
        sidebar.list.scrollClip(to: 120, animated: false)
        // A real scroll runs no window layout: the chips are where they were until something re-places them.
        try #require(hints.shownHints == before, "something re-placed the chips before the scroll event")
        NSApp.sendEvent(try Self.scrollEvent())
        for _ in 0..<20 { await Task.yield() }

        let expected = hints.hints(held: [.command])
        try #require(expected != before, "the scroll moved nothing the chips follow")
        #expect(hints.shownHints == expected, "chips stayed where the rows were before the scroll")
    }
}
