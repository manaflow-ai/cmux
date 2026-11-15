import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-11-09 (11:18 PM, the hover card of "Programming language for cross-platform cmux"): "right spacing is
/// bad for the hover card, ensure padding on all sides is even, also roundness needs to match roundness of the
/// workspace row itself". With legacy scrollers (a mouse attached, or "Show scroll bars: Always") the tab list kept a
/// scroller's width at its right even when its rows fit and nothing scrolled, so each row's fill stopped about 15 pt
/// short of the card's right edge while it reached within a few points of the left. The rows' fill used the item
/// radius, not the sidebar row's.
///
/// The contract, at every density: a tab row's fill is as far from the card's right edge as from its left, its corners
/// are the sidebar workspace row's, and the card's corners are concentric around it (the row's radius plus that gap).
@MainActor @Suite(.serialized, .closesItsWindows) struct WorkspaceHoverCardEvenInsetTests {
    static func mount(scrollers: NSScroller.Style) -> (NSWindow, WorkspaceHoverCardView) {
        _ = NSApplication.shared
        let card = WorkspaceHoverCardView()
        card.configure(WorkspaceHoverCardFixture.content, now: WorkspaceHoverCardFixture.now)
        // Three tabs: the list fits, nothing scrolls.
        card.configureTabs(title: WorkspaceHoverCardFixture.title, tabs: Array(WorkspaceHoverCardFixture.tabs.prefix(3)),
                           now: WorkspaceHoverCardFixture.now)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 700))
        window.contentView?.addSubview(card)
        card.tabList.listScrollView.scrollerStyle = scrollers
        card.frame = NSRect(origin: NSPoint(x: 20, y: 20), size: card.fittingSize)
        card.layoutSubtreeIfNeeded()
        card.tabList.needsLayout = true
        card.tabList.layoutSubtreeIfNeeded()
        card.applyColors()
        return (window, card)
    }

    /// Each shown tab row's fill in the card's coordinates.
    static func rowFills(_ card: WorkspaceHoverCardView) -> [CGRect] {
        card.tabList.rowViews.filter { !$0.isHiddenOrHasHiddenAncestor && $0.frame.width > 0 }
            .map { card.convert($0.bounds, from: $0) }
    }

    @Test(arguments: SidebarDensity.allCases, [NSScroller.Style.legacy, .overlay])
    func aTabRowsFillIsAsFarFromTheRightAsFromTheLeft(_ density: SidebarDensity, _ scrollers: NSScroller.Style) throws {
        try SidebarGroupRailAlignmentTests.with(density, .off) {
            let (window, card) = Self.mount(scrollers: scrollers)
            defer { window.closeAfterTest() }
            let fills = Self.rowFills(card)
            try #require(fills.count == 3, "\(density): the card shows \(fills.count) tab rows")
            for fill in fills {
                let left = fill.minX, right = card.bounds.width - fill.maxX
                #expect(abs(left - right) <= 0.5, "\(density), \(scrollers == .legacy ? "legacy" : "overlay") scrollers: a row's fill is \(left) pt from the card's left, \(right) pt from its right")
            }
        }
    }

    @Test(arguments: SidebarDensity.allCases)
    func theRowsAndTheCardShareTheSidebarRowsRoundness(_ density: SidebarDensity) throws {
        try SidebarGroupRailAlignmentTests.with(density, .off) {
            let (window, card) = Self.mount(scrollers: .overlay)
            defer { window.closeAfterTest() }
            let row = try #require(card.tabList.rowViews.first)
            let radius = SidebarDensityTokens.rowCornerRadius
            #expect(abs((row.layer?.cornerRadius ?? 0) - radius) <= 0.01,
                    "\(density): a tab row's corners are \(row.layer?.cornerRadius ?? 0) pt, a sidebar row's \(radius) pt")
            let gap = try #require(Self.rowFills(card).first).minX
            #expect(abs((card.layer?.cornerRadius ?? 0) - (radius + gap)) <= 0.01,
                    "\(density): the card's corners are \(card.layer?.cornerRadius ?? 0) pt, concentric is \(radius + gap) pt")
        }
    }
}
