import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Leo 2026-11-08 (ask-2ba1bed2e4), our sidebar beside a browser's vertical tabs moving a selection: "ours vs edge's group
/// moving i think we need to make ours more like edge and chrome". The browser lifts every selected tab, stacked, under the
/// pointer, and the list opens one gap that tall. Ours lifted only the pressed row with a count badge, while the list
/// opened a gap for all the selected rows: the one-row card rode over rows that had not made way, and the gap below it
/// stood empty. The card carries every selected row in the order the drop lays them out, the pressed row stays under
/// the pointer, and the card is as tall as the gap the list opens for it.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarMultiDragStackTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)

    static func list() -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let names = ["a", "b", "c", "d", "e", "f", "g", "h"]
        let sections = [SidebarSection(kind: .machine(machine), nodes: names.map { .workspace(SidebarWorkspace(id: WorkspaceID($0), title: $0)) })]
        let model = SidebarModel(sections: sections, activeWorkspaceID: WorkspaceID("a"))
        let list = SidebarListView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 700))
        window.contentView = root
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        return (list, window)
    }

    static func rowViews(on lift: NSView) -> [SidebarRowView] {
        lift.subviews.flatMap { view -> [SidebarRowView] in
            if let row = view as? SidebarRowView { return [row] }
            return rowViews(on: view)
        }
    }

    /// Lifts `pressed` with `selected` selected; returns the list, its window and the pressed row's frame before the lift.
    static func lift(_ selected: [String], pressed: String) throws -> (SidebarListView, NSWindow, NSPoint, CGFloat, CGFloat) {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let (list, window) = list()
        list.model.selection = Set(selected.map(WorkspaceID.init))
        list.reload(animated: false)
        let key = SidebarRowKey.workspace(WorkspaceID(pressed))
        let row = try #require(list.displayed.row(for: key))
        let start = NSPoint(x: 80, y: row.y + row.height / 2)
        list.press = SidebarPress(key: key, point: start)
        list.beginDrag(try #require(list.press))
        return (list, window, start, row.y, row.height)
    }

    /// Three selected rows next to each other, the middle one pressed: the card holds all three, where they were.
    @Test func aSelectionLiftsEveryRowAsOneStack() throws {
        let (list, window, _, _, rowHeight) = try Self.lift(["c", "d", "e"], pressed: "d")
        defer { window.close() }
        let drag = try #require(list.drag, "the selection did not lift")
        let spacing = list.displayed.rowSpacing
        let c = drag.lift.frame
        let rows = Self.rowViews(on: drag.lift)
        #expect(rows.count == 3, "the card carries \(rows.count) row(s), not the 3 selected")
        #expect(abs(c.height - (3 * rowHeight + 2 * spacing)) < 0.5, "the card is \(c.height) tall, not three rows")
        #expect(abs(drag.gapHeight - c.height) < 0.5, "the gap (\(drag.gapHeight)) is not the card's height (\(c.height))")
    }

    /// A selection that is not next to each other closes up on the card: in drop order, the pressed row under the
    /// pointer, the card as tall as the gap.
    @Test func aScatteredSelectionStacksAroundThePressedRow() throws {
        let (list, window, _, pressedY, rowHeight) = try Self.lift(["b", "d", "g"], pressed: "d")
        defer { window.close() }
        let drag = try #require(list.drag, "the selection did not lift")
        let spacing = list.displayed.rowSpacing
        let card = drag.lift.frame
        let rows = Self.rowViews(on: drag.lift).sorted { $0.frame.minY < $1.frame.minY }
        #expect(rows.count == 3, "the card carries \(rows.count) row(s), not the 3 selected")
        // b is above d in the stack: the card starts one row (and its spacing) above where d was.
        #expect(abs(card.minY - (pressedY - rowHeight - spacing)) < 0.5, "d moved under the pointer: card top \(card.minY), d was at \(pressedY)")
        #expect(abs(drag.gapHeight - card.height) < 0.5)
    }

    /// Moving the stack down the list: on every frame the list's open gap is the card's height (the rows below make
    /// way for the whole stack, not for one row).
    @Test func theGapIsTheStacksHeightOnEveryFrame() throws {
        let (list, window, start, _, _) = try Self.lift(["b", "c", "d"], pressed: "c")
        defer { window.close() }
        let drag = try #require(list.drag, "the selection did not lift")
        let spacing = list.displayed.rowSpacing
        var failures: [String] = []
        var y = start.y
        let bottom = (list.displayed.rows.last?.maxY ?? 400) + 10
        while y < bottom {
            y += 6
            list.updateDrag(windowPoint: list.convert(NSPoint(x: start.x, y: y), to: nil))
            guard list.displayed.gapY != nil else { continue }
            let gap = list.displayed.gapShift - spacing
            if abs(gap - drag.lift.frame.height) > 0.5 { failures.append("y \(Int(y)): gap \(gap), card \(drag.lift.frame.height)") }
        }
        #expect(failures.isEmpty, "\(failures.prefix(8).joined(separator: "\n"))")
    }

    /// The stack moves its drop as one row does: a little over one row down, the rows below have made way once.
    @Test func theStackMovesItsDropWithinOneRow() throws {
        let (list, window, start, _, rowHeight) = try Self.lift(["b", "c", "d"], pressed: "c")
        defer { window.close() }
        let drag = try #require(list.drag, "the selection did not lift")
        let origin = drag.target
        var y = start.y
        let end = start.y + rowHeight + list.displayed.rowSpacing + 4
        while y < end {
            y = min(end, y + 4)
            list.updateDrag(windowPoint: list.convert(NSPoint(x: start.x, y: y), to: nil))
        }
        #expect(drag.target != origin, "a row and a bit down, the stack's drop is still \(String(describing: drag.target))")
    }
}
