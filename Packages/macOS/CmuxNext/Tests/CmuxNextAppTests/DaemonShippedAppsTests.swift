import Foundation
@testable import CmuxNextDaemonService
import Testing

/// The App Store lists only what cmux ships as its own apps (Leo, 2026-11-16: "stop shipping these
/// into the app store if they're fucking busted"): the app hands its daemon the first-party folder
/// and no apps directory, so the SDK examples in `AppPlatform/store` never become listings.
@Suite
struct DaemonShippedAppsTests {
    @Test func theDaemonGetsTheFirstPartyAppsAndNoExamples() {
        let environment = DaemonService.firstPartyAppsEnvironment
        #expect(environment["CMUX_APPS_FIRST_PARTY_DIR"] != nil)
        #expect(environment["CMUX_APPS_DIRS"] == nil)
    }
}
