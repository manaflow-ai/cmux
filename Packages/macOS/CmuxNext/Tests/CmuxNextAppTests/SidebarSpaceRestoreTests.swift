import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-15: at launch, while cmux-tui loads, the workspace list must not slide in from the
/// side. The window first shows the space saved with it; when the daemon then restores another
/// space, the list shows it at once. A space the person picks still slides (R99).
@MainActor
struct SidebarSpaceRestoreTests {
    private func sidebar() -> (SidebarModel, SidebarView) {
        let model = SidebarModel()
        model.profiles = [SidebarProfile(id: ProfileKey("first"), name: "First"), SidebarProfile(id: ProfileKey("second"), name: "Second")]
        model.activeProfileID = ProfileKey("first")
        let sidebar = SidebarView(model: model)
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.renderNow()
        return (model, sidebar)
    }

    @Test(.enabled("a slide needs motion on") { await MainActor.run { Motion.animatesMovement } })
    func theSpaceRestoredAtLaunchShowsWithoutASlide() {
        let (model, sidebar) = sidebar()
        model.restoreActiveProfile(ProfileKey("second"))
        sidebar.renderNow()
        #expect(model.activeProfileID == ProfileKey("second"))
        #expect(sidebar.spacePaging.snapshotView == nil, "the restored space slid in")
    }

    @Test(.enabled("a slide needs motion on") { await MainActor.run { Motion.animatesMovement } })
    func aSpaceThePersonPicksStillSlides() {
        let (model, sidebar) = sidebar()
        model.apply(.switchProfile(ProfileKey("second")))
        sidebar.renderNow()
        #expect(sidebar.spacePaging.snapshotView != nil, "a picked space no longer slides")
    }
}
