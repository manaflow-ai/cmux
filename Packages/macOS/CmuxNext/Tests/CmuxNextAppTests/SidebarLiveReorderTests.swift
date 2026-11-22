import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// nxdog30 (R77 preflight, 2026-10-04): while Gamma is held over Alpha in a
/// live window (mouse events through the sidebar, the bridge selecting the
/// pressed workspace), Alpha must draw in its moved slot, never as an empty
/// row. Windows never go on screen.
///
/// The row moves are AppKit `animator()` frame animations, which advance only
/// in a GUI session with a display: on a display-less host (the EC2 fleet
/// Macs, `NSScreen.screens` empty) they never run and the row keeps its old
/// frame. Skipped there (cmux-ci 75001ce577efbc629038d12d fails both tests
/// alone on aws-m4pro; triage-live-f56c5cc7 passes 3 of 3 on a mini).
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)), .requiresGUISession) struct SidebarLiveReorderTests {
    static let keys = ["0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a01", "0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a02", "0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a03"]
    static let names = ["Alpha", "Beta", "Gamma"]

    static func tree(count: Int = 3, focused: Int = 0) throws -> DaemonTree {
        let workspaces = zip(keys, names).prefix(count).enumerated().map { index, pair in
            let base = (index + 1) * 10
            return """
            {"active":\(index == focused),"id":\(base),"key":"\(pair.0)","name":"\(pair.1)","screens":[{"active":true,"id":\(base + 1),
            "layout":{"pane":\(base + 2),"type":"leaf"},"name":null,"panes":[{"active_tab":0,"id":\(base + 2),"name":null,
            "tabs":[{"kind":"pty","name":"zsh","surface":\(base + 3),"dead":false,"cwd":"/tmp"}]}]}]}
            """
        }
        let json = #"{"generation":"g1","workspace_revision":"# + "\(2 + count)" + #","workspaces":["# + workspaces.joined(separator: ",") + "]}"
        return try JSONDecoder().decode(DaemonTree.self, from: Data(json.utf8))
    }

    /// Waits until `condition` holds, at most `limit`. The row moves are
    /// animator() frame animations driven by the main run loop, so under a
    /// loaded parallel run they land later than any fixed sleep; a fixed
    /// sleep then reads the old frame although the row does move.
    static func eventually(within limit: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock(), deadline = clock.now + limit
        while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(16)) }
    }

    static func event(_ type: NSEvent.EventType, _ point: NSPoint, in list: NSView) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: list.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: list.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    }

    @Test func theRowUnderTheHeldRowDrawsInItsMovedSlot() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        services.daemon.store.apply(snapshot: try Self.tree())
        let controller = try #require(services.windows.openWindow(workspaces: Self.keys))
        services.windows.reconcileMembership()
        defer { controller.window?.close() }
        let sidebar = controller.sidebar.container.sidebarView
        await LocationTrailWiringTests.settle { sidebar.model.allWorkspaces.count == 3 }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let list = sidebar.list
        list.reload(animated: false)
        func row(_ name: String) -> SidebarRow? {
            list.displayed.rows.first { row in
                if case let .workspace(id) = row.key { return sidebar.model.workspace(id)?.title == name }
                return false
            }
        }
        let alpha = try #require(row("Alpha")), gamma = try #require(row("Gamma"))
        let press = NSPoint(x: list.frame(for: gamma).minX + 40, y: list.frame(for: gamma).midY)
        list.mouseDown(with: try #require(Self.event(.leftMouseDown, press, in: list)))
        let over = NSPoint(x: press.x, y: list.frame(for: alpha).minY + 2)
        for step in 1...8 {
            let y = press.y + (over.y - press.y) * CGFloat(step) / 8
            list.mouseDragged(with: try #require(Self.event(.leftMouseDragged, NSPoint(x: press.x, y: y), in: list)))
            await Task.yield()
        }
        try await Self.eventually {
            guard let moved = row("Alpha"), let view = list.rowViews[moved.key] else { return false }
            return view.frame == list.frame(for: moved)
        }
        #expect(list.drag != nil)
        let moved = try #require(row("Alpha"))
        let view = try #require(list.rowViews[moved.key], "Alpha has a row view")
        #expect(view.superview === list)
        #expect(view.alphaValue == 1, "Alpha is drawn")
        #expect(view.frame == list.frame(for: moved), "Alpha sits in its moved slot")
        #expect(moved.y > alpha.y, "Alpha moved down for Gamma")
        list.mouseUp(with: try #require(Self.event(.leftMouseUp, over, in: list)))
    }

    /// As in nxdog30: the workspaces arrive one by one (each focused as it
    /// is created) with time for every animation, then Gamma is dragged.
    @Test func afterWorkspacesArriveOneByOneTheHeldDragKeepsEveryOtherRow() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        services.daemon.store.apply(snapshot: try Self.tree(count: 1, focused: 0))
        let controller = try #require(services.windows.openWindow(workspaces: [Self.keys[0]]))
        services.windows.reconcileMembership()
        defer { controller.window?.close() }
        let sidebar = controller.sidebar.container.sidebarView
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        for count in 2...3 {
            try await Task.sleep(for: .milliseconds(400))
            services.daemon.store.apply(snapshot: try Self.tree(count: count, focused: count - 1))
            services.windows.reconcileMembership()
        }
        await LocationTrailWiringTests.settle { sidebar.model.allWorkspaces.count == 3 }
        try await Task.sleep(for: .milliseconds(900))
        let list = sidebar.list
        func row(_ name: String) -> SidebarRow? {
            list.displayed.rows.first { row in
                if case let .workspace(id) = row.key { return sidebar.model.workspace(id)?.title == name }
                return false
            }
        }
        let alpha = try #require(row("Alpha")), gamma = try #require(row("Gamma"))
        let press = NSPoint(x: list.frame(for: gamma).minX + 40, y: list.frame(for: gamma).midY)
        list.mouseDown(with: try #require(Self.event(.leftMouseDown, press, in: list)))
        let over = NSPoint(x: press.x, y: list.frame(for: alpha).minY + 2)
        for step in 1...12 {
            let y = press.y + (over.y - press.y) * CGFloat(step) / 12
            list.mouseDragged(with: try #require(Self.event(.leftMouseDragged, NSPoint(x: press.x, y: y), in: list)))
            try await Task.sleep(for: .milliseconds(16))
        }
        try await Self.eventually {
            guard let moved = row("Alpha"), let view = list.rowViews[moved.key] else { return false }
            return view.frame == list.frame(for: moved)
        }
        let moved = try #require(row("Alpha"))
        let view = list.rowViews[moved.key]
        let selection = sidebar.model.orderedSelection.compactMap { sidebar.model.workspace($0)?.title }
        let diag = "selection \(selection), suppressed \(list.suppressed.count), view \(String(describing: view?.frame)) alpha \(String(describing: view?.alphaValue)) super \(view?.superview === list)"
        #expect(view?.superview === list, "\(diag)")
        #expect(view?.alphaValue == 1, "\(diag)")
        #expect(view?.frame == list.frame(for: moved), "\(diag)")
        list.mouseUp(with: try #require(Self.event(.leftMouseUp, over, in: list)))
    }
}
