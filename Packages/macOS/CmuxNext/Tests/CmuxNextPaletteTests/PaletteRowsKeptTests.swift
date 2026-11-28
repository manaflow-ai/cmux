import AppKit
import CmuxNextDesign
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Testing

/// Cmd-Shift-P and Cmd-P show new results in the rows already on screen (CMUX NEXT Stable perf gate). An open sets the
/// list's results twice (its first frame, then the full list), and each set reloaded the table: every row on screen
/// left the table and was made again, with its first layout and the window's key view loop. On the bench (mini, 120 Hz,
/// 30 opens) that was most of the open's commit stage, 11 to 19 ms of a 16.7 ms frame. Results of the same shape (a
/// header where a header was, a result where a result was) now configure the rows the table already holds, and the
/// list shows exactly what a list made for those results shows.
@MainActor
@Suite(.closesItsWindows)
struct PaletteRowsKeptTests {
    /// A list in a window tall enough to show every row of these tests.
    static func host() throws -> (PaletteListView, NSTableView, NSWindow) {
        _ = NSApplication.shared
        let size = NSSize(width: 640, height: 1200)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let list = PaletteListView(frame: NSRect(origin: .zero, size: size))
        window.contentView = list
        let table = try #require(list.documentView as? NSTableView)
        return (list, table, window)
    }

    /// A frame: the list laid out, and each visible row's view and cell made as the table's draw makes them. A reload's
    /// rows are made when the table draws, and a window no one shows never draws, so a list read after a reload alone
    /// shows none; a row on screen already is kept as it is.
    static func settle(_ list: PaletteListView) {
        list.needsLayout = true
        list.layoutSubtreeIfNeeded()
        guard let table = list.documentView as? NSTableView else { return }
        let visible = table.rows(in: table.visibleRect)
        for row in visible.location..<NSMaxRange(visible) {
            _ = table.rowView(atRow: row, makeIfNecessary: true)
            _ = table.view(atColumn: 0, row: row, makeIfNecessary: true)
        }
    }

    static func row(_ id: String, _ title: String, subtitle: String? = nil, isEnabled: Bool = true) -> PaletteRow {
        PaletteRow(item: PaletteItem(id: id, title: title, subtitle: subtitle, isEnabled: isEnabled,
                                     primary: PaletteCommand(id: "open", title: "Open", effect: .perform {})),
                   highlights: [], score: 0)
    }

    /// Sections titled `"<prefix> <n>"` (an empty title has no header row), with `counts` rows each, ids and titles
    /// from `prefix`. Every third row has a subtitle; `disabled` rows (by id) are greyed.
    static func sections(_ prefix: String, _ counts: [Int], titled: Bool = true,
                         disabled: Set<String> = []) -> [PaletteResultSection] {
        counts.enumerated().map { index, count in
            PaletteResultSection(
                section: PaletteSection(id: "\(prefix)-section-\(index)", title: titled ? "\(prefix) \(index)" : "",
                                        order: index),
                rows: (0..<count).map { n in
                    let id = "\(prefix)\(index).\(n)"
                    return row(id, "\(prefix) title \(index).\(n)", subtitle: n % 3 == 0 ? "\(prefix) path \(n)" : nil,
                               isEnabled: !disabled.contains(id))
                })
        }
    }

    /// What every row on screen shows, in order: its place and height, its kind and text, greyed or not, selected and
    /// hovered (the palette's and the table's).
    static func shown(_ table: NSTableView) -> [String] {
        (0..<table.numberOfRows).map { row in
            let frame = table.rect(ofRow: row)
            let rowView = table.rowView(atRow: row, makeIfNecessary: false) as? PaletteTableRowView
            var text = "\(row) y=\(frame.minY) h=\(frame.height) selected=\(rowView?.isPaletteSelected ?? false)"
                + " hovered=\(rowView?.isHovered ?? false) tableSelected=\(table.isRowSelected(row))"
            switch table.view(atColumn: 0, row: row, makeIfNecessary: false) {
            case let header as PaletteSectionHeaderCell:
                text += " header \(header.title)"
            case let cell as PaletteRowCell:
                text += " item \(cell.accessibilityLabel() ?? "-") alpha=\(cell.alphaValue)"
                text += " subtitle=\(cell.subtitle.isHidden ? "-" : cell.subtitle.stringValue)"
            case let other:
                text += " cell=\(other.map { String(describing: type(of: $0)) } ?? "none")"
            }
            return text
        }
    }

