import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// What one drag move costs in a real list, end to end: `SidebarListView.updateDrag` from the pointer to the drawn look,
/// with the drag base check (`dragBase`) timed on its own. `SidebarDragMoveCostTests` times the resolve's parts; this
/// one also counts the options the base check builds and the look a new target draws (`showDragLayout`).
/// Leo 2026-11-04: "It should just never, ever ... be acceptable for there to be some sort of linear time growth
/// degradation". The harness lists `count` workspaces in groups of 10 in the app's sidebar, lifts the first one and moves it down 3 points
/// per move for 200 moves, a hand's pace; it prints `DRAG-FULL-MOVE` lines per size.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarDragFullMoveCostTests {
    static let sizes = [50, 200, 1000, 5000]
    static let moves = 200

    /// The app's sidebar (its scroll view realizes the visible rows only) over `count` workspaces.
    static func list(_ count: Int) -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let groups = stride(from: 0, to: count, by: 10).map { start in
            SidebarNode.group(SidebarGroup(id: GroupID("fm-g\(start)"), name: "Group \(start)", color: .green,
                                           workspaces: (start..<min(count, start + 10)).map {
                                               SidebarWorkspace(id: WorkspaceID("fm-\($0)"), title: "workspace \($0)")
                                           }))
        }
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: groups)], activeWorkspaceID: nil)
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 800)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 800), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(sidebar)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        return (sidebar.list, window)
    }

    static func stat(_ values: [Double], _ q: Double) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))]
    }

    static func microseconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds &- start) / 1000
    }

    /// One drag of the first workspace over `count` rows: each move's cost, split by whether it drew a new target,
    /// and the base check's cost alone.
    static func sweep(_ count: Int) throws -> (held: [Double], retarget: [Double], base: [Double], seen: String) {
        let (list, window) = list(count)
        defer { window.close() }
        let row = try #require(list.displayed.row(for: .workspace(WorkspaceID("fm-0"))))
        let start = NSPoint(x: 80, y: row.y + row.height / 2)
        list.press = SidebarPress(key: row.key, point: start)
        list.beginDrag(try #require(list.press))
        let drag = try #require(list.drag)
        var held: [Double] = [], retarget: [Double] = [], base: [Double] = [], targets: [String] = []
        for step in 1...moves {
            let before = drag.target
            let point = list.convert(NSPoint(x: start.x, y: start.y + 3 * CGFloat(step)), to: nil)
            let cost = microseconds { list.updateDrag(windowPoint: point) }
            if drag.target == before { held.append(cost) } else { retarget.append(cost) }
            base.append(microseconds { _ = list.dragBase(drag) })
            if drag.target != before { targets.append(drag.target.map { String(describing: $0) } ?? "nil") }
        }
        // What the sweep resolved: its first targets and the last move's probe, so a sweep that never retargets says why.
        var seen = "targets=\(targets.prefix(3)) probe=\(drag.probe.map { String(describing: $0) } ?? "nil")"
        // Where a move's time goes, at the sweep's end: each part's median of 20 calls.
        let point = drag.lastWindowPoint
        let parts: [(String, () -> Void)] = [
            ("pin", { _ = SidebarListPinDrop.holds(list, drag, at: point) }),
            ("gate", { _ = SidebarGroupDrop.gate(list, drag, card: drag.probeCard, resolved: nil) }),
            ("options", { _ = list.options(includeGap: true) }),
            ("make", { _ = SidebarLayout.make(sections: list.listSections, metrics: list.metrics, options: list.options(includeGap: false)) }),
            ("displayLayout", { _ = list.displayLayout() }),
            ("groupLines", { _ = list.groupLines(list.displayed) }),
            ("frames", { for row in list.displayed.rows { _ = list.frame(for: row) } }),
            ("showDragLayout", { list.showDragLayout() }),
        ]
        for (name, part) in parts {
            seen += String(format: " %@=%.1fus", name, stat((0..<20).map { _ in microseconds(part) }, 0.5))
        }
        list.cancelDrag()
        return (held, retarget, base, seen)
    }

    /// The base is made once per drag and again only after a reload (any change of the options the list draws runs
    /// one) or a width change: a move reuses it and builds no options.
    @Test func theDragBaseHoldsAcrossMovesUntilTheListReloads() throws {
        let (list, window) = Self.list(50)
        defer { window.close() }
        let row = try #require(list.displayed.row(for: .workspace(WorkspaceID("fm-0"))))
        let start = NSPoint(x: 80, y: row.y + row.height / 2)
        list.press = SidebarPress(key: row.key, point: start)
        list.beginDrag(try #require(list.press))
        let drag = try #require(list.drag)
        let move = { (dy: CGFloat) in list.updateDrag(windowPoint: list.convert(NSPoint(x: start.x, y: start.y + dy), to: nil)) }
        move(3)
        let first = try #require(drag.base?.rules)
        move(40)
        move(90)
        #expect(drag.base?.rules === first, "a move made the drag's base again")
        list.reload(animated: false)
        move(93)
        let reloaded = try #require(drag.base?.rules)
        #expect(reloaded !== first, "a reload left the drag's base as it was")
        list.setFrameSize(NSSize(width: list.frame.width - 20, height: list.frame.height))
        move(96)
        #expect(drag.base?.rules !== reloaded, "a width change left the drag's base as it was")
        list.cancelDrag()
    }

    @Test func dragFullMoveCostPerSize() throws {
        _ = try Self.sweep(50) // warm the reducer, the layout and the allocator
        for count in Self.sizes {
            let (held, retarget, base, seen) = try Self.sweep(count)
            print(String(format: "DRAG-FULL-MOVE rows=%d held n=%d p50=%.1fus p95=%.1fus | retarget n=%d p50=%.1fus p95=%.1fus | base check p50=%.1fus p95=%.1fus",
                         count, held.count, Self.stat(held, 0.5), Self.stat(held, 0.95), retarget.count,
                         Self.stat(retarget, 0.5), Self.stat(retarget, 0.95), Self.stat(base, 0.5), Self.stat(base, 0.95)) + " | \(seen)")
        }
    }
}
