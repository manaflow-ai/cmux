@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// The Chief owner gets the open-file limit the app was launched with from the app
/// (`AppEnvironment.daemonEnvironment`), so its brains and their tool shells get it back
/// (pl-cef-tab-nofile review 1: the owner inherited the app's raised limit and passed it on).
struct ChiefOwnerLaunchLimitTests {
    /// cmux-pty `LAUNCH_SOFT_LIMIT_ENV` (`OpenFileLimit.originalSoftLimitKey`).
    static let key = "CMUX_TUI_HOST_NOFILE_SOFT"

    static func home() -> ChiefHome {
        ChiefHome(root: FileManager.default.temporaryDirectory.appendingPathComponent("chief-launch-limit-\(UUID().uuidString)"),
                  isolated: true)
    }

    @Test func theOwnerGetsTheAppsLaunchLimit() {
        let environment = ChiefConversationOwner.ownerEnvironment(home: Self.home(), process: ["HOME": "/Users/someone"],
                                                                  launch: [Self.key: "256"])
        #expect(environment[Self.key] == "256")
    }
}
