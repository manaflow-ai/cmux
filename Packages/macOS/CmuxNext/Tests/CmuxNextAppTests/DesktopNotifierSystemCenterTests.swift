@testable import CmuxNextApp
import CmuxNextDesign
import Testing

/// Which launches post through the system notification center: a user's launch always; an automation
/// launch (e2e scripts, captures) only when it opts in with `CMUX_NEXT_NATIVE_NOTIFICATIONS=1`.
struct DesktopNotifierSystemCenterTests {
    @Test func aUsersLaunchUsesTheSystemCenter() {
        #expect(DesktopNotifier.usesSystemCenter(in: [:]))
        #expect(DesktopNotifier.usesSystemCenter(in: ["CMUX_NEXT_NATIVE_NOTIFICATIONS": "1"]))
    }

    @Test func anAutomationLaunchDoesNotUnlessItOptsIn() {
        for automation in [["CMUX_NEXT_SOCKET_MODE": "automation"], ["CMUX_NEXT_NO_ACTIVATE": "1"],
                           ["CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_NO_ACTIVATE": "1"]] {
            let expectedWithoutOptIn = !WindowDrawPolicy.isAutomationLaunch(automation)
            #expect(DesktopNotifier.usesSystemCenter(in: automation) == expectedWithoutOptIn)
            #expect(DesktopNotifier.usesSystemCenter(in: automation.merging(["CMUX_NEXT_NATIVE_NOTIFICATIONS": "1"]) { $1 }))
            for other in ["0", "", "true", "yes"] {
                #expect(DesktopNotifier.usesSystemCenter(in: automation.merging(["CMUX_NEXT_NATIVE_NOTIFICATIONS": other]) { $1 })
                    == expectedWithoutOptIn)
            }
        }
    }

    #if DEBUG
    @Test func aDebugAutomationLaunchIsOffByDefault() {
        #expect(!DesktopNotifier.usesSystemCenter(in: ["CMUX_NEXT_SOCKET_MODE": "automation"]))
        #expect(!DesktopNotifier.usesSystemCenter(in: ["CMUX_NEXT_NO_ACTIVATE": "1"]))
    }
    #endif
}
