import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// The flat sidebar: a workspace row draws no icon unless the user chose one
/// (WORKSPACE-ROWS-NO-DEFAULT-ICON); a chosen icon takes the leading slot and
/// moves the title past it. The resize edge stays hidden until hover.
@MainActor @Suite struct FlatSidebarTests {
    @Test func onlyAChosenIconTakesTheLeadingSlot() throws {
        var sections = fixture()
        sections[1].nodes[0] = .workspace(SidebarWorkspace(id: id("a"), title: "a", icon: .symbol("hammer")))
        let h = MinimalChromeTests.Harness(sections: sections)
        let plain = try #require(h.sidebar.list.rowViews[.workspace(id("b"))] as? WorkspaceRowView)
        let iconned = try #require(h.sidebar.list.rowViews[.workspace(id("a"))] as? WorkspaceRowView)
        plain.layoutSubtreeIfNeeded()
        iconned.layoutSubtreeIfNeeded()
        // A row without a user icon starts its title at the leading inset.
        #expect(plain.titleFrame.minX == SidebarStyle.titleLeading)
        #expect(plain.subviews.compactMap { $0 as? SidebarIconView }.allSatisfy { $0.isHidden })
        // A chosen icon draws and the title follows it.
        #expect(iconned.titleFrame.minX > plain.titleFrame.minX)
        #expect(iconned.subviews.compactMap { $0 as? SidebarIconView }.contains { !$0.isHidden })
    }

    @Test func onlyAChosenIconTakesRoom() {
        #expect(!SidebarIconView.showsIcon(nil))
        #expect(SidebarIconView.showsIcon(.swatch(.red)))
        #expect(SidebarIconView.showsIcon(.symbol("hammer")))
    }

    /// The sidebar itself is flat. Only a floating card drawn on
    /// `OverlaySurfaceView` (the Did you know card, Liquid Glass by Lawrence's
    /// decision in cx-367y) may hold glass.
    @Test func containerIsAFlatSurfaceWithNoGlassOrVisibleEdge() throws {
        let container = SidebarContainerView(model: SidebarModel(sections: fixture()))
        let all = [container] + container.allSubviews
        let onAnOverlayCard = { (view: NSView) in
            sequence(first: view.superview, next: { $0?.superview }).contains { $0 is OverlaySurfaceView }
        }
        let flatGlass = all.filter { $0 is NSGlassEffectView && !onAnOverlayCard($0) }
        #expect(flatGlass.isEmpty, "glass outside an overlay card: \(flatGlass)")
        let handle = try #require(container.subviews.compactMap { $0 as? SidebarResizeHandle }.first)
        #expect(!handle.isLineVisible)
        handle.setHovered(true)
        #expect(handle.isLineVisible)
        handle.setHovered(false)
        #expect(!handle.isLineVisible)
    }

    @Test func groupHeadersAreQuietText() throws {
        let h = MinimalChromeTests.Harness(sections: fixture())
        let header = try #require(h.sidebar.list.rowViews[.group(g1)] as? GroupHeaderRowView)
        header.layoutSubtreeIfNeeded()
        // The chip (cx-rcby): it starts near the workspace titles' inset and
        // the collapse chevron ends it, after the name.
        let row = try #require(h.sidebar.list.rowViews[.workspace(id("b"))] as? WorkspaceRowView)
        row.layoutSubtreeIfNeeded()
        #expect(header.labelFrame.minX <= row.titleFrame.minX, "chip \(header.labelFrame.minX) row \(row.titleFrame.minX)")
        #expect(header.disclosureFrame.midX > header.titleFrame.maxX)
        #expect(header.titleFont == SidebarStyle.headerFont)
    }
}
