@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSidebar
import Testing

/// Leo 2026-11-04: "i feel like the restarted after nightly update does too many layout shifts/flicker
/// renderings". The relaunch bench showed the footer's account item draw its 18 pt glyph in the first frame
/// and the 24 pt avatar a turn later, in about every window: the avatar came from a task's first loop pass.
@MainActor struct SidebarProfileControlFirstFrameTests {
    @Test func installGivesTheAvatarBeforeTheFirstFrame() {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let model = SidebarModel()
        let sidebar = SidebarView(model: model, design: DesignSettings())
        SidebarProfileControl(services: services, state: nil).install(model: model, sidebar: sidebar)
        #expect(model.profileAvatar != nil, "the account item draws the avatar in the turn the window is made")
    }
}
