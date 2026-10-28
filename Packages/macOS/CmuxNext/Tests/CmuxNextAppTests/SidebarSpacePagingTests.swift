import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Space paging by swipe, wheel and dot: every step the person makes counts, in the step's own turn.
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

    /// Audit B9: a released swipe switched the space only once its settle spring finished (about 250 ms), and wheel
    /// steps and swipes in that time were dropped. The release is the person's choice: the space switches in its own
    /// turn while the pages keep sliding, and the next step counts.
    @Test func aReleasedSwipeSwitchesTheSpaceInItsOwnTurnAndTheNextStepCounts() {
        let (model, sidebar) = sidebar()
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }

        sidebar.spacePaging.scroll(.began, deltaX: -180, time: 0)
        sidebar.spacePaging.scroll(.ended, deltaX: 0, time: 0.1)
        #expect(model.activeProfileID == ProfileKey("space1"), "the released swipe waited for its settle animation to switch the space")

        // A wheel notch right after the release (the settle still running) pages on from there.
        sidebar.spacePaging.page(by: 1)
        #expect(model.activeProfileID == ProfileKey("space2"), "a wheel step during the settle was dropped")
    }

    @Test func aSwipeRightAfterAReleasedSwipeStartsFromTheNewSpace() {
        let (model, sidebar) = sidebar()
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }

        sidebar.spacePaging.scroll(.began, deltaX: -180, time: 0)
        sidebar.spacePaging.scroll(.ended, deltaX: 0, time: 0.1)
        sidebar.spacePaging.scroll(.began, deltaX: -180, time: 0.15)
        sidebar.spacePaging.scroll(.ended, deltaX: 0, time: 0.25)
        #expect(model.activeProfileID == ProfileKey("space2"), "the second swipe was dropped behind the first one's settle")
    }

    @Test func supersedingSelectionReleasesPendingSwipe() {
        let (model, sidebar) = sidebar()
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }

        sidebar.spacePaging.scroll(.began, deltaX: -180, time: 0)
        sidebar.spacePaging.scroll(.ended, deltaX: 0, time: 0.1)
        #expect(model.activeProfileID == ProfileKey("space1"))

        // A click on a dot while the swipe's slide still runs, as in the app.
        model.apply(.switchProfile(ProfileKey("space2")))

        // The lock is gone: the wheel pages again, from the space the selection chose.
        sidebar.spacePaging.page(by: -1)
        #expect(model.activeProfileID == ProfileKey("space1"))
    }
}
