import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// Canvas layout (INVENTORY row 31, plans/cmux-next/canvas-layout.md): Toggle Canvas Layout shows
/// the focused screen as free-placed panes on a zoomable plane, where they showed before, and the
/// canvas zoom actions scale what the screen shows about its center. Runs the registry's actions
/// (the path the palette, keyboard, menus, CLI and MCP share) on a window with a two-pane split.
@MainActor @Suite(.serialized)
struct CanvasLayoutActionTests {
    static let toggleAndZoom: [ActionID] = ["toggleCanvasLayout", "canvasZoomIn", "canvasZoomOut", "canvasZoomReset"]

    private static func tree() -> DaemonTree {
        let first = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let second = PaneSnapshot(id: PaneID(rawValue: 2), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 2), title: "~")])
        let layout: LayoutNode = .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(first.id), b: .leaf(second.id))
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, panes: [first, second])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "canvas-ws"), name: "canvas", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "canvas-ws"), index: 0)])
        return tree
    }

    /// The app with one window showing the two-pane workspace.
    static func window() async throws -> (AppServices, WindowController, WorkspaceContentController) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: tree())
        let controller = try #require(services.windows.openWindow(workspaces: ["canvas-ws"], frame: CGRect(x: 200, y: 200, width: 1200, height: 760)))
        for _ in 0..<200 where controller.workspaceContent?.panes.count != 2 { try await Task.sleep(for: .milliseconds(10)) }
        let content = try #require(controller.workspaceContent)
        try #require(content.panes.count == 2, "the window never showed the workspace's two panes")
        content.contentView.layoutSubtreeIfNeeded()
        return (services, controller, content)
    }

    static func run(_ id: ActionID, on pane: PaneController, _ services: AppServices) -> String? {
        services.registry.capturingRefusal {
            _ = services.registry.perform(id, invocation: ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane.paneKey), origin: .user))
        }
    }

    @Test func toggleAndZoomAreAvailable() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        for id in Self.toggleAndZoom {
            #expect(services.registry.unavailableReason(for: id) == nil, "\(id) is still greyed out")
        }
    }

    @Test func toggleShowsTheScreenAsACanvasWherePanesShowedAndZoomScalesIt() async throws {
        let (services, controller, content) = try await Self.window()
        defer { controller.teardown(); controller.window?.close() }
        let panes = content.panes.values.sorted { $0.paneKey < $1.paneKey }
        let root = content.layoutView
        let before = try panes.map { try #require(root.frame(of: $0.layoutPaneID)) }
        #expect(!services.registry.context.contains(.canvasLayout))

        #expect(Self.run("toggleCanvasLayout", on: panes[0], services) == nil)
        root.syncWithModel()
        #expect(services.registry.context.contains(.canvasLayout), "a canvas screen does not bring the canvas actions")
        let shown = try panes.map { try #require(root.frame(of: $0.layoutPaneID)) }
        for (old, new) in zip(before, shown) {
            #expect(abs(old.minX - new.minX) < 1 && abs(old.minY - new.minY) < 1 && abs(old.width - new.width) < 1,
                    "a pane moved going into canvas mode: \(old) became \(new)")
        }

        // Zoom In scales the canvas about the view's center by 1.25.
        #expect(Self.run("canvasZoomIn", on: panes[0], services) == nil)
        root.syncWithModel()
        let zoomed = try #require(root.frame(of: panes[1].layoutPaneID))
        #expect(abs(zoomed.width - shown[1].width * 1.25) < 2, "Zoom In did not scale the pane: \(shown[1]) became \(zoomed)")
        let center = CGPoint(x: root.bounds.midX, y: root.bounds.midY)
        #expect(abs((zoomed.minX - center.x) - (shown[1].minX - center.x) * 1.25) < 2, "Zoom In did not keep the center")

        // Actual Size returns; a second one has nothing to do.
        #expect(Self.run("canvasZoomReset", on: panes[0], services) == nil)
        root.syncWithModel()
        let reset = try #require(root.frame(of: panes[1].layoutPaneID))
        #expect(abs(reset.width - shown[1].width) < 1)
        #expect(Self.run("canvasZoomReset", on: panes[0], services) != nil)

        // Zoom Out shrinks it.
        #expect(Self.run("canvasZoomOut", on: panes[0], services) == nil)
        root.syncWithModel()
        let out = try #require(root.frame(of: panes[1].layoutPaneID))
        #expect(abs(out.width - shown[1].width / 1.25) < 2)

        // Toggling again shows the split as it was.
        #expect(Self.run("toggleCanvasLayout", on: panes[0], services) == nil)
        root.syncWithModel()
        #expect(!services.registry.context.contains(.canvasLayout))
        let back = try #require(root.frame(of: panes[1].layoutPaneID))
        #expect(abs(back.minX - before[1].minX) < 1 && abs(back.width - before[1].width) < 1)
        // Off a canvas the zoom actions do not apply.
        #expect(!services.registry.isAvailable("canvasZoomIn"))
    }
}
