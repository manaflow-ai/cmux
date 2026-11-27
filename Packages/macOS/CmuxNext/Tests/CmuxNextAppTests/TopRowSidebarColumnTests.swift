import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The sidebar's top control lines up with what sits below it (Leo 2026-11-07: "the top of the sidebar
/// with the subsequent elements below (workspaces and their notification symbols, then the search
/// icon)"): the titlebar row's + centers on the trailing column that the rows' status marks, their
/// unread dots and footer Search share, at every density and sidebar width.
@MainActor @Suite(.serialized) struct TopRowSidebarColumnTests {
    @Test(arguments: DensityPreset.allCases) func thePlusCentersOnTheTrailingColumn(_ preset: DensityPreset) {
        _ = NSApplication.shared
        let saved = DesignSettings.shared.densityTokens
        DesignSettings.shared.densityTokens = preset.tokens
        defer { DesignSettings.shared.densityTokens = saved }
        for width in [Metrics.sidebarMinWidth, Metrics.sidebarWidth, 300, Metrics.sidebarMaxWidth] {
            let sidebar = SidebarView(model: SidebarModel(), design: DesignSettings())
            sidebar.frame = NSRect(x: 0, y: 0, width: width, height: 480)
            sidebar.layoutSubtreeIfNeeded()
            let column = SidebarStyle.trailingColumnCenterX(sidebarWidth: width)
            #expect(abs(sidebar.newButton.frame.midX - column) <= 0.5, "\(preset.rawValue) at \(width): + \(sidebar.newButton.frame.midX), column \(column)")
            let search = SidebarStyle.trailingColumnFrame(sidebarWidth: width, centerY: 0, side: SidebarFooterBand.searchButtonSide)
            #expect(abs(sidebar.newButton.frame.midX - search.midX) <= 0.5, "\(preset.rawValue) at \(width): Search \(search.midX)")
        }
    }
}
