import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextBridge
import CmuxNextTabs
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
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        // No real mouse: the press under test holds the button down until its mouse-up.
        services.notifications.leftButtonIsDown = { true }
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

    /// The center of `pane`'s tab strip in window coordinates.
    private static func stripCenter(of pane: PaneModel, in fixture: Fixture) throws -> NSPoint {
        let strip = try #require(fixture.content.panes[LayoutPaneID(pane.id)]?.view.stripView, "pane \(pane.id) has no strip")
        try #require(strip.window === fixture.window && !strip.isHiddenOrHasHiddenAncestor && strip.bounds.width > 0, "pane \(pane.id) shows no strip")
        return strip.convert(NSPoint(x: strip.bounds.midX, y: strip.bounds.midY), to: nil)
    }

    /// Dragging a tab or a pane by its strip moves the ring with it (classic: a Bonsplit tab drag
    /// never dismissed). The press used to read the pane at once, so the moved pane arrived bare.
    @Test func aStripPressThatDragsReadsNothing() async throws {
        let fixture = try await Self.open()
        defer {
            fixture.controller.teardown()
            fixture.window.close()
        }
        let notifications = fixture.services.notifications
        let point = try Self.stripCenter(of: fixture.other, in: fixture)
        notifications.noteMouseDown(in: fixture.window, at: point)
        #expect(!notifications.log.contains { $0.hasPrefix("ack ") }, "pressing a tab to drag it read its pane")
        let drop = NSPoint(x: point.x + TabTunables.dragStartDistance.value + 40, y: point.y - 120)
        notifications.noteMouseUp(in: fixture.window, at: drop)
        #expect(!notifications.log.contains { $0.hasPrefix("ack ") }, "a tab drag read the pane it came from")
    }

    /// A strip press released where it went down is a click into that pane: it reads it.
    @Test func aStripClickReadsItsPane() async throws {
        let fixture = try await Self.open()
        defer {
            fixture.controller.teardown()
            fixture.window.close()
        }
        let notifications = fixture.services.notifications
        let clicked = try #require(fixture.other.tabs.first)
        let kept = try #require(fixture.focused.tabs.first)
        let point = try Self.stripCenter(of: fixture.other, in: fixture)
        notifications.noteMouseDown(in: fixture.window, at: point)
        notifications.noteMouseUp(in: fixture.window, at: point)
        #expect(notifications.log.contains("ack \(clicked.id)"), "a click on the pane's strip kept its ring")
        #expect(!notifications.log.contains("ack \(kept.id)"), "a strip click cleared another pane's ring")
    }

    /// A reorder or a cancelled tear-off that ends where it began still dragged: it reads nothing.
    @Test func aDragThatComesBackReadsNothing() async throws {
        let fixture = try await Self.open()
        defer {
            fixture.controller.teardown()
            fixture.window.close()
        }
        let notifications = fixture.services.notifications
        let point = try Self.stripCenter(of: fixture.other, in: fixture)
        notifications.noteMouseDown(in: fixture.window, at: point)
        notifications.noteMouseDragged(in: fixture.window, at: NSPoint(x: point.x + TabTunables.dragStartDistance.value + 40, y: point.y))
        notifications.noteMouseUp(in: fixture.window, at: point)
        #expect(!notifications.log.contains { $0.hasPrefix("ack ") }, "a drag that came back read its pane")
    }

    /// In the titlebar row the window's own tracking loop takes the mouse-up before the press is
    /// seen, and may have moved the window: a press that stayed put reads its pane at once, one
    /// that dragged the window reads nothing (measured from where it went down, before dispatch).
    @Test func aPressWhoseMouseUpWasTakenResolvesAtOnce() async throws {
        let fixture = try await Self.open()
        defer {
            fixture.controller.teardown()
            fixture.window.close()
        }
        let notifications = fixture.services.notifications
        let clicked = try #require(fixture.other.tabs.first)
        let point = try Self.stripCenter(of: fixture.other, in: fixture)
        let screen = fixture.window.convertPoint(toScreen: point)
        let moved = NSPoint(x: screen.x + TabTunables.dragStartDistance.value + 60, y: screen.y)
        notifications.leftButtonIsDown = { false }
        // The window moved with the pointer: the window point is under the pointer again, the press point is not.
        notifications.pointerLocation = { moved }
        notifications.noteMouseDown(in: fixture.window, at: point, screen: screen)
        #expect(!notifications.log.contains { $0.hasPrefix("ack ") }, "a window drag from the strip read its pane")
        notifications.pointerLocation = { screen }
        notifications.noteMouseDown(in: fixture.window, at: point, screen: screen)
        #expect(notifications.log.contains("ack \(clicked.id)"), "a click the titlebar tracked kept its ring")
    }

    /// The app's own input (`debug.mouse`) holds no hardware button: its strip press waits for its
    /// own mouse-up rather than ending at once from the person's pointer.
    @Test func aSyntheticStripPressWaitsForItsMouseUp() async throws {
        let fixture = try await Self.open()
        defer {
            fixture.controller.teardown()
            fixture.window.close()
        }
        let notifications = fixture.services.notifications
        let clicked = try #require(fixture.other.tabs.first)
        let point = try Self.stripCenter(of: fixture.other, in: fixture)
        notifications.leftButtonIsDown = { false }
        notifications.pointerLocation = { NSPoint(x: -10_000, y: -10_000) }
        notifications.noteMouseDown(in: fixture.window, at: point, synthetic: true)
        #expect(notifications.stripPress != nil, "a synthetic strip press ended at the person's pointer")
        notifications.noteMouseUp(in: fixture.window, at: point)
        #expect(notifications.log.contains("ack \(clicked.id)"), "a synthetic strip click kept its ring")
    }

    /// A right-click on a strip is no drag: it reads its pane at once, as before. One during a
    /// strip drag leaves the drag alone.
    @Test func aRightClickOnAStripReadsItsPane() async throws {
        let fixture = try await Self.open()
        defer {
            fixture.controller.teardown()
            fixture.window.close()
        }
        let notifications = fixture.services.notifications
        let clicked = try #require(fixture.other.tabs.first)
        let point = try Self.stripCenter(of: fixture.other, in: fixture)
        notifications.noteMouseDown(in: fixture.window, at: point, left: false)
        #expect(notifications.log.contains("ack \(clicked.id)"), "a right-click on the strip kept its ring")
        #expect(notifications.stripPress == nil && notifications.viewHolds.isEmpty, "a right-click held its tab")

        let kept = try #require(fixture.focused.tabs.first)
        let strip = try Self.stripCenter(of: fixture.focused, in: fixture)
        notifications.noteMouseDown(in: fixture.window, at: strip)
        notifications.noteMouseDown(in: fixture.window, at: strip, left: false)
        #expect(notifications.stripPress?.tab == kept.id, "a right-click ended the strip drag under way")
        #expect(!notifications.log.contains("ack \(kept.id)"), "a right-click during a strip drag read the dragged tab")
    }

    /// The press focuses its tab and the drop focuses it where it lands, in either order with the
    /// daemon's echo; neither is a look. Under the `focus` dismissal policy and for Mark as Unread
    /// (cleared on coming into view), the moved tab keeps its ring until the person's next input.
    @Test func aMovedTabsFocusIsNoLookUntilTheNextInput() async throws {
        let fixture = try await Self.open()
        defer {
            fixture.controller.teardown()
            fixture.window.close()
        }
        let notifications = fixture.services.notifications
        let moved = try #require(fixture.other.tabs.first)
        let point = try Self.stripCenter(of: fixture.other, in: fixture)
        let away = NSPoint(x: point.x + TabTunables.dragStartDistance.value + 40, y: point.y)
        notifications.noteMouseDown(in: fixture.window, at: point)
        #expect(notifications.unheld([moved]).isEmpty, "the press's focus read the tab it picked up")
        notifications.noteMouseUp(in: fixture.window, at: away)
        // Out of view while the move lands, then focused at the drop: still no look.
        #expect(notifications.unheld([]).isEmpty)
        #expect(notifications.unheld([moved]).isEmpty, "the drop's focus read the moved tab")
        notifications.clearTabMarks(entering: [], held: [moved.id])
        #expect(notifications.viewedTabIDs.contains(moved.id), "the moved tab's mark would clear as it comes into view")
        // A key ends the hold.
        notifications.endViewHolds()
        #expect(notifications.unheld([moved]).map(\.id) == [moved.id], "a key left the moved tab held")

        // So does a click, here or in the tab itself.
        notifications.noteMouseDown(in: fixture.window, at: point)
        notifications.noteMouseUp(in: fixture.window, at: away)
        #expect(notifications.unheld([moved]).isEmpty)
        notifications.noteMouseDown(in: fixture.window, at: try Self.center(of: fixture.other, in: fixture))
        #expect(notifications.unheld([moved]).map(\.id) == [moved.id], "a click into the moved tab left it held")
    }
}
