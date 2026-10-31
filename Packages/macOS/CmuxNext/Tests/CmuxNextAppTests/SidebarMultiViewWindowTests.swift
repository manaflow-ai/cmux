import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Leo 2026-10-21, item D, the window half (Debug Settings `sidebar.multiView`): a window shows several
/// workspaces side by side. A sidebar row held and dragged onto a pane edge of the shown workspace goes on that
/// side of it, whole, instead of merging its tabs in; `SidebarModel.onScreen` is exactly the workspaces whose
/// content is on screen, frame by frame; a click on a row off screen, or a shown workspace closing, returns to
/// one; the window's record brings the set back. With the toggle off an edge drop still merges.
/// Each workspace `k0`...`k3` has one pane with a terminal and a browser tab; the window shows `k0`.
/// The drags need a display: on a host without one the window is clamped to its minimum size and the drop zones
/// resolve differently (the fleet's display-less minis), so the suite runs where there is a screen.
@MainActor @Suite(.serialized, .enabled(if: !NSScreen.screens.isEmpty, "the drag tests need a display"), .closesItsWindows)
struct SidebarMultiViewWindowTests {
    @MainActor final class Fixture {
        let services: AppServices
        let state: WindowState
        let controller: WindowController
        let keys: [String]

        init(keys: [String] = ["k0", "k1", "k2", "k3"], record: String? = nil, tree: DaemonTree? = nil, capabilities: [String] = []) async throws {
            _ = NSApplication.shared
            self.keys = keys
            services = AppServices(environment: AppEnvironment.current([:]))
            let store = services.machines.local.store
            let caps = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
            let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1","capabilities":["# + caps + "]}"
            let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
            store.noteHandshake(identity)
            store.connectionState = .connected(identity)
            store.apply(snapshot: tree ?? Self.tree(keys))
            if let record {
                // A relaunch: the window's state comes from its saved record.
                state = WindowState(record: try JSONDecoder().decode(WindowRecord.self, from: Data(record.utf8)))
                services.windows.registry.provisional[state.id] = keys
                controller = WindowController(state: state, services: services, frame: NSRect(x: 120, y: 120, width: 1200, height: 760))
            } else {
                // The window manager's own window, so the drag session finds it under the pointer.
                services.windows.ordersWindowsIn = false
                controller = try #require(services.windows.openWindow(workspaces: keys, frame: CGRect(x: 120, y: 120, width: 1200, height: 760)))
                state = controller.state
            }
            // A CI host without a display clamps a new window to its minimum size: set the frame outright.
            controller.window?.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 760), display: false)
            controller.window?.orderFrontRegardless()
            controller.showWorkspace(requested: state.workspaceID)
            try await Task.sleep(for: .milliseconds(300))
            frame()
        }

        /// `unread`: `k1`'s first tab holds an unread notification.
        static func tree(_ keys: [String], unread: Bool = false) -> DaemonTree {
            var tree = DaemonTree(registryID: "s-local", workspaces: keys.enumerated().map { index, key in
                WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: key), name: key,
                                  screens: [key == "k1" ? twoPanes(unread: unread) : SpaceSwitchBench.screen(Int(key.dropFirst()) ?? index)])
            })
            tree.personal = PersonalState(workspaces: keys.enumerated().map { index, key in
                PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: key), index: index)
            })
            return tree
        }

        /// `k1`'s screen: two panes side by side, a terminal each.
        static func twoPanes(unread: Bool) -> ScreenSnapshot {
            let note = unread ? TabNotification(notification: NotificationID(rawValue: 7), unread: true, level: .info, source: "agent") : nil
            let first = PaneSnapshot(id: PaneID(rawValue: 101), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 201), title: "~", notification: note)])
            let second = PaneSnapshot(id: PaneID(rawValue: 102), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 202), title: "~")])
            return ScreenSnapshot(id: ScreenID(rawValue: 101), layout: .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5,
                                                                              a: .leaf(first.id), b: .leaf(second.id)), panes: [first, second])
        }

        func close() {
            services.dragSession.finish(commit: false)
            services.dragSession.finishLanding()
            controller.teardown()
            controller.window?.close()
        }

        /// One frame: the window lays out and draws what the last event left.
        func frame() {
            for _ in 0..<3 { RunLoop.main.run(mode: .default, before: Date()) }
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            controller.window?.displayIfNeeded()
        }

        var list: SidebarListView { controller.sidebar.container.sidebarView.list }
        var model: SidebarModel { controller.sidebar.model }
        var onScreen: Set<String> { Set(model.onScreen.map(\.rawValue)) }

        /// What the window draws: every mounted workspace whose content view is in the content area, not hidden
        /// and not empty.
        var shown: Set<String> { Set(visible.map(\.workspace.id)) }

        var visible: [WorkspaceContentController] {
            controller.mountedContents.filter { content in
                let view = content.contentView
                return view.superview === controller.root.contentHost && !view.isHiddenOrHasHiddenAncestor && view.frame.width > 1 && view.frame.height > 1
            }
        }

        /// `id`'s content in window coordinates, when it is on screen.
        func windowFrame(_ id: String) -> CGRect? {
            visible.first { $0.workspace.id == id }.map { $0.contentView.convert($0.contentView.bounds, to: nil) }
        }

        func event(_ type: NSEvent.EventType, at windowPoint: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: controller.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1,
                                            pressure: type == .leftMouseUp ? 0 : 1))
        }

        /// The middle of `id`'s sidebar row, in window coordinates.
        func rowPoint(_ id: String) throws -> NSPoint {
            let row = try #require(list.displayed.row(for: .workspace(WorkspaceID(id))), "no row \(id)")
            return list.convert(NSPoint(x: 80, y: row.y + row.height / 2), to: nil)
        }

        /// A click on `id`'s sidebar row: press and release on it.
        func clickRow(_ id: String) throws {
            let point = try rowPoint(id)
            list.mouseDown(with: try event(.leftMouseDown, at: point))
            list.mouseUp(with: try event(.leftMouseUp, at: point))
        }

        /// A click in the middle of `id`'s content, through the window.
        func clickContent(_ id: String) throws {
            let frame = try #require(windowFrame(id), "\(id) is not on screen")
            let point = NSPoint(x: frame.midX, y: frame.midY)
            let window = try #require(controller.window)
            window.sendEvent(try event(.leftMouseDown, at: point))
            window.sendEvent(try event(.leftMouseUp, at: point))
        }

        /// A screen point on `edge`'s split zone of the shown workspace's pane: 15% of the pane in from that edge,
        /// past the window-edge dock band and inside the pane's split band. Tests use the left and bottom edges: a
        /// CI host without a display clamps the window to its minimum size, where a pane is wider than its layout
        /// and its right edge is out of view.
        func edgePoint(_ edge: TabDropEdge, inset: CGFloat = 0.15, points: CGFloat? = nil) throws -> CGPoint {
            let layout = try #require(controller.content?.layoutView)
            let window = try #require(layout.window)
            let r = layout.convert(layout.bounds, to: nil)
            let (dx, dy) = (points ?? r.width * inset, points ?? r.height * inset)
            let point = switch edge {
            case .left: CGPoint(x: r.minX + dx, y: r.midY)
            case .right: CGPoint(x: r.maxX - dx, y: r.midY)
            case .top: CGPoint(x: r.midX, y: r.maxY - dy)
            case .bottom: CGPoint(x: r.midX, y: r.minY + dy)
            }
            return window.convertPoint(toScreen: point)
        }

        /// A hold-then-drag of `id`'s sidebar row: pressed, lifted, carried out of the sidebar (the window drag
        /// takes it over there), over `edge`'s split zone of the shown workspace's pane, and released.
        func dragRow(_ id: String, to edge: TabDropEdge, inset: CGFloat = 0.15, points: CGFloat? = nil, release: Bool = true) throws {
            let start = try rowPoint(id)
            list.mouseDown(with: try event(.leftMouseDown, at: start))
            for dy in [CGFloat(-6), -12, -18] {
                list.mouseDragged(with: try event(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y + dy)))
                frame()
            }
            let content = try #require(controller.content).contentView
            let inside = content.convert(content.bounds, to: nil)
            list.mouseDragged(with: try event(.leftMouseDragged, at: NSPoint(x: inside.midX, y: inside.midY)))
            #expect(services.dragSession.drag != nil, "the window drag did not take the row over")
            let point = try edgePoint(edge, inset: inset, points: points)
            #expect(services.dragSession.window(at: point) === controller, "no window under the drag at \(point): \(geometry)")
            services.dragSession.update(point)
            frame()
            guard release else { return }
            services.dragSession.finish(commit: true)
            services.dragSession.finishLanding()
            frame()
        }

        /// Where the window and the shown layout are, for a failure's message.
        var geometry: String {
            let window = controller.window
            let layout = controller.content.map { $0.layoutView.convert($0.layoutView.bounds, to: nil) }
            let panes = controller.content?.panes.values.map { $0.view.convert($0.view.bounds, to: nil) } ?? []
            return "window \(window?.frame ?? .zero) visible \(window?.isVisible ?? false) layout \(layout ?? .zero) panes \(panes) "
                + "screens \(NSScreen.screens.map(\.frame)) ordered \(NSApp.orderedWindows.count) registered \(services.windows.controllers.count)"
        }

        /// The workspace's tabs, in order.
        func tabs(_ id: String) -> [String] {
            services.workspace(id: id)?.screens.flatMap(\.panes).flatMap(\.tabs).map(\.id) ?? []
        }
    }

    static func withMultiView<T>(_ on: Bool = true, _ body: () async throws -> T) async rethrows -> T {
        TunableStore.shared.register(SidebarTunables.all)
        TunableStore.shared.activate(file: nil)
        // Puts back what it found, so a test of the other multi-view suite that runs in this one's await keeps its value.
        let before = TunableStore.shared.override(SidebarTunables.multiView.key)
        TunableStore.shared.set(SidebarTunables.multiView.key, on ? .bool(true) : nil)
        precondition(SidebarTunables.multiView.value == on, "the sidebar.multiView override did not take")
        defer { TunableStore.shared.set(SidebarTunables.multiView.key, before) }
        return try await body()
    }

    // MARK: - Edge drops

    @Test func aRowDroppedOnAPaneEdgeShowsItsWorkspaceBesideTheShownOne() async throws {
        try await Self.withMultiView {
            let f = try await Fixture()
            defer { f.close() }
            let k1Tabs = f.tabs("k1")
            try #require(f.shown == ["k0"])

            try f.dragRow("k1", to: .left)
            #expect(f.shown == ["k0", "k1"], "the left-edge drop did not show k1 beside k0: \(f.shown) \(f.geometry)")
            #expect(f.state.workspaceID == "k0", "the drop switched the focused workspace")
            #expect(f.tabs("k1") == k1Tabs, "the drop moved k1's tabs: it merged instead of placing beside")
            #expect(f.services.workspace(id: "k1") != nil)
            let left = try #require(f.windowFrame("k1")), right = try #require(f.windowFrame("k0"))
            #expect(right.minX >= left.maxX, "k1 is not on k0's left: \(left) \(right)")
            #expect(abs(left.width - right.width) <= 1 && left.height == right.height, "the halves differ: \(left) \(right)")

            // Another row on the bottom edge goes under k0, k1 keeping its column.
            try f.dragRow("k2", to: .bottom)
            #expect(f.shown == ["k0", "k1", "k2"], "the bottom-edge drop: \(f.shown)")
            let top = try #require(f.windowFrame("k0")), bottom = try #require(f.windowFrame("k2"))
            #expect(bottom.maxY <= top.minY, "k2 is not under k0: \(top) \(bottom)") // window coordinates, y up
            #expect(abs(bottom.minX - top.minX) <= 1)
            #expect(f.state.workspaceID == "k0")
        }
    }

    /// The window drag previews the beside place while it hovers the edge; nothing changes until the release.
    @Test func hoveringAnEdgeShowsNothingNewUntilTheRelease() async throws {
        try await Self.withMultiView {
            let f = try await Fixture()
            defer { f.close() }
            try f.dragRow("k1", to: .bottom, release: false)
            #expect(f.shown == ["k0"])
            #expect(f.onScreen == ["k0"])
            f.services.dragSession.finish(commit: true)
            f.services.dragSession.finishLanding()
            f.frame()
            #expect(f.shown == ["k0", "k1"])
            let top = try #require(f.windowFrame("k0")), bottom = try #require(f.windowFrame("k1"))
            #expect(bottom.maxY <= top.minY, "k1 is not under k0: \(top) \(bottom)") // window coordinates, y up
        }
    }

    // MARK: - On screen, frame by frame

    @Test func onScreenIsTheShownSetInEveryFrame() async throws {
        try await Self.withMultiView {
            let f = try await Fixture()
            defer { f.close() }
            var step = "start"
            @MainActor func check(_ expected: Set<String>, focused: String, _ location: SourceLocation = #_sourceLocation) {
                f.frame()
                #expect(f.shown == expected, "\(step): the window shows \(f.shown)", sourceLocation: location)
                #expect(f.onScreen == f.shown, "\(step): onScreen \(f.onScreen) is not the shown set \(f.shown)", sourceLocation: location)
                #expect(f.state.workspaceID == focused, "\(step): focused \(f.state.workspaceID ?? "-")", sourceLocation: location)
                #expect(f.model.activeWorkspaceID?.rawValue == focused, "\(step): the sidebar's selected row", sourceLocation: location)
            }
            check(["k0"], focused: "k0")

            step = "k1 dropped on k0's left edge"
            try f.dragRow("k1", to: .left)
            check(["k0", "k1"], focused: "k0")

            step = "a click in k1's content"
            try f.clickContent("k1")
            check(["k0", "k1"], focused: "k1")

            step = "a click on k0's row"
            try f.clickRow("k0")
            check(["k0", "k1"], focused: "k0")

            step = "a click on k2's row (off screen)"
            try f.clickRow("k2")
            check(["k2"], focused: "k2")

            step = "back to k0 and k3 dropped on its left edge"
            try f.clickRow("k0")
            check(["k0"], focused: "k0")
            try f.dragRow("k3", to: .left)
            check(["k0", "k3"], focused: "k0")

            step = "k3 closed"
            f.services.machines.local.store.apply(snapshot: Fixture.tree(["k0", "k1", "k2"]))
            try await Task.sleep(for: .milliseconds(100))
            f.controller.showWorkspace(requested: f.state.workspaceID)
            check(["k0"], focused: "k0")
        }
    }

    /// A press on a pane of a workspace beside the focused one, through the app's event dispatch (the layout's own
    /// event monitor sees it first): that workspace is focused, and so is the pane pressed, not the one it last had.
    @Test func aPressOnAPaneOfAWorkspaceBesideFocusesThatWorkspaceAndPane() async throws {
        try await Self.withMultiView {
            let f = try await Fixture()
            defer { f.close() }
            try f.dragRow("k1", to: .left)
            try #require(f.shown == ["k0", "k1"])
            let k1 = try #require(f.visible.first { $0.workspace.id == "k1" })
            let order = k1.layoutModel.screens.flatMap(\.layout.panes)
            try #require(order.count == 2, "k1 has \(order.count) panes")
            let pressed = try #require(k1.panes[order[1]])
            let frame = pressed.view.convert(pressed.view.bounds, to: nil)
            let point = NSPoint(x: frame.midX, y: frame.midY)
            NSApp.sendEvent(try f.event(.leftMouseDown, at: point))
            NSApp.sendEvent(try f.event(.leftMouseUp, at: point))
            f.frame()
            #expect(f.state.workspaceID == "k1", "the press did not focus k1")
            #expect(f.shown == ["k0", "k1"])
            #expect(f.controller.focus.state.pane == pressed.paneKey,
                    "the focused pane is \(f.controller.focus.state.pane ?? "-"), not the pressed \(pressed.paneKey)")
        }
    }

    /// A workspace beside the focused one draws an attention ring that comes after it went on screen.
    @Test func aWorkspaceBesideDrawsARingThatComesAfterTheDrop() async throws {
        try await Self.withMultiView {
            let f = try await Fixture()
            defer { f.close() }
            try f.dragRow("k1", to: .left)
            try #require(f.shown == ["k0", "k1"])
            let k1 = try #require(f.visible.first { $0.workspace.id == "k1" })
            try #require(k1.layoutModel.attention.isEmpty)
            f.services.machines.local.store.apply(snapshot: Fixture.tree(f.keys, unread: true))
            try await Task.sleep(for: .milliseconds(100))
            f.frame()
            #expect(f.state.workspaceID == "k0")
            #expect(!k1.layoutModel.attention.isEmpty, "k1's unread tab draws no ring beside k0")
        }
    }

    /// The toggle turned off while a window shows two workspaces: it shows the focused one alone.
    @Test func turningTheToggleOffShowsTheFocusedWorkspaceAlone() async throws {
        try await Self.withMultiView {
            let f = try await Fixture()
            defer { f.close() }
            try f.dragRow("k1", to: .left)
            try #require(f.shown == ["k0", "k1"])
            TunableStore.shared.set(SidebarTunables.multiView.key, nil)
            try await Task.sleep(for: .milliseconds(100))
            f.frame()
            #expect(f.shown == ["k0"], "the window still shows \(f.shown)")
            #expect(f.onScreen.isEmpty)
            let k0 = try #require(f.windowFrame("k0"))
            let host = f.controller.root.contentHost
            #expect(k0.size == host.bounds.size, "k0 does not fill the content area: \(k0) in \(host.bounds)")
        }
    }

    // MARK: - The window's record

    @Test func theShownSetComesBackWithTheWindowsRecord() async throws {
        try await Self.withMultiView {
            let f = try await Fixture()
            try f.dragRow("k1", to: .left)
            try #require(f.shown == ["k0", "k1"])
            let record = try #require(f.services.windows.registry.value.record(f.state.id, state: f.state, order: 0))
            let json = try #require(String(data: try JSONEncoder().encode(record), encoding: .utf8))
            f.close()

            let again = try await Fixture(record: json)
            defer { again.close() }
            #expect(again.shown == ["k0", "k1"], "the relaunched window shows \(again.shown)")
            #expect(again.onScreen == ["k0", "k1"])
            #expect(again.state.workspaceID == "k0")
            let left = try #require(again.windowFrame("k1")), right = try #require(again.windowFrame("k0"))
            #expect(right.minX >= left.maxX)
        }
    }

    // MARK: - The toggle off

    @Test func withTheToggleOffAnEdgeDropStillMerges() async throws {
        try await Self.withMultiView(false) {
            let f = try await Fixture()
            defer { f.close() }
            // With the toggle off, a drag of the shown workspace's row starts as the window drag's own.
            let handoff = SidebarDragHandoff(payload: .workspaces([WorkspaceID("k1")]), workspaceIDs: [WorkspaceID("k1")],
                                             rowScreenFrame: CGRect(x: 300, y: 300, width: 220, height: 28),
                                             grabOffset: CGPoint(x: 20, y: 14), screenPoint: CGPoint(x: 320, y: 314), image: nil)
            #expect(f.services.dragSession.beginWorkspaces(handoff, from: f.controller))
            let point = try f.edgePoint(.left)
            f.services.dragSession.update(point)
            let drag = try #require(f.services.dragSession.drag)
            let pane = try #require(f.controller.content?.panes.values.first?.layoutPaneID.rawValue)
            #expect(drag.workspaceOutcome == .window(id: f.state.id, target: .merge(.newSplit(paneID: pane, edge: .left))),
                    "the edge drop is no longer the merge: \(drag.workspaceOutcome) at \(point): \(f.geometry)")
            f.services.dragSession.finish(commit: true)
            f.services.dragSession.finishLanding()
            f.frame()
            #expect(f.shown == ["k0"])
            #expect(f.model.onScreen.isEmpty, "the toggle off wrote onScreen")
            #expect(f.state.workspaceID == "k0")
        }
    }
}