    @Test func newResultsOfTheSameShapeShowInTheRowsOnScreen() throws {
        let (list, table, window) = try Self.host()
        defer { window.closeAfterTest() }
        list.setSections(Self.sections("a", [3, 4]))
        Self.settle(list)
        let rowViews = (0..<table.numberOfRows).map { table.rowView(atRow: $0, makeIfNecessary: false) }
        let cells = (0..<table.numberOfRows).map { table.view(atColumn: 0, row: $0, makeIfNecessary: false) }
        try #require(table.numberOfRows == 9 && rowViews.allSatisfy { $0 != nil }, "the list showed no rows to keep")

        list.setSections(Self.sections("b", [3, 4]))
        for row in 0..<table.numberOfRows {
            #expect(table.rowView(atRow: row, makeIfNecessary: false) === rowViews[row],
                    "row \(row) left the table and is made again for results of the same shape")
            #expect(table.view(atColumn: 0, row: row, makeIfNecessary: false) === cells[row],
                    "row \(row)'s cell left the table and is made again for results of the same shape")
        }
        Self.settle(list)
        let header = table.view(atColumn: 0, row: 0, makeIfNecessary: false) as? PaletteSectionHeaderCell
        #expect(header?.title == "b 0", "the header shows the old results")
        let cell = table.view(atColumn: 0, row: 1, makeIfNecessary: false) as? PaletteRowCell
        #expect(cell?.accessibilityLabel() == "b title 0.0", "the row shows the old results")
    }

    /// The results before and after each change these tests make.
    static func change(_ name: String) -> (before: [PaletteResultSection], after: [PaletteResultSection]) {
        let greyed: Set<String> = ["a0.1", "a1.3"]
        return switch name {
        case "same shape": (sections("a", [3, 4]), sections("b", [3, 4]))
        case "more rows": (sections("a", [3, 2]), sections("b", [3, 5]))
        case "more sections": (sections("a", [3]), sections("b", [3, 2]))
        case "fewer rows": (sections("a", [3, 5]), sections("b", [3, 2]))
        case "fewer sections": (sections("a", [2, 3, 2]), sections("b", [2]))
        case "another shape": (sections("a", [3, 4]), sections("b", [1, 5]))
        case "headers gone": (sections("a", [3, 4]), sections("b", [7], titled: false))
        case "headers come": (sections("a", [7], titled: false), sections("b", [3, 3]))
        case "from none": ([], sections("b", [3, 4]))
        case "to none": (sections("a", [3, 4]), [])
        case "greyed": (sections("a", [3, 4]), sections("a", [3, 4], disabled: greyed))
        case "greyed back": (sections("a", [3, 4], disabled: greyed), sections("a", [3, 4]))
        case "same rows": (sections("a", [3, 4]), sections("a", [3, 4]))
        case "sections swap": (sections("a", [3, 4]), Array(sections("a", [3, 4]).reversed()))
        default: ([], [])
        }
    }

    /// For each change of results, the list that had the old ones shows what a list made for the new ones shows:
    /// the same shape, more or fewer rows, another shape, no rows, greyed rows, and the selected and hovered row
    /// moving to another place.
    @Test(arguments: ["same shape", "more rows", "more sections", "fewer rows", "fewer sections", "another shape",
                      "headers gone", "headers come", "from none", "to none", "greyed", "greyed back", "same rows",
                      "sections swap"])
    func anUpdatedListShowsWhatAFreshListShows(_ name: String) throws {
        let (before, after) = Self.change(name)
        try #require(!before.isEmpty || !after.isEmpty, "no change named \(name)")
        for (selected, hovered) in [(nil, nil), ("a1.2", "a0.0"), ("b0.1", "b1.1"), ("a0.1", "a0.1")] as [(String?, String?)] {
            let (updated, updatedTable, updatedWindow) = try Self.host()
            defer { updatedWindow.closeAfterTest() }
            updated.setSections(before)
            updated.setSelection(selected)
            updated.setHover(hovered)
            Self.settle(updated)
            updated.setSections(after)
            Self.settle(updated)

            let (fresh, freshTable, freshWindow) = try Self.host()
            defer { freshWindow.closeAfterTest() }
            fresh.setSelection(selected)
            fresh.setHover(hovered)
            fresh.setSections(after)
            Self.settle(fresh)

            #expect(Self.shown(updatedTable) == Self.shown(freshTable),
                    "\(name), selected \(selected ?? "-"), hovered \(hovered ?? "-"): the updated list shows other rows")
            #expect(updatedTable.numberOfRows == freshTable.numberOfRows)
        }
    }

    /// Results set after a header height change (a setting no window or text size follows) show headers at the new
    /// height, as a list made for them does, not the height the rows on screen were laid out with.
    @Test func resultsAfterAHeightChangeShowTheNewHeight() throws {
        let store = TunableStore.shared
        let header = MetricTunables.sidebarHeaderHeight.descriptor
        store.activate(file: nil)
        store.register([header])
        defer { _ = store.set(header.key, nil) }
        let (updated, updatedTable, updatedWindow) = try Self.host()
        defer { updatedWindow.closeAfterTest() }
        updated.setSections(Self.sections("a", [3, 4]))
        Self.settle(updated)
        let before = updatedTable.rect(ofRow: 0).height
        try #require(store.set(header.key, .number(Double(MetricTunables.sidebarHeaderHeight.value) + 10)) != nil)
        try #require(PaletteLayout.headerRowHeight != before, "the header height did not change")

        updated.setSections(Self.sections("b", [3, 4]))
        Self.settle(updated)
        let (fresh, freshTable, freshWindow) = try Self.host()
        defer { freshWindow.closeAfterTest() }
        fresh.setSections(Self.sections("b", [3, 4]))
        Self.settle(fresh)
        #expect(updatedTable.rect(ofRow: 0).height == PaletteLayout.headerRowHeight, "a kept header keeps its old height")
        #expect(Self.shown(updatedTable) == Self.shown(freshTable), "the updated list shows other rows")
    }
}
