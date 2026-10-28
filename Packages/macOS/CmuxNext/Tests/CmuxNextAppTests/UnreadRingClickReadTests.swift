import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextBridge
import Foundation
import Testing

/// The unread ring stays until the person clicks into its own pane (Austin, 2026-10-20). A
/// mouse-down read the window's focused tab, whatever was under the pointer: a click on the
/// sidebar or on another pane, before focus moved there, read the focused pane's ring.
@MainActor @Suite(.serialized)
struct UnreadRingClickReadTests {
    /// One workspace, two panes side by side, each tab holding an unread notification.
    private static func tree() -> DaemonTree {
        let marker = { (id: UInt64) in TabNotification(notification: NotificationID(rawValue: id), unread: true, level: .info, source: "agent") }
        let first = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~", notification: marker(4))])
        let second = PaneSnapshot(id: PaneID(rawValue: 2), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 2), title: "~", notification: marker(5))])
        let layout: LayoutNode = .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(first.id), b: .leaf(second.id))
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, panes: [first, second])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "click-ws"), name: "click", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "click-ws"), index: 0)])
        return tree
    }

    private struct Fixture {
        let services: AppServices
        let controller: WindowController
        let window: NSWindow
        let content: WorkspaceContentController
        let focused: PaneModel
        let other: PaneModel
    }

    private static func open() async throws -> Fixture {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.notifications.start()  // the app's launch post; init only wires it
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree())
        let controller = try #require(services.windows.openWindow(workspaces: ["click-ws"], frame: CGRect(x: 200, y: 200, width: 1200, height: 760)))
        for _ in 0..<200 where controller.workspaceContent?.panes.count != 2 { try await Task.sleep(for: .milliseconds(10)) }
        let content = try #require(controller.workspaceContent)
        try #require(content.panes.count == 2, "the window never showed the workspace's two panes")
        for _ in 0..<200 where controller.focus.state.pane == nil { try await Task.sleep(for: .milliseconds(10)) }
        let focusedKey = try #require(controller.focus.state.pane, "the window focused no pane")
        content.contentView.layoutSubtreeIfNeeded()
        for _ in 0..<200 where content.layoutModel.visiblePanes.count != 2 { try await Task.sleep(for: .milliseconds(10)) }
        try #require(content.layoutModel.visiblePanes.count == 2, "the layout never placed both panes")
        let panes = try #require(store.workspaces.first?.screens.first?.panes)
        let focused = try #require(panes.first { $0.id == focusedKey })
        let other = try #require(panes.first { $0.id != focusedKey })
        return Fixture(services: services, controller: controller, window: try #require(controller.window), content: content,
                       focused: focused, other: other)
    }

    /// The center of `pane` in window coordinates.
    private static func center(of pane: PaneModel, in fixture: Fixture) throws -> NSPoint {
        let root = fixture.content.layoutView
        let frame = try #require(root.frame(of: LayoutPaneID(pane.id)), "pane \(pane.id) has no frame")
        return root.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
    }

    @Test func aClickInAPaneReadsThatPaneOnly() async throws {
        let fixture = try await Self.open()
        defer {
            fixture.controller.teardown()
            fixture.window.close()
        }
        let clicked = try #require(fixture.other.tabs.first)
        let kept = try #require(fixture.focused.tabs.first)
        let point = try Self.center(of: fixture.other, in: fixture)
        fixture.services.notifications.noteMouseDown(in: fixture.window, at: point)
        #expect(fixture.services.notifications.log.contains("ack \(clicked.id)"), "the clicked pane kept its ring")
        #expect(!fixture.services.notifications.log.contains("ack \(kept.id)"), "a click in another pane cleared the focused pane's ring")
    }

    @Test func aClickOutsideThePanesReadsNothing() async throws {
        let fixture = try await Self.open()
        defer {
            fixture.controller.teardown()
            fixture.window.close()
        }
        let root = fixture.content.layoutView
        let frames = fixture.content.layoutModel.visiblePanes.compactMap { root.frame(of: $0) }.map { root.convert($0, to: nil) }
        // The window's top-left corner: the sidebar or titlebar, never a pane.
        let corner = NSPoint(x: 2, y: fixture.window.frame.height - 2)
        try #require(!frames.contains { $0.contains(corner) }, "the fixture's corner lies in a pane")
        fixture.services.notifications.noteMouseDown(in: fixture.window, at: corner)
        #expect(!fixture.services.notifications.log.contains { $0.hasPrefix("ack ") }, "a click outside the panes cleared a ring")
    }
}
