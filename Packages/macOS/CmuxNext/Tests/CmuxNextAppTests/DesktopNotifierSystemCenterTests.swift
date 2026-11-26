@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextNotifications
import Testing

/// Which launches post through the system notification center: a user's launch always; an automation
/// launch (e2e scripts, captures) only when it opts in with `CMUX_NEXT_NATIVE_NOTIFICATIONS=1`.
struct DesktopNotifierSystemCenterTests {
    /// A click that cold-launched the app reaches the delegate before the app sets `onOpen`: it is
    /// parked and runs, in order, once `onOpen` is set; later clicks go straight through.
    @MainActor @Test func clicksBeforeOnOpenRunOnceItIsSet() {
        let notifier = DesktopNotifier()
        notifier.open(id: "cmux-notification-1", surface: 1)
        notifier.open(id: "cmux-notification-2", surface: nil)
        #expect(notifier.parkedOpens.count == 2)
        var runs: [String] = []
        notifier.onOpen = { id, surface in runs.append("\(id)@\(surface.map(String.init) ?? "-")") }
        #expect(runs == ["cmux-notification-1@1", "cmux-notification-2@-"])
        #expect(notifier.parkedOpens.isEmpty)
        notifier.open(id: "cmux-notification-3", surface: 3)
        #expect(runs.last == "cmux-notification-3@3")
        notifier.prepare() // outside the main app bundle: no center, no crash
    }

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

    @Test func aGUIJobAsksForPermissionOnlyWhenItOptsIn() {
        #expect(DesktopNotifier.asksPermission(in: [:]))
        for job in [["NX_REMOTE": "1"], ["CMUX_TEST_REQUIRE_GUI": "1"]] {
            #expect(!DesktopNotifier.asksPermission(in: job))
            #expect(DesktopNotifier.asksPermission(in: job.merging(["CMUX_NEXT_NATIVE_NOTIFICATIONS": "1"]) { $1 }))
            let automationJob = job.merging(["CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_NATIVE_NOTIFICATIONS": "1"]) { $1 }
            #expect(DesktopNotifier.asksPermission(in: automationJob))
        }
        let automation = ["CMUX_NEXT_SOCKET_MODE": "automation"]
        #expect(DesktopNotifier.asksPermission(in: automation) == DesktopNotifier.usesSystemCenter(in: automation))
        #expect(DesktopNotifier.asksPermission(in: automation.merging(["CMUX_NEXT_NATIVE_NOTIFICATIONS": "1"]) { $1 }))
    }

    @Test func onlyAnOptedInAutomationLaunchStartsWithoutDeliveredBanners() {
        #expect(!DesktopNotifier.startsWithoutDeliveredBanners(in: [:]))
        #expect(!DesktopNotifier.startsWithoutDeliveredBanners(in: ["CMUX_NEXT_SOCKET_MODE": "automation"]))
        let optedIn = ["CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_NATIVE_NOTIFICATIONS": "1"]
        #expect(DesktopNotifier.startsWithoutDeliveredBanners(in: optedIn) == WindowDrawPolicy.isAutomationLaunch(optedIn))
        // A user's launch that happens to set the variable keeps its Notification Center history.
        #expect(!DesktopNotifier.startsWithoutDeliveredBanners(in: ["CMUX_NEXT_NATIVE_NOTIFICATIONS": "1"]))
    }

    #if DEBUG
    @Test func aDebugAutomationLaunchIsOffByDefault() {
        #expect(!DesktopNotifier.usesSystemCenter(in: ["CMUX_NEXT_SOCKET_MODE": "automation"]))
        #expect(!DesktopNotifier.usesSystemCenter(in: ["CMUX_NEXT_NO_ACTIVATE": "1"]))
    }
    #endif
}
