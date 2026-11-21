import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-11-15: "there's some crazy sort of layout shift on teh sidebar when i move my mouse over to
/// another display/desktop maybe? like the shared keyboard/mouse thing between air blue and cosmic
/// gray". Universal Control's shared mouse flips the system's scroller style; AppKit reset the
/// sidebar's scroll view to legacy, the list narrowed by the scroller's width and every row pill
/// (Leads, the selected session, Agents) shrank and grew back on each flip. The rows now keep one
/// width whatever AppKit sets (`OverlayScrollView`).
@MainActor @Suite(.serialized) struct SidebarScrollerStyleFlipKeepsRowWidthTests {
    private static let row = WorkspaceID("ws-0")

    private static func sidebar() -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        // More rows than fit, so a legacy scroller would show and take width.
        let rows = (0..<60).map { SidebarWorkspace(id: WorkspaceID("ws-\($0)"), title: "workspace \($0)") }
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: rows.map { .workspace($0) })])
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 400)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.fitToClip()
        return sidebar
    }

    private static func rowFrame(_ sidebar: SidebarView) throws -> NSRect {
        let row = try #require(sidebar.list.displayed.row(for: .workspace(row)))
        return sidebar.list.frame(for: row)
    }

    @Test func aScrollerStyleFlipKeepsTheRowsAtOneWidth() throws {
        let sidebar = Self.sidebar()
        let before = try Self.rowFrame(sidebar)
        let clipBefore = sidebar.scrollView.contentView.frame.width
        for style in [NSScroller.Style.legacy, .overlay, .legacy] {
            // What AppKit does to the scroll view on NSScroller.preferredScrollerStyleDidChangeNotification.
            sidebar.scrollView.scrollerStyle = style
            sidebar.scrollView.tile()
            sidebar.list.fitToClip()
            let after = try Self.rowFrame(sidebar)
            #expect(sidebar.scrollView.scrollerStyle == .overlay)
            #expect(sidebar.scrollView.contentView.frame.width == clipBefore, "the list's clip changed width (\(style))")
            #expect(after.minX == before.minX && after.width == before.width,
                    "a row changed width on a flip to \(style): \(before) vs \(after)")
        }
    }

    /// The bands above and below the list scroll too: their clips keep one width as well.
    @Test func theBandsKeepTheirWidthOnAFlip() {
        let sidebar = Self.sidebar()
        for scroll in [sidebar.aboveScroll, sidebar.belowScroll] {
            let before = scroll.contentView.frame.width
            scroll.scrollerStyle = .legacy
            scroll.tile()
            #expect(scroll.scrollerStyle == .overlay)
            #expect(scroll.contentView.frame.width == before)
        }
    }
}
