import AppKit
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// What one drag move costs in a real list, end to end: `SidebarListView.updateDrag` from the pointer to the drawn look,
/// with the drag base check (`dragBase`) timed on its own. `SidebarDragMoveCostTests` times the resolve's parts; this
/// one also counts the options the base check builds and the look a new target draws (`showDragLayout`).
/// Leo 2026-11-04: "It should just never, ever ... be acceptable for there to be some sort of linear time growth
/// degradation". The harness lists `count` workspaces in groups of 10, lifts the first one and moves it down 3 points
/// per move for 200 moves, a hand's pace; it prints `DRAG-FULL-MOVE` lines per size.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarDragFullMoveCostTests {
    static let sizes = [50, 200, 1000, 5000]
    static let moves = 200

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
        let list = SidebarListView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 800))
        window.contentView = root
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        return (list, window)
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
    static func sweep(_ count: Int) throws -> (held: [Double], retarget: [Double], base: [Double]) {
        let (list, window) = list(count)
        defer { window.close() }
        let row = try #require(list.displayed.row(for: .workspace(WorkspaceID("fm-0"))))
        let start = NSPoint(x: 80, y: row.y + row.height / 2)
        list.press = SidebarPress(key: row.key, point: start)
        list.beginDrag(try #require(list.press))
        let drag = try #require(list.drag)
        var held: [Double] = [], retarget: [Double] = [], base: [Double] = []
        for step in 1...moves {
            let before = drag.target
            let point = list.convert(NSPoint(x: start.x, y: start.y + 3 * CGFloat(step)), to: nil)
            let cost = microseconds { list.updateDrag(windowPoint: point) }
            if drag.target == before { held.append(cost) } else { retarget.append(cost) }
            base.append(microseconds { _ = list.dragBase(drag) })
        }
        list.cancelDrag()
        return (held, retarget, base)
    }

    @Test func dragFullMoveCostPerSize() throws {
        _ = try Self.sweep(50) // warm the reducer, the layout and the allocator
        for count in Self.sizes {
            let (held, retarget, base) = try Self.sweep(count)
            print(String(format: "DRAG-FULL-MOVE rows=%d held n=%d p50=%.1fus p95=%.1fus | retarget n=%d p50=%.1fus p95=%.1fus | base check p50=%.1fus p95=%.1fus",
                         count, held.count, Self.stat(held, 0.5), Self.stat(held, 0.95), retarget.count,
                         Self.stat(retarget, 0.5), Self.stat(retarget, 0.95), Self.stat(base, 0.5), Self.stat(base, 0.95)))
        }
    }
}
