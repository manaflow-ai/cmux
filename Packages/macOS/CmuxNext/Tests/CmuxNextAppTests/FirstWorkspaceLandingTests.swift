@testable import CmuxNextApp
import CmuxNextHome
import Testing

/// A first launch with no workspace of the person's own lands on Home, the Chief's workspace,
/// instead of making an empty New Tab workspace (Leo 2026-10-19: the Chief as the front door).
/// Debug Settings > Home > First launch opens Home off, or classic Home, keeps the New Tab
/// workspace.
struct FirstWorkspaceLandingTests {
    @Test func homeIsTheFrontDoorByDefault() {
        #expect(HomeTunables.launchIntoHome.descriptor.key == "home.launchIntoHome")
        #expect(HomeTunables.all.contains { $0.key == "home.launchIntoHome" })
        #expect(FirstWorkspace.landing(launchIntoHome: true, classic: false, home: "ws_home") == "ws_home")
    }

    @Test func theSwitchOffOrClassicHomeMakesANewTabWorkspace() {
        #expect(FirstWorkspace.landing(launchIntoHome: false, classic: false, home: "ws_home") == nil)
        #expect(FirstWorkspace.landing(launchIntoHome: true, classic: true, home: "ws_home") == nil)
    }

    @Test func noHomeWorkspaceYetMakesANewTabWorkspace() {
        #expect(FirstWorkspace.landing(launchIntoHome: true, classic: false, home: nil) == nil)
    }
}
