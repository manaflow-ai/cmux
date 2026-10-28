import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// A direct profile selection superseding a swipe must release the swipe lock.
@MainActor
struct SidebarSpacePagingTests {
    private func sidebar() -> (SidebarModel, SidebarView) {
        let model = SidebarModel()
        model.profiles = (0..<3).map { SidebarProfile(id: ProfileKey("space\($0)"), name: "Space \($0)") }
        model.activeProfileID = ProfileKey("space0")
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        return (model, sidebar)
    }

    @Test func supersedingSelectionReleasesPendingSwipe() {
        let (model, sidebar) = sidebar()
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }

        sidebar.spacePaging.scroll(.began, deltaX: -180, time: 0)
        sidebar.spacePaging.scroll(.ended, deltaX: 0, time: 0.1)
        #expect(sidebar.spacePaging.pendingTarget == ProfileKey("space1"))

        // The settle's completion (the swipe's own switch) waits on Core Animation, so the
        // direct selection lands first, as a click on a dot mid-settle does in the app.
        model.apply(.switchProfile(ProfileKey("space2")))
        #expect(!sidebar.spacePaging.modelDidSwitch(to: ProfileKey("space2")))
        #expect(sidebar.spacePaging.pendingTarget == nil)

        // The lock is gone: the wheel pages again, from the space the selection chose.
        sidebar.spacePaging.page(by: -1)
        #expect(model.activeProfileID == ProfileKey("space1"))
    }
}
