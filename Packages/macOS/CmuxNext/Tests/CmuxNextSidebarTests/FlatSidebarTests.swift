import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// The flat, text-first sidebar: no glass panel, no per-row icon unless
/// the user chose one, no visible resize edge until hover.
@MainActor @Suite struct FlatSidebarTests {
    @Test func rowsAreTextFirstUnlessTheUserChoseAnIcon() throws {
        var sections = fixture()
        sections[1].nodes[0] = .workspace(SidebarWorkspace(id: id("a"), title: "a", icon: .symbol("hammer")))
        let h = MinimalChromeTests.Harness(sections: sections)
        let plain = try #require(h.sidebar.list.rowViews[.workspace(id("b"))] as? WorkspaceRowView)
        let iconned = try #require(h.sidebar.list.rowViews[.workspace(id("a"))] as? WorkspaceRowView)
        plain.layoutSubtreeIfNeeded()
        iconned.layoutSubtreeIfNeeded()
        #expect(plain.titleFrame.minX == SidebarStyle.horizontalInset)
        #expect(iconned.titleFrame.minX > SidebarStyle.horizontalInset + SidebarStyle.iconBox)
        let icons = plain.subviews.compactMap { $0 as? SidebarIconView }
        let allHidden = icons.allSatisfy(\.isHidden)
        #expect(allHidden)
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
