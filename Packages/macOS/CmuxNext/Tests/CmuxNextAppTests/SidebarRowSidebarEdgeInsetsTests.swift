import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-11-10 (msg 26565, the selected Home row over pinned rows with spinners): "left/right padding around
/// workspace is not good". Measured in the whole sidebar, not in one row: a row's highlight sits as far from the
/// sidebar's left edge as from its right, and inside the highlight the first glyph (a pin, or a text-only title)
/// starts as far from the highlight's left as the status mark ends from its right, at every density.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarRowSidebarEdgeInsetsTests {
    static let pin = LayoutItemID("itm_edge_pin")
    static let busy = WorkspaceID("ws-edge-busy")
    static let tolerance: CGFloat = 0.5

    /// A sidebar with one pinned row (its pin leads) and a workspace row with a status mark on the trailing column.
    static func sidebar() -> (SidebarView, NSWindow) {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [
            SidebarUniformRowSpacingTests.pinnedBlock(),
            CmuxNextSidebar.SidebarSection(kind: .machine(machine), nodes: [
                .workspace(SidebarWorkspace(id: busy, title: "subrouter 2", activity: .success)),
            ]),
        ], activeWorkspaceID: nil)
        model.layout = SidebarLayoutDocument(sections: [
            LayoutSection(id: SidebarLayoutDocument.pinnedSectionID, showsTitle: false, region: .top, look: .builtIn,
                          items: [LayoutItem(id: pin, ref: .workspace("pinned-missing"))]),
        ])
        model.docDrag = SidebarDocDrag(item: { _ in nil }, section: { _ in nil }, begin: { _ in [:] }, drop: { _, _ in },
                                       adoptRef: { _ in nil })
        let sidebar = SidebarView(model: model, design: DesignSettings.shared)
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 420)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 420), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(sidebar)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.fitToClip()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return (sidebar, window)
    }

    static func inSidebar(_ rect: CGRect, from view: NSView, _ sidebar: SidebarView) -> CGRect { sidebar.convert(rect, from: view) }

    @Test(arguments: SidebarDensity.allCases)
    func everyRowsHighlightAndContentAreEvenLeftAndRight(_ density: SidebarDensity) throws {
        let (saved, savedMotion) = (DesignSettings.shared.sidebarSections.density, Motion.reduceMotionOverride)
        (DesignSettings.shared.sidebarSections.density, Motion.reduceMotionOverride) = (density, true)
        defer { (DesignSettings.shared.sidebarSections.density, Motion.reduceMotionOverride) = (saved, savedMotion) }
        let (sidebar, window) = Self.sidebar()
        defer { window.close() }
        let width = sidebar.bounds.width

        let block = try #require(sidebar.list.rowViews[SidebarUniformRowSpacingTests.pinnedKey] as? SidebarBlockRowView, "no Pinned block")
        let pinned = try #require(block.region.itemViews[Self.pin], "no pinned row")
        pinned.layoutSubtreeIfNeeded()
        let pinnedFill = Self.inSidebar(pinned.pill.frame, from: pinned, sidebar)
        let pinInk = Self.inSidebar(try #require(pinned.pinInkFrame, "the pinned row draws no pin"), from: pinned, sidebar)

        let row = try #require(sidebar.list.rowViews[.workspace(Self.busy)] as? WorkspaceRowView, "no workspace row")
        row.layoutSubtreeIfNeeded()
        let rowFill = Self.inSidebar(row.bounds, from: row, sidebar)
        let title = row.title.alignmentRect(forFrame: row.title.frame)
        let titleX = Self.inSidebar(title, from: row, sidebar).minX
        // Every status mark centers on the trailing column (a spinner in a status-glyph box, the other marks larger in
        // the same badge cell), so the column's center is what mirrors the leading inset: a status-glyph box on it ends
        // the content inset before the fill's end.
        let shown = [row.rowBadge as NSView, row.activity].first { !$0.isHidden && $0.frame.width > 0 }
        let markView = try #require(shown, "\(density): the row shows no status mark")
        let mark = Self.inSidebar(markView.frame, from: row, sidebar)

        for (name, fill) in [("the pinned row", pinnedFill), ("the workspace row", rowFill)] {
            let left = fill.minX, right = width - fill.maxX
            #expect(abs(left - right) <= Self.tolerance,
                    "\(density): \(name)'s highlight is \(left) pt from the sidebar's left edge, \(right) pt from its right")
        }
        let trailing = rowFill.maxX - mark.midX - SidebarStyle.statusGlyphSize / 2
        for (name, leading) in [("the pin", pinInk.minX - pinnedFill.minX), ("a text-only title", titleX - rowFill.minX)] {
            #expect(abs(leading - trailing) <= Self.tolerance,
                    "\(density): \(name) starts \(leading) pt inside its highlight, a status-glyph box on the trailing column ends \(trailing) pt before the highlight's end")
        }
    }
}
