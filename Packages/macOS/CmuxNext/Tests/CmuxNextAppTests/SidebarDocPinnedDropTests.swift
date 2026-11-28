import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// A drag never pins, as in classic cmux (Lucas 2026-11-26: "you should not be allowed to move a workspace that is not
/// pinned above a pinned workspace. the current logic allows you move a workspace above a pinned one and from that it
/// pins that workspace"). The reducer refuses a list workspace beside the pinned rows, beside Home and into Pinned
/// (`drag_begin`'s top tier, `pinned`); with that table, a list row dragged up over the pinned rows shows no drop in
/// Pinned, opens no "Drop here to pin" row, and its release is not sent to Pinned or Top. The lift moves no row (Leo
/// 2026-11-07: "it's super weird how when you drag ANY workspace, it shifts imediately due to that").
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

    @Test func aWorkspaceFromTheListDraggedOverPinnedRowsIsNotPinned() throws {
        defer { Motion.reduceMotionOverride = nil }
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let h = Harness()
        defer { h.close() }
        // The reducer's table for a list workspace: the top sections refuse it, the machine list takes it.
        let topKeys = Set(Harness.pins.map(\.id.rawValue) + [SidebarDocStore.pinnedSection, Harness.home.id.rawValue,
                                                              SidebarLayoutDocument.topSectionID.rawValue])
        let listKeys = [Harness.machineSection] + Harness.loose.map { "itm_" + $0.rawValue }
        h.list.model.docDrag?.begin = { dragged in
            var table: [String: SidebarDocAcceptance] = [:]
            for key in topKeys { table[key] = SidebarDocAcceptance(before: false, into: false, after: false, refusal: "pinned") }
            for key in listKeys {
                table[key] = dragged.contains(key) ? SidebarDocAcceptance(before: false, into: false, after: false, refusal: "self")
                    : SidebarDocAcceptance(before: true, into: key == Harness.machineSection, after: true)
            }
            return table
        }
        let id = Harness.loose[1]
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
            let section = h.list.drag?.docTarget?.section
            #expect(section != SidebarDocStore.pinnedSection && section != SidebarLayoutDocument.topSectionID.rawValue,
                    "the drag shows a drop in a top section at y \(y): \(String(describing: h.list.drag?.docTarget))")
        }
        #expect(h.list.drag?.openZone != SidebarDocStore.pinnedSection, "a \"Drop here to pin\" row opened")
        h.list.finishDrag()
        h.finishFlights()
        for (items, target) in h.drops {
            #expect(target.section != SidebarDocStore.pinnedSection && target.section != SidebarLayoutDocument.topSectionID.rawValue,
                    "\(items) dropped into a top section: \(target)")
        }
        h.expectEveryRowAtRest("after a list row dragged over the pinned rows")
    }
}
