import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The titlebar's + and its workspace chooser read as one native split button, as a macOS toolbar
/// menu item draws it: the + first, a narrow chevron right after it with no gap, both the +'s
/// height. Lawrence 2026-10-30 (message 17682): "the dropdown on left of plus is ugly" (a full-size
/// chevron left of the + read as a third Back/Forward arrow).
@MainActor @Suite(.serialized) struct SidebarNewWorkspaceSplitButtonTests {
    func sidebar(width: CGFloat = 280) -> SidebarView {
        _ = NSApplication.shared
        // The chevron is opt-in (`sidebar.showNewWorkspaceChooser`, off by default since 2026-10-30).
        let design = DesignSettings()
        design.sidebarSections.showNewWorkspaceChooser = true
        let sidebar = SidebarView(model: SidebarModel(), design: design)
        sidebar.frame = NSRect(x: 0, y: 0, width: width, height: 480)
        sidebar.layoutSubtreeIfNeeded()
        return sidebar
    }

    @Test func theChevronTrailsThePlusAsOneNarrowSegment() {
        let sidebar = sidebar()
        let plus = sidebar.newButton.frame, chevron = sidebar.newWorkspaceOptionsButton.frame
        #expect(!sidebar.newWorkspaceOptionsButton.isHidden)
        #expect(chevron.minX == plus.maxX, "the chevron sits right after the +, touching it")
        #expect(chevron.width < plus.width * 0.7, "the chevron is a narrow indicator, not a third arrow button")
        #expect(chevron.height == plus.height && chevron.minY == plus.minY)
        #expect(chevron.maxX == sidebar.bounds.width - Metrics.space3, "the pair keeps the +'s trailing inset")
    }

    @Test func withoutRoomThePlusTakesTheTrailingSlotAlone() {
        let sidebar = sidebar()
        sidebar.titlebarLeadingReserve = sidebar.bounds.width - Metrics.space3 - SidebarStyle.toolbarButtonSize
        sidebar.layoutSubtreeIfNeeded()
        #expect(sidebar.newWorkspaceOptionsButton.isHidden)
        #expect(sidebar.newButton.frame.maxX == sidebar.bounds.width - Metrics.space3)
        #expect(sidebar.newButton.frame.minX >= sidebar.titlebarLeadingReserve)
    }
}
