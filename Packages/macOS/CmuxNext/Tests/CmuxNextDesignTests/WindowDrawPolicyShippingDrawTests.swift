@testable import CmuxNextDesign
import Testing

/// idle-budget's shipping measurement mode: an automation launch with
/// `CMUX_NEXT_BENCH_SHIPPING_DRAW=1` stops drawing occluded windows, as a user's launch does, and
/// stays an automation launch for everything else (notifications, attention).
@Suite struct WindowDrawPolicyShippingDrawTests {
    private let automation = ["CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation"]
    /// The shipping env idle-budget launches with: no no-activate, the automation socket, the key.
    private let shipping = ["CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_ISOLATED_LAUNCH": "1",
                            "CMUX_NEXT_BENCH_SHIPPING_DRAW": "1"]

    @Test func shippingDrawStopsTheOccludedDraw() {
        var environment = automation
        environment[WindowDrawPolicy.shippingDrawKey] = "1"
        #expect(WindowDrawPolicy.drawsOccludedWindows(environment) == false)
        #expect(WindowDrawPolicy.drawsOccludedWindows(shipping) == false)
    }

    /// `DesktopNotifier.usesSystemCenter` and the pairing's Dock bounce read `isAutomationLaunch`:
    /// the key never turns a Debug bench launch into one that asks for notification permission.
    @Test func shippingDrawLeavesTheAutomationLaunchForNotifications() {
        #if DEBUG
        #expect(WindowDrawPolicy.isAutomationLaunch(shipping))
        var environment = automation
        environment[WindowDrawPolicy.shippingDrawKey] = "1"
        #expect(WindowDrawPolicy.isAutomationLaunch(environment))
        #else
        #expect(WindowDrawPolicy.isAutomationLaunch(shipping) == false)
        #endif
    }

    @Test func automationLaunchWithoutTheKeyStillDrawsOccludedWindowsInDebug() {
        #if DEBUG
        #expect(WindowDrawPolicy.drawsOccludedWindows(automation))
        var environment = automation
        environment[WindowDrawPolicy.shippingDrawKey] = "0"
        #expect(WindowDrawPolicy.drawsOccludedWindows(environment))
        #else
        #expect(WindowDrawPolicy.drawsOccludedWindows(automation) == false)
        #endif
        #expect(WindowDrawPolicy.drawsOccludedWindows([:]) == false)
    }

    @Test func theKeyIsTheOneTheBenchSets() {
        #expect(WindowDrawPolicy.shippingDrawKey == "CMUX_NEXT_BENCH_SHIPPING_DRAW")
    }
}
