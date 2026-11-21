import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// A sidebar row's fill rounds as the tabs do at the density now (Lucas 2026-11-14: "the left sidebar tab becomes too
/// circular ... match the sidebar item roundness to the tab roundness"). The row set its corner once, when it was made,
/// so a row made at Spacious kept Spacious's corner on Compact's 20 pt row, nearly a pill beside 5 pt tabs.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarRowCornerFollowsDensityTests {
    @Test func aRowMadeAtOneDensityTakesTheNextDensitysCorner() {
        _ = NSApplication.shared
        let design = DesignSettings.shared
        let saved = design.densityTokens
        defer { design.densityTokens = saved }
        design.densityTokens = DensityPreset.spacious.tokens
        let view = EmptySectionRowView(key: .emptySection(.machine(.local)))
        view.frame = NSRect(x: 0, y: 0, width: 240, height: Metrics.chromeRowHeight)
        view.layoutSubtreeIfNeeded()
        let spacious = view.layer?.cornerRadius
        #expect(spacious == SidebarStyle.rowCornerRadius)

        design.densityTokens = DensityPreset.compact.tokens
        // The density change lays the row out again at its new height.
        view.frame.size.height = Metrics.chromeRowHeight
        view.layoutSubtreeIfNeeded()
        #expect(SidebarStyle.rowCornerRadius != spacious, "the two densities round differently")
        #expect(view.layer?.cornerRadius == SidebarStyle.rowCornerRadius, "the row takes Compact's corner")
        #expect(view.layer?.cornerRadius == Metrics.tabCornerRadius, "the row rounds as a tab")
    }
}
