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

    /// The edge matrix deliberately crosses the app appearance density with the sidebar's own
    /// density. Search's side follows appearance tokens while row heights/insets follow the
    /// sidebar density, so either axis alone can miss a clipping or alignment regression.
    nonisolated enum EdgeWidth: String, CaseIterable, Sendable { case minimum, `default`, wide }

    nonisolated struct EdgeLook: CustomTestStringConvertible, Sendable {
        var appearance: DensityPreset
        var density: SidebarDensity
        var width: EdgeWidth
        var testDescription: String { "\(appearance.rawValue)/\(density.rawValue)/\(width.rawValue)" }
    }

    nonisolated static let edgeLooks: [EdgeLook] = DensityPreset.allCases.flatMap { appearance in
        SidebarDensity.allCases.flatMap { density in
            EdgeWidth.allCases.map {
                EdgeLook(appearance: appearance, density: density, width: $0)
            }
        }
    }

    private static func edgeWidth(_ kind: EdgeWidth) -> CGFloat {
        switch kind {
        case .minimum: Metrics.sidebarMinWidth
        case .default: Metrics.sidebarWidth
        case .wide: Metrics.sidebarMaxWidth
        }
    }

    private static func withAppearance<T>(_ appearance: DensityPreset, _ body: () throws -> T) rethrows -> T {
        let saved = DesignSettings.shared.densityTokens
        DesignSettings.shared.densityTokens = appearance.tokens
        defer { DesignSettings.shared.densityTokens = saved }
        return try body()
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

    /// A hovered row (the default close spot, at the row's end): ✕ on the column, its menu one slot in. A hovered group header: the chevron on the column, the
    /// menu and the + one and two slots in. Every hovered control, of every row kind, centers on a slot.
    @Test(arguments: looks)
    func hoveredControlsStepOneSlotPitch(_ look: Look) throws {
        try SidebarRowCloseSpotTests.withCloseSpot(.end) { try SidebarGroupRailAlignmentTests.with(look.density, .off) {
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
            for (id, expected) in [(T.selected, ["close", "more"]), (T.nested, ["close", "more"]),
                                   (T.unread, ["close", "more"]), (T.busy, ["close", "more"])] {
                let row = try #require(h.list.rowViews[.workspace(id)] as? WorkspaceRowView)
                // The harness wires no menu; the app's rows have one, so the hovered ⋮ shows (as in the capture).
                row.onMore = {}
                row.isHovered = true
                row.layoutSubtreeIfNeeded()
                defer { row.isHovered = false; row.layoutSubtreeIfNeeded() }
                let controls: [(String, NSView)] = [("close", row.closeButton), ("more", row.moreButton)]
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
    /// Leo 2026-10-30: "this alignment is annoying too". The trailing column must also stay
    /// inside the sidebar content when it is at the minimum, default and wide widths: the resize
    /// band straddles the edge, so an accessory whose frame reaches into its inside half is clipped
    /// or crowded by the drag target. This measures the actual status, chevron, hover controls and
    /// footer Search frames rather than only checking the style math.
    @Test(arguments: edgeLooks)
    func trailingAccessoriesStayInsideContentAndShareOneColumn(_ c: EdgeLook) throws {
        try Self.withAppearance(c.appearance) {
            try SidebarGroupRailAlignmentTests.with(c.density, .off) {
                let width = Self.edgeWidth(c.width)
                    let h = T.KindHarness(width: width)
                    defer { h.window.close() }
                    let column = try T.columnX(h)
                    let tolerance = Self.tolerance(h)
                    var accessories: [(String, CGRect, Bool)] = []
                    let rows: [(String, NSView)] = [
                        ("status", try h.row(.workspace(T.unread))),
                        ("selected", try h.row(.workspace(T.selected))),
                        ("group", try h.row(.group(T.open))),
                        ("pinned", try h.bandRow(T.lead)),
                    ]
                    for (name, row) in rows {
                        for mark in T.marks(in: row, named: name, list: h.list) {
                            let side = SidebarStyle.trailingSlotSide
                            accessories.append((mark.what, CGRect(x: mark.midX - side / 2, y: 0, width: side, height: side), true))
                        }
                    }

                    let selected = try #require(h.list.rowViews[.workspace(T.selected)] as? WorkspaceRowView)
                    selected.onMore = {}
                    selected.isHovered = true
                    selected.layoutSubtreeIfNeeded()
                    defer { selected.isHovered = false; selected.layoutSubtreeIfNeeded() }
                    for (name, view) in [("close", selected.closeButton), ("more", selected.moreButton)]
                        where !view.isHidden && T.drawnAlpha(view, below: h.list) > 0.01 {
                        // Hover controls occupy the shared slot grid: close is slot 0, while
                        // the menu intentionally steps left by one pitch.
                        accessories.append((name, h.list.convert(view.frame, from: selected), name == "close"))
                    }

                    // Exercise the idle hovered row as well: it has no status mark to hide,
                    // which is the path that previously retained the old horizontal inset.
                    let idle = try #require(h.list.rowViews[.workspace(T.idle)] as? WorkspaceRowView)
                    idle.onClose = {}
                    idle.onMore = {}
                    idle.isHovered = true
                    idle.layoutSubtreeIfNeeded()
                    defer { idle.isHovered = false; idle.layoutSubtreeIfNeeded() }
                    let idleControls: [(String, NSView)] = [("idle-close", idle.closeButton), ("idle-more", idle.moreButton)]
                    #expect(idleControls.contains { !$0.1.isHidden }, "\(c): idle workspace did not create hover controls")
                    for (name, view) in idleControls
                        where !view.isHidden && T.drawnAlpha(view, below: h.list) > 0.01 {
                        accessories.append((name, h.list.convert(view.frame, from: idle), name == "idle-close"))
                    }

                    // Pinned rows use the same shared slot helper but live in the top block's
                    // region, so include their hover controls in the edge matrix.
                    let pinned = try h.bandRow(T.lead)
                    pinned.onMore = {}
                    PointerHover.setDebugPointer(pinned.convert(NSPoint(x: pinned.bounds.midX, y: pinned.bounds.midY), to: nil), in: h.window)
                    #expect(pinned.isHovered, "\(c): debug pointer did not hover the pinned workspace")
                    pinned.layoutSubtreeIfNeeded()
                    defer { PointerHover.setDebugPointer(nil, in: h.window); pinned.layoutSubtreeIfNeeded() }
                    // A pinned row has no hover close (Lawrence msg 19392): its more button takes the column.
                    let pinnedControls: [(String, NSView?)] = [("pinned-more", pinned.hoverMore)]
                    #expect(pinnedControls.contains { $0.1 != nil }, "\(c): pinned workspace did not create hover controls")
                    for (name, view) in pinnedControls.compactMap({ name, view in
                        view.map { (name, $0 as NSView) }
                    }) where !view.isHidden && T.drawnAlpha(view, below: h.list) > 0.01 {
                        accessories.append((name, h.list.convert(view.frame, from: pinned), name == "pinned-more"))
                    }

                    // A hovered group header exposes its disclosure, menu and add controls on
                    // slots 0, 1 and 2 respectively. Only the disclosure is part of the shared
                    // column; the other controls remain on the slot grid to its left.
                    let header = try #require(h.list.rowViews[.group(T.open)] as? GroupHeaderRowView)
                    header.onAdd = {}
                    header.isHovered = true
                    header.layoutSubtreeIfNeeded()
                    defer { header.isHovered = false; header.layoutSubtreeIfNeeded() }
                    if let disclosure = header.debugDisclosure, disclosure.shown {
                        accessories.append(("header-chevron", h.list.convert(disclosure.frame, from: header), true))
                    }
                    let headerControls: [(String, NSView)] = [("header-more", header.moreButton), ("header-add", header.addButton)]
                    for (name, view) in headerControls
                        where !view.isHidden && T.drawnAlpha(view, below: h.list) > 0.01 {
                        accessories.append((name, h.list.convert(view.frame, from: header), false))
                    }

                    // The machine/section header has its own trailing + action. It must use
                    // the same column even though it is not a group header.
                    for sectionHeader in h.list.rowViews.values.compactMap({ $0 as? SectionHeaderRowView }) {
                        sectionHeader.layoutSubtreeIfNeeded()
                        #expect(!sectionHeader.addButton.isHidden, "\(c): section header + is missing")
                        accessories.append(("section-add", h.list.convert(sectionHeader.addButton.frame, from: sectionHeader), true))
                    }

                    #expect(!h.sidebar.searchButton.isHidden, "\(c): Search is hidden")
                    accessories.append(("search", h.sidebar.convert(h.sidebar.searchButton.frame, from: h.sidebar), true))

                    let band = SidebarResizeBand(width: max(Metrics.dividerHitWidth, SidebarResizeBand.minimumWidth),
                                                 gutter: Metrics.mainPaneGutter)
                    #expect(band.inside <= SidebarResizeBand.contentInset + tolerance,
                            "\(c) resize band takes \(band.inside) pt of the content")
                    let contentEdge = width - band.inside
                    for (name, frame, sharesColumn) in accessories {
                        if sharesColumn {
                            #expect(abs(frame.midX - column) <= tolerance,
                                    "\(c) \(name) centers at \(frame.midX), column \(column)")
                        }
                        #expect(frame.maxX <= contentEdge + tolerance,
                                "\(c) \(name) reaches \(frame.maxX), inside content edge \(contentEdge), band \(band)")
                    }
                    print("TRAILSLOT|edge|\(c)|column \(column)|content \(contentEdge)|band \(band)|\(accessories.map { "\($0.0)@\($0.1.midX)" }.joined(separator: " "))")
            }
        }
    }
}
