import Foundation
@testable import CmuxNextDaemonService
import Testing

/// The App Store lists cmux's own apps: the default apps and the store apps the build writes to
/// `AppPlatform/store` (Leo, 2026-11-20: "WHY THE F*** IS THERE STILL NOTHING IN THE APP STORE").
/// The daemon gets that folder, and its shelf rule keeps the SDK samples there off Discover.
@Suite
struct DaemonShippedAppsTests {
    @Test func theDaemonGetsTheFirstPartyAppsAndTheStorePackages() {
        let environment = DaemonService.firstPartyAppsEnvironment
        #expect(environment["CMUX_APPS_FIRST_PARTY_DIR"] != nil)
        #expect(environment["CMUX_APPS_DIRS"]?.hasSuffix("store") == true)
    }
}
