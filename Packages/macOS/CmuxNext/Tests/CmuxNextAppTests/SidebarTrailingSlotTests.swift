import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-29, on the sidebar's right edge (a hovered row's ⋮ ⌄ ✕ over rows with a red ⓘ and blue unread dots): "I SAID
/// THE SHIT WAS MISALIGNED LAST FUCCKING NIGHT". Every trailing mark sits on one column and every trailing control on one
/// slot grid: slot 0 is the column (the dot, the status, a hovered row's ✕, a header's chevron), and each slot left of it
/// steps one `trailingSlotPitch`. A hovered row stepped 22 pt to its chevron and 20 pt to its menu; a row badge floored
/// its x to whole points, so at a fractional sidebar width its dot sat up to a point left of the ✕ above it. The widths
/// here are fractional on purpose: a sidebar is dragged to any width. Each case prints a `TRAILSLOT|` line.
@MainActor @Suite(.serialized) struct SidebarTrailingSlotTests {
    typealias T = SidebarTrailingColumnTests

    nonisolated struct Look: CustomTestStringConvertible, Sendable {
        var density: SidebarDensity
        var width: CGFloat
        var testDescription: String { "\(density.rawValue)/\(width)pt" }
    }

    nonisolated static let looks: [Look] = SidebarDensity.allCases.flatMap { density in
        [CGFloat(220.5), 247.25, 263.75, 301.5].map { Look(density: density, width: $0) }
    }

    /// Half a backing pixel: a mark placed on the nearest pixel is never further than this from the column.
    static func tolerance(_ h: T.KindHarness) -> CGFloat { 0.5 / (h.window.backingScaleFactor > 0 ? h.window.backingScaleFactor : 2) + 0.01 }

