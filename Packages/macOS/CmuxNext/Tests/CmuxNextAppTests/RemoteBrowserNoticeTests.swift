@testable import CmuxNextApp
import CmuxNextRemoteLocalhostService
import Testing

/// The notice under a browser tab of another machine's workspace says where
/// localhost goes, from the tab's `RemoteLocalhostRoute`.
struct RemoteBrowserNoticeTests {
    @Test func forwardedLocalhostGoesToTheMachine() {
        #expect(RemoteStrings.browserRunsOnThisMac("studio", route: .machine("studio"))
                == "This tab runs on this Mac. localhost goes to studio.")
    }

    @Test func fallbackSaysLocalhostIsThisMacAndWhy() {
        #expect(RemoteStrings.browserRunsOnThisMac("studio", route: .thisMacInstead("studio", .turnedOff))
                == "This tab runs on this Mac, and localhost is this Mac too (forwarding is turned off).")
        #expect(RemoteStrings.browserRunsOnThisMac("studio", route: .thisMacInstead("studio", .updateMachine))
                == "This tab runs on this Mac, and localhost is this Mac too (studio needs a cmux update).")
        #expect(RemoteStrings.browserRunsOnThisMac("studio", route: .thisMacInstead("studio", .webKit))
                == "This tab runs on this Mac, and localhost is this Mac too (WebKit tabs cannot forward localhost).")
    }

    @Test func noRouteKeepsTheOldText() {
        #expect(RemoteStrings.browserRunsOnThisMac("studio", route: nil) == "This tab runs on this Mac, not on studio.")
        #expect(RemoteStrings.browserRunsOnThisMac("studio", route: .thisMac) == "This tab runs on this Mac, not on studio.")
    }
}
