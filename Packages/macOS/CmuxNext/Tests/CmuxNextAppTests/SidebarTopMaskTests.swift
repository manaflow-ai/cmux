import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// With the minimal titlebar the sidebar list starts at the tab strip's height (level with the
/// panes' content), above the bottom of the traffic lights' row. Scrolled, rows slid up under the
/// lights and stayed visible there (an "Agents" group header pill on nightly 3a63d6d9). The rule
/// (claude-sr2, 2026-10-21): at rest nothing changes; scrolled, the list's top mask hides rows
/// under the lights outright and fades them in below, from `Metrics.titlebarHeight` down.
@MainActor @Suite(.serialized) struct SidebarTopMaskTests {
    /// A document taller than its scroll view, top-down, so offset 0 is the top.
    private final class TallDocument: NSView {
        override var isFlipped: Bool { true }
    }

    private static func fadeView(height: CGFloat = 300) -> (ScrollEdgeFadeView, NSScrollView) {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: height))
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = TallDocument(frame: NSRect(x: 0, y: 0, width: 200, height: height * 4))
        let fade = ScrollEdgeFadeView(scrollView: scroll)
        fade.layoutSubtreeIfNeeded()
        return (fade, scroll)
    }

    private static func scroll(_ scroll: NSScrollView, to offset: CGFloat, _ fade: ScrollEdgeFadeView) {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scroll.reflectScrolledClipView(scroll.contentView)
        fade.updateFade(animated: false)
    }

    /// The mask's alpha `y` points below the list's top: its gradient read the way Core Animation
    /// draws it (location 0 is the top on screen; the end colors extend past the end stops).
    private static func alpha(_ fade: ScrollEdgeFadeView, at y: CGFloat) throws -> CGFloat {
        let mask = try #require(fade.layer?.mask as? CAGradientLayer)
        let stops = (mask.locations ?? []).map { CGFloat($0.doubleValue) }
        let alphas = ((mask.colors as? [CGColor]) ?? []).map(\.alpha)
        try #require(stops.count == alphas.count && !stops.isEmpty)
        let t = y / max(mask.bounds.height, 1)
        if t <= stops[0] { return alphas[0] }
        for index in 1..<stops.count where t <= stops[index] {
            let span = stops[index] - stops[index - 1]
            let progress = span > 0 ? (t - stops[index - 1]) / span : 1
            return alphas[index - 1] + (alphas[index] - alphas[index - 1]) * progress
        }
        return alphas[alphas.count - 1]
    }

    @Test func atRestTheTopClipChangesNothing() throws {
        let (fade, _) = Self.fadeView()
        fade.topClip = 6
        #expect(!fade.edges.contains(.top))
        for y in stride(from: CGFloat(0), through: 60, by: 1) {
            #expect(try Self.alpha(fade, at: y) == 1, "at rest the list's top shows at \(y) pt")
        }
    }

    @Test func scrolledTheTopClipHidesRowsThenFades() throws {
        let (fade, scroll) = Self.fadeView()
        fade.topClip = 6
        Self.scroll(scroll, to: 120, fade)
        #expect(fade.edges.contains(.top))
        for y in stride(from: CGFloat(0), to: 6, by: 0.5) {
            #expect(try Self.alpha(fade, at: y) == 0, "scrolled, a row \(y) pt below the list's top is hidden")
        }
        let below = try Self.alpha(fade, at: 6 + Metrics.scrollEdgeFade / 2)
        #expect(below > 0 && below < 1, "the fade starts below the hidden band")
        #expect(try Self.alpha(fade, at: 6 + Metrics.scrollEdgeFade + 1) == 1)
    }

    @Test func withNoTopClipTheFadeStartsAtTheTop() throws {
        let (fade, scroll) = Self.fadeView()
        Self.scroll(scroll, to: 120, fade)
        #expect(try Self.alpha(fade, at: 0) == 0)
        #expect(try Self.alpha(fade, at: 2) > 0, "no hidden band: the fade begins at the list's top")
    }

    private static func sidebar(titlebarRow: CGFloat, windowControls: Bool = true) -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let workspaces = (0..<60).map { SidebarWorkspace(id: WorkspaceID("ws-\($0)"), title: "workspace \($0)") }
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: workspaces.map { .workspace($0) })])
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.titlebarHeightOverride = titlebarRow
        sidebar.headerHasWindowControls = windowControls
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        return sidebar
    }

    /// The minimal titlebar's header row (the tab strip's height): the list keeps its top, and
    /// the band hidden while scrolled runs from there to the titlebar's bottom.
    @Test func minimalTitlebarHidesUpToTheTitlebarBottom() {
        let sidebar = Self.sidebar(titlebarRow: Metrics.tabStripHeight)
        for fade in [sidebar.aboveFade, sidebar.edgeFade] {
            let top = fade.frame.minY
            #expect(top >= Metrics.tabStripHeight, "the band is not moved up")
            #expect(top + fade.topClip == max(top, Metrics.titlebarHeight), "hidden down to the titlebar's bottom from \(top) pt")
        }
    }

    @Test func fullTitlebarHidesNothing() {
        let sidebar = Self.sidebar(titlebarRow: Metrics.titlebarHeight)
        #expect(sidebar.edgeFade.topClip == 0)
        #expect(sidebar.aboveFade.topClip == 0)
    }

    /// A right sidebar has no traffic lights over it: nothing to hide.
    @Test func noWindowControlsHidesNothing() {
        let sidebar = Self.sidebar(titlebarRow: Metrics.tabStripHeight, windowControls: false)
        #expect(sidebar.edgeFade.topClip == 0)
        #expect(sidebar.aboveFade.topClip == 0)
    }
}
