import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextFocusUI
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-10-29 (screenshot, NIGHTLY 6c1a5ab): "alignmnet here is generally pretty bad". Holding Cmd drew
/// Home's and the pinned rows' chips (⌘1…⌘5) at another right edge than the workspace rows' chips (⌘6…⌘8): a band
/// or block row's view runs `horizontalInset` past its drawn pill on each side, and the chip right-aligned to the
/// view, not to the pill. In the titlebar the ⌘B ⌘[ ⌘] chips sat 4 pt from the traffic lights and 4 pt apart, so
/// their glass edges ran together and crowded the lights.
///
/// Every sidebar chip now ends on the rows' one trailing content edge (the trailing mark column's right edge: since
/// #27598 the control slot around the grid's trailing line, `LayoutGrid.sidebarTrailCenter` from the sidebar's right
/// edge) and centers on its row; titlebar chips keep the traffic lights' own gap
/// between each other, twice that after the lights, and center on the lights' line.
@MainActor @Suite(.closesItsWindows, .serialized)
struct ShortcutHintChipAlignmentTests {
    static let home = LayoutItemID("itm_chip_home")
    static let pinned = [LayoutItemID("itm_chip_p1"), LayoutItemID("itm_chip_p2")]
    static let rows = (1...3).map { WorkspaceID("ws-chip-\($0)") }
    /// Frames snap to backing pixels at 2x.
    static let tolerance: CGFloat = 0.5

    /// Places chips without motion, so a test reads their final frames at once.
    private struct InstantFader: ShortcutHintChipFading {
        func fadeIn(_ chips: [NSView], in overlay: NSView) { chips.forEach { $0.alphaValue = 1 } }
        func fadeOut(_ chips: [NSView], in overlay: NSView, completion: @escaping @MainActor @Sendable () -> Void) { completion() }
    }

    /// The sidebar with Home and two pinned workspaces above three workspace rows, Pinned drawn in the band above
    /// the list (`document` false) or as a block of the list (the sidebar document).
    final class Harness {
        let model: SidebarModel
        let sidebar: SidebarView
        let window: NSWindow
        var list: SidebarListView { sidebar.list }

        init(document: Bool, width: CGFloat) {
            let items = [LayoutItem(id: ShortcutHintChipAlignmentTests.home, ref: SidebarLayoutDocument.homeRef)]
                + ShortcutHintChipAlignmentTests.pinned.map { LayoutItem(id: $0, ref: .workspace("s:\($0.rawValue)")) }
            let section = LayoutSection(id: SidebarLayoutDocument.pinnedSectionID, region: .top, look: .builtIn, arrangement: .list, items: items)
            let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
            let listed = CmuxNextSidebar.SidebarSection(kind: .machine(machine), nodes: ShortcutHintChipAlignmentTests.rows.map {
                SidebarNode.workspace(SidebarWorkspace(id: $0, title: "workspace \($0.rawValue)"))
            })
            if document {
                let block = CmuxNextSidebar.SidebarSection(kind: .custom(SidebarCustomSection(id: SidebarLayoutDocument.pinnedSectionID.rawValue)), nodes: [])
                model = SidebarModel(sections: [block, listed])
                model.docDrag = SidebarDocDrag(item: { _ in nil }, section: { _ in nil }, begin: { _ in [:] }, drop: { _, _ in }, adoptRef: { _ in nil })
            } else {
                model = SidebarModel(sections: [listed])
            }
            model.layout = SidebarLayoutDocument(sections: [section])
            for (index, item) in ShortcutHintChipAlignmentTests.pinned.enumerated() {
                var info = SidebarItemInfo(title: "pinned \(index + 1)", symbol: "textformat")
                info.textOnly = true
                info.leadingPin = true
                info.workspace = WorkspaceID("ws-pin-\(index + 1)")
                model.itemInfo[item] = info
            }
            sidebar = SidebarView(model: model, design: DesignSettings.shared)
            sidebar.frame = NSRect(x: 0, y: 0, width: width, height: 480)
            window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(sidebar)
            window.orderFrontRegardless()
            sidebar.renderNow()
            settle()
            if document { list.reload(animated: false); settle() }
        }

        func settle() {
            sidebar.renderNow()
            sidebar.layoutSubtreeIfNeeded()
            list.fitToClip()
            sidebar.layoutSubtreeIfNeeded()
            list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
            for region in [sidebar.aboveRegion] + list.blockRegions {
                region.itemViews.values.forEach { $0.layoutSubtreeIfNeeded(); $0.layout() }
            }
        }

        /// The fill each destination draws, in sidebar coordinates: a list row is its fill; a band or block row
        /// draws its pill inset in its view.
        func drawnFill(_ item: SidebarItem) -> CGRect? {
            switch item {
            case let .workspace(id):
                guard let row = list.rowViews[.workspace(id)] else { return nil }
                return sidebar.convert(row.bounds, from: row)
            case let .topItem(id):
                guard let view = ([sidebar.aboveRegion] + list.blockRegions).lazy.compactMap({ $0.itemViews[id] }).first else { return nil }
                return sidebar.convert(view.pill.frame, from: view)
            case .group:
                return nil
            }
        }

