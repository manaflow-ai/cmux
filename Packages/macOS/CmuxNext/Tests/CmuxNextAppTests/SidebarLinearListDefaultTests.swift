import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// By default the sidebar is a plain linear list of workspaces (with groups): no dropdowns.
/// Lawrence 2026-10-30 (message 18548): "by default i dont want to have workspace titlebar
/// dropdowns at all, i just want to have linear list of workspaces (with groups ofc)". The
/// titlebar shows the + alone (no chooser chevron).
@MainActor @Suite(.serialized) struct SidebarLinearListDefaultTests {
    func sidebar(design: DesignSettings = DesignSettings()) -> SidebarView {
        _ = NSApplication.shared
        let sidebar = SidebarView(model: SidebarModel(), design: design)
        sidebar.frame = NSRect(x: 0, y: 0, width: 280, height: 480)
        sidebar.layoutSubtreeIfNeeded()
        return sidebar
    }

    @Test func aFreshSidebarShowsThePlusWithNoChooserDropdown() {
        let sidebar = sidebar()
        #expect(sidebar.newWorkspaceOptionsButton.isHidden, "no workspace dropdown in the titlebar by default")
        // The + alone centers on the rows' trailing column (Leo 2026-11-07).
        #expect(abs(sidebar.newButton.frame.midX - (sidebar.bounds.width - SidebarStyle.trailingCenterFromEdge)) <= 0.5,
                "the + alone takes the trailing slot")
    }
}
