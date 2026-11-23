import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// A drag into Pinned pins the workspace, the one drag that pins (a pinned row unpins from its right-click menu; design
/// dp-1824f397ce), as the palette and the API do (Leo 2026-11-21:
/// "i dont think it works very well, especially with clicking and dragging"); Pinned used to refuse a workspace from
/// the list (#22263). The lift moves no row (Leo 2026-11-07: "it's super weird how when you drag ANY workspace, it
/// shifts imediately due to that").
///
/// The real list with the Pinned block's three rows and three list rows (`SidebarHomePinnedDragHarness`); the drop
/// is the one move the document is sent.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarDocPinnedDropTests {
    typealias Harness = SidebarHomePinnedDragHarness

    init() { Motion.reduceMotionOverride = true }

    /// Every pinned row's and list row's y in the list.
    static func ys(_ h: Harness) throws -> [String: CGFloat] {
        var ys: [String: CGFloat] = [:]
        for pin in Harness.pins {
            let view = try h.item(pin.id)
            ys[pin.id.rawValue] = h.list.convert(view.bounds, from: view).minY
        }
        for id in Harness.loose { ys[id.rawValue] = h.list.displayed.row(for: .workspace(id))?.y }
        return ys
    }

    @Test func aWorkspaceFromTheListDraggedBetweenPinnedRowsIsPinned() throws {
        defer { Motion.reduceMotionOverride = nil }
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let h = Harness()
        defer { h.close() }
        let id = Harness.loose[0]
        let row = try #require(h.list.displayed.row(for: .workspace(id)))
        let target = try h.item(Harness.pins[1].id)
        let middle = h.list.convert(target.bounds, from: target).midY
        let before = try Self.ys(h)
        let start = NSPoint(x: 80, y: row.y + row.height / 2)
        h.list.press = SidebarPress(key: .workspace(id), point: start)
        h.list.beginDrag(try #require(h.list.press))
        #expect(h.list.drag != nil, "the list row did not lift")
        h.settle()
        for (key, y) in try Self.ys(h) where key != id.rawValue {
            #expect(abs((before[key] ?? y) - y) <= 0.5, "the lift moved \(key) from \(before[key] ?? 0) to \(y)")
        }
        var y = start.y
        while y > middle {
            y = max(middle, y - 3)
            h.list.updateDrag(windowPoint: h.list.convert(NSPoint(x: start.x, y: y), to: nil))
        }
        for _ in 0..<3 { h.list.updateDrag(windowPoint: h.list.convert(NSPoint(x: start.x, y: y), to: nil)) }
        #expect(h.list.drag?.docTarget?.section == SidebarDocStore.pinnedSection,
                "Pinned refuses the workspace: \(String(describing: h.list.drag?.docTarget))")
        h.list.finishDrag()
        h.finishFlights()
        #expect(h.drops.count == 1 && h.drops.first?.0 == ["itm_" + id.rawValue]
                    && h.drops.first?.1.section == SidebarDocStore.pinnedSection,
                "the drop did not pin the workspace: \(h.drops.map { "\($0.0) -> \($0.1)" })")
        h.expectEveryRowAtRest("after a list row dropped into Pinned")
    }
}
