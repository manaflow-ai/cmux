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
            // Each edge lands on a whole device pixel: on a 1x screen (a fleet display worker) a fractional density's
            // two edges can each round a point the other way.
            let allowed = window.backingScaleFactor >= 2 ? 0.5 : 2 / max(window.backingScaleFactor, 1) + 0.01
            for fill in fills {
                let left = fill.minX, right = card.bounds.width - fill.maxX
                #expect(abs(left - right) <= allowed, "\(density), \(scrollers == .legacy ? "legacy" : "overlay") scrollers: a row's fill is \(left) pt from the card's left, \(right) pt from its right")
            }
        }
    }

    /// Lawrence 2026-11-16, on a card of one tab ("manaflow-ai/trellis: Trellis: a programming l…") over Show details:
    /// "bottom padding must be same as left/right, same for top". The fills reached `fillOutset` past the card's
    /// content at the sides only, so the hovered Show details stood further from the card's bottom than from its sides,
    /// and the first tab row (the name hidden: the one tab says it) further from the top. Every fill that meets a
    /// card edge stands the same gap from it as from the sides, the gap the card's corners are concentric around.
    @Test(arguments: SidebarDensity.allCases)
    func aFillAtTheTopOrBottomIsAsFarFromThatEdgeAsFromTheSides(_ density: SidebarDensity) throws {
        try SidebarGroupRailAlignmentTests.with(density, .off) {
            _ = NSApplication.shared
            let title = "manaflow-ai/trellis: Trellis: a programming language"
            let card = WorkspaceHoverCardView()
            card.configure(WorkspaceHoverCardContent(title: title, icon: .terminal, age: "3m",
                                                     facts: [.init(icon: .folder, text: "~/fun/trellis", kind: "folder")]),
                           now: WorkspaceHoverCardFixture.now)
            card.configureTabs(title: title, tabs: [SidebarTab(id: TabID("gh"), title: title, kind: .browser, host: "github.com")],
                               now: WorkspaceHoverCardFixture.now)
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 400), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.closeAfterTest() }
            window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
            window.contentView?.addSubview(card)
            card.frame = NSRect(origin: NSPoint(x: 20, y: 20), size: card.fittingSize)
            card.layoutSubtreeIfNeeded()
            card.tabList.layoutSubtreeIfNeeded()
            card.detailsToggle.layoutSubtreeIfNeeded()
            try #require(!card.detailsToggle.isHiddenOrHasHiddenAncestor, "\(density): no Show details")
            let row = try #require(Self.rowFills(card).first, "\(density): no tab row")
            // The side gap the card's corners are concentric around. Frames land on whole device pixels: a 1x screen
            // (a fleet display worker) rounds a fractional density's edges by up to a point.
            let gap = WorkspaceHoverCardView.tokens.padding - WorkspaceTabHoverCardRow.fillOutset
            let pixel = 1 / max(window.backingScaleFactor, 1) + 0.01
            #expect(abs(row.minX - gap) <= pixel, "\(density): the tab row's fill is \(row.minX) pt from the card's left, not \(gap) pt")
            // The card is not flipped: its top is maxY.
            #expect(abs((card.bounds.height - row.maxY) - gap) <= pixel,
                    "\(density): the first tab row's fill is \(card.bounds.height - row.maxY) pt from the card's top, not \(gap) pt")
            let toggle = card.detailsToggle
            let fill = card.convert(toggle.fillLayer.frame, from: toggle)
            #expect(abs(fill.minX - gap) <= pixel, "\(density): Show details' fill is \(fill.minX) pt from the card's left, not \(gap) pt")
            #expect(abs(fill.minY - gap) <= pixel,
                    "\(density): Show details' fill is \(fill.minY) pt from the card's bottom, not \(gap) pt")
            #expect(abs(card.layer.map(\.cornerRadius).map { $0 - SidebarDensityTokens.rowCornerRadius - gap } ?? 1) <= 0.01,
                    "\(density): the card's corners are not concentric around a \(gap) pt gap")
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
            // The row's edge lands on a whole device pixel; the corner is exact (one pixel on a 1x screen).
            let pixel = window.backingScaleFactor >= 2 ? 0.01 : 1 / max(window.backingScaleFactor, 1) + 0.01
            #expect(abs((card.layer?.cornerRadius ?? 0) - (radius + gap)) <= pixel,
                    "\(density): the card's corners are \(card.layer?.cornerRadius ?? 0) pt, concentric is \(radius + gap) pt")
        }
    }
}
