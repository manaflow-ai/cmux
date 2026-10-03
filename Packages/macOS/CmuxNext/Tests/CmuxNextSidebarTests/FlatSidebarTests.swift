import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// The flat sidebar: each workspace row starts with its type glyph, a custom
/// icon replaces that glyph without changing the title column, and the resize
/// edge stays hidden until hover.
@MainActor @Suite struct FlatSidebarTests {
    @Test func rowsReserveTheTypeIconColumnAndKeepCustomIconsAligned() throws {
        var sections = fixture()
        sections[1].nodes[0] = .workspace(SidebarWorkspace(id: id("a"), title: "a", icon: .symbol("hammer")))
        let h = MinimalChromeTests.Harness(sections: sections)
        let plain = try #require(h.sidebar.list.rowViews[.workspace(id("b"))] as? WorkspaceRowView)
        let iconned = try #require(h.sidebar.list.rowViews[.workspace(id("a"))] as? WorkspaceRowView)
        plain.layoutSubtreeIfNeeded()
        iconned.layoutSubtreeIfNeeded()
        // A row without a user icon still shows its terminal type glyph.
        #expect(plain.titleFrame.minX > SidebarStyle.horizontalInset)
        // Replacing the type glyph with a custom symbol does not move the
        // title column or create a second, blank leading gap.
        #expect(iconned.titleFrame.minX == plain.titleFrame.minX)
        let icons = plain.subviews.compactMap { $0 as? SidebarIconView }
        #expect(icons.count == 1)
        #expect(icons.allSatisfy { !$0.isHidden })
    }

    @Test func onlyAChosenIconTakesRoom() {
        #expect(!SidebarIconView.showsIcon(nil))
        #expect(SidebarIconView.showsIcon(.swatch(.red)))
        #expect(SidebarIconView.showsIcon(.symbol("hammer")))
    }

    @Test func containerIsAFlatSurfaceWithNoGlassOrVisibleEdge() throws {
        let container = SidebarContainerView(model: SidebarModel(sections: fixture()))
        let all = [container] + container.allSubviews
        let hasGlass = all.contains { $0 is NSGlassEffectView }
        #expect(!hasGlass)
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
        // The name aligns with workspace titles; the chevron trails.
        #expect(header.titleFrame.minX == SidebarStyle.horizontalInset)
        #expect(header.disclosureFrame.midX > header.bounds.midX)
        #expect(header.titleFont == SidebarStyle.headerFont)
    }
}