    @Test(arguments: looks)
    func everyMarkSitsOnTheColumnWithinHalfAPixel(_ look: Look) throws {
        try SidebarGroupRailAlignmentTests.with(look.density, .off) {
            let h = T.KindHarness(width: look.width)
            defer { h.window.close() }
            let column = try T.columnX(h), tolerance = Self.tolerance(h)
            let rows: [(String, NSView)] = [
                ("unread", try h.row(.workspace(T.unread))), ("member", try h.row(.workspace(T.member))),
                ("nested", try h.row(.workspace(T.nested))), ("busy", try h.row(.workspace(T.busy))),
                ("waiting", try h.row(.workspace(T.waiting))), ("selected", try h.row(.workspace(T.selected))),
                ("home", try h.bandRow(T.home)), ("bandSelected", try h.bandRow(T.lead)),
                ("tabUnread", try h.row(.tab(T.selected, T.tabUnread))), ("tabWorking", try h.row(.tab(T.selected, T.tabWorking))),
                ("foldedHeader", try h.row(.group(T.folded))),
            ]
            var marks: [T.Mark] = []
            for (name, row) in rows { marks += T.marks(in: row, named: name, list: h.list) }
            print("TRAILSLOT|marks|\(look.testDescription)|column \(column)|\(marks.map(\.description).joined(separator: " "))")
            #expect(marks.count >= rows.count, "\(look.testDescription): a row shows no trailing mark: \(marks)")
            for mark in marks {
                #expect(abs(mark.midX - column) <= tolerance,
                        "\(look.testDescription): \(mark.what) centers at \(mark.midX), \(mark.midX - column) pt off the column \(column)")
            }
        }
    }

    /// A hovered row (the default close spot, at the row's end): ✕ on the column, its chevron one slot in, its menu two
    /// slots in; a row with no chevron puts its menu one slot in. A hovered group header: the chevron on the column, the
    /// menu and the + one and two slots in. Every hovered control, of every row kind, centers on a slot.
    @Test(arguments: looks)
    func hoveredControlsStepOneSlotPitch(_ look: Look) throws {
        try SidebarTabGroupControlsTests.withCloseSpot(.end) { try SidebarGroupRailAlignmentTests.with(look.density, .off) {
            let h = T.KindHarness(width: look.width)
            defer { h.window.close() }
            let column = try T.columnX(h), tolerance = Self.tolerance(h), pitch = SidebarStyle.trailingSlotPitch
            @MainActor func drawn(_ view: NSView) -> Bool { !view.isHidden && T.drawnAlpha(view, below: h.list) > 0.01 }
            var report: [String] = []
            func expectSlots(_ label: String, _ centers: [(String, CGFloat)], _ expected: [String]) {
                let ordered = centers.sorted { $0.1 > $1.1 }
                report.append("\(label) " + ordered.map { "\($0.0)@\($0.1)" }.joined(separator: ","))
                #expect(ordered.map(\.0) == expected, "\(look.testDescription) \(label): controls right to left \(ordered.map(\.0)), want \(expected)")
                for (slot, (what, x)) in ordered.enumerated() {
                    let want = column - CGFloat(slot) * pitch
                    #expect(abs(x - want) <= tolerance, "\(look.testDescription) \(label): \(what) at \(x), slot \(slot) at \(want) (pitch \(pitch))")
                }
            }
            for (id, expected) in [(T.selected, ["close", "disclosure", "more"]), (T.nested, ["close", "disclosure", "more"]),
                                   (T.unread, ["close", "more"]), (T.busy, ["close", "more"])] {
                let row = try #require(h.list.rowViews[.workspace(id)] as? WorkspaceRowView)
                // The harness wires no menu; the app's rows have one, so the hovered ⋮ shows (as in the capture).
                row.onMore = {}
                row.isHovered = true
                row.layoutSubtreeIfNeeded()
                defer { row.isHovered = false; row.layoutSubtreeIfNeeded() }
                let controls: [(String, NSView)] = [("close", row.closeButton), ("disclosure", row.disclosureButton), ("more", row.moreButton)]
                expectSlots(id.rawValue, controls.filter { drawn($0.1) }.map { ($0.0, h.list.convert($0.1.frame, from: row).midX) }, expected)
            }
            for id in [T.open, T.sub] {
                let header = try #require(h.list.rowViews[.group(id)] as? GroupHeaderRowView)
                // The harness wires no +; the app's headers offer one, so the + takes slot 2 (and the overlap check runs).
                header.onAdd = {}
                header.isHovered = true
                header.layoutSubtreeIfNeeded()
                defer { header.isHovered = false; header.layoutSubtreeIfNeeded() }
                var centers: [(String, CGFloat)] = []
                if let chevron = header.debugDisclosure, chevron.shown { centers.append(("chevron", h.list.convert(chevron.frame, from: header).midX)) }
                for (what, view) in [("more", header.moreButton), ("add", header.addButton)] as [(String, NSView)] where drawn(view) {
                    centers.append((what, h.list.convert(view.frame, from: header).midX))
                }
                expectSlots(id.rawValue, centers, header.onAdd == nil ? ["chevron", "more"] : ["chevron", "more", "add"])
                // Neighbors never overlap: a click on the menu's visible area never lands on the +.
                let shown = ([header.moreButton, header.addButton] as [NSView]).filter(drawn).map(\.frame)
                if let chevron = header.debugDisclosure, chevron.shown, let more = shown.first {
                    #expect(more.maxX <= chevron.frame.minX + 0.01, "\(look.testDescription) \(id.rawValue): the menu overlaps the chevron")
                }
                if shown.count == 2 {
                    #expect(shown[1].maxX <= shown[0].minX + 0.01, "\(look.testDescription) \(id.rawValue): the + overlaps the menu")
                }
            }
            print("TRAILSLOT|hover|\(look.testDescription)|column \(column) pitch \(pitch)|\(report.joined(separator: "; "))")
        } }
    }

    /// A listed tab with a status and an unread dot: the status on the column, the dot one slot in (the line a hovered
    /// row's chevron takes), never an ad hoc gap beside it.
    @Test(arguments: looks)
    func aTabDotBesideItsStatusTakesTheNextSlot(_ look: Look) throws {
        try SidebarGroupRailAlignmentTests.with(look.density, .off) {
            let h = T.KindHarness(width: look.width)
            defer { h.window.close() }
            let row = try #require(h.list.rowViews[.tab(T.selected, T.tabWorking)] as? SidebarTabRowView)
            row.unreadDot.configure(.dot)
            row.needsLayout = true
            row.layoutSubtreeIfNeeded()
            let column = try T.columnX(h), tolerance = Self.tolerance(h)
            let dot = h.list.convert(row.unreadDot.frame, from: row).midX
            let want = column - SidebarStyle.trailingSlotPitch
            print("TRAILSLOT|tab|\(look.testDescription)|column \(column)|dot \(dot) want \(want)")
            #expect(abs(dot - want) <= tolerance, "\(look.testDescription): the tab's dot at \(dot), slot 1 at \(want)")
        }
    }
}