        /// The chips a Cmd hold draws over the sidebar, keyed by the destination each one selects.
        func chips() -> [SidebarItem: CGRect] {
            let overlay = ShortcutHintOverlayView(fader: InstantFader())
            overlay.frame = sidebar.frame
            window.contentView?.addSubview(overlay)
            defer { overlay.removeFromSuperview() }
            let frames = sidebar.shortcutHintItemFrames.sorted { $0.value.minY < $1.value.minY }
            overlay.hints = frames.enumerated().map { index, entry in
                .init(text: "⌘\(index + 1)", rect: overlay.convert(entry.value, from: sidebar), trailingInset: 0)
            }
            var result: [SidebarItem: CGRect] = [:]
            for (index, entry) in frames.enumerated() {
                guard let chip = overlay.subviews.compactMap({ $0 as? ShortcutHintChipView }).first(where: { $0.text == "⌘\(index + 1)" }) else { continue }
                result[entry.key] = sidebar.convert(chip.frame, from: overlay)
            }
            return result
        }
    }

    nonisolated struct Case: CustomTestStringConvertible, Sendable {
        var document: Bool
        var density: SidebarDensity
        var width: CGFloat
        var testDescription: String { "\(document ? "document" : "band")/\(density.rawValue)/\(Int(width))pt" }
    }

    nonisolated static let cases: [Case] = [false, true].flatMap { document in
        SidebarDensity.allCases.flatMap { density in [200, 260].map { Case(document: document, density: density, width: $0) } }
    }

    /// Home's, the pinned rows' and the workspace rows' chips end on one x: the rows' trailing content edge.
    @Test(arguments: cases)
    func everySidebarChipEndsOnTheRowsTrailingContentEdge(_ c: Case) throws {
        try SidebarGroupRailAlignmentTests.with(c.density, .off) {
            let harness = Harness(document: c.document, width: c.width)
            defer { harness.window.close() }
            let chips = harness.chips()
            let items: [SidebarItem] = [.topItem(Self.home)] + Self.pinned.map(SidebarItem.topItem) + Self.rows.map(SidebarItem.workspace)
            for item in items {
                let fill = try #require(harness.drawnFill(item), "\(c.testDescription): \(item) draws no fill")
                let chip = try #require(chips[item], "\(c.testDescription): \(item) has no chip; chips \(chips.keys)")
                // The trailing column sits on the grid's line, 24 pt from the sidebar's right edge (#27598), and its
                // control slot (the hover close's, `trailingSlotSide`) ends half a slot past it.
                let column = fill.minX + SidebarStyle.trailingColumnCenterX(rowWidth: fill.width)
                #expect(abs(harness.sidebar.bounds.maxX - column - LayoutGrid.sidebarTrailCenter) <= Self.tolerance,
                        "\(c.testDescription): \(item)'s trailing column is \(harness.sidebar.bounds.maxX - column) pt from the sidebar's edge")
                let edge = column + SidebarStyle.trailingSlotSide / 2
                #expect(abs(chip.maxX - edge) <= Self.tolerance,
                        "\(c.testDescription): \(item)'s chip ends at \(chip.maxX), the rows' trailing content edge is \(edge) (fill \(fill))")
                #expect(abs(chip.midY - fill.midY) <= Self.tolerance,
                        "\(c.testDescription): \(item)'s chip centers at y \(chip.midY), its row at \(fill.midY)")
            }
            let edges = items.compactMap { chips[$0]?.maxX }
            #expect((edges.max() ?? 0) - (edges.min() ?? 0) <= Self.tolerance, "\(c.testDescription): chip right edges differ: \(edges)")
        }
    }

    /// The ⌘B ⌘[ ⌘] chips keep the traffic lights' own gap between each other, twice it after the lights, never
    /// overlap, and center on the lights' line.
    @Test func titlebarChipsClearTheTrafficLightsAndEachOther() throws {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 800, height: 500),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.orderFrontRegardless()
        defer { window.close() }
        let root = try #require(window.contentView)
        let overlay = ShortcutHintOverlayView(fader: InstantFader())
        overlay.frame = root.bounds
        root.addSubview(overlay)
        let lights = overlay.convert(try #require(WindowTitlebar.trafficLightsFrame(in: window), "no traffic lights"), from: nil)
        let close = try #require(window.standardWindowButton(.closeButton)), mini = try #require(window.standardWindowButton(.miniaturizeButton))
        let lightsGap = mini.convert(mini.bounds, to: nil).minX - close.convert(close.bounds, to: nil).maxX
        // The toolbar band's buttons as the app lays them out: 24 pt squares right after the lights.
        let side: CGFloat = 24
        let controls = (0..<3).map { CGRect(x: lights.maxX + 4 + CGFloat($0) * side, y: lights.midY - side / 2, width: side, height: side) }
        overlay.hints = zip(["⌘B", "⌘[", "⌘]"], controls).map { .init(text: $0, rect: $1, row: .titlebar) }
        let chips = overlay.subviews.compactMap { $0 as? ShortcutHintChipView }.sorted { $0.frame.minX < $1.frame.minX }.map(\.frame)
        try #require(chips.count == 3, "drew \(chips.count) titlebar chips")
        #expect(chips[0].minX - lights.maxX >= lightsGap * 2 - Self.tolerance,
                "the first chip starts \(chips[0].minX - lights.maxX) pt after the lights; their own gap is \(lightsGap) pt")
        for (left, right) in zip(chips, chips.dropFirst()) {
            #expect(right.minX - left.maxX >= lightsGap - Self.tolerance, "chips \(left) and \(right) are \(right.minX - left.maxX) pt apart; the lights' gap is \(lightsGap) pt")
        }
        for chip in chips {
            #expect(abs(chip.midY - lights.midY) <= Self.tolerance, "a chip centers at y \(chip.midY), the lights at \(lights.midY)")
            #expect(chip.height == chips[0].height, "chips differ in height: \(chips.map(\.height))")
        }
    }
}
