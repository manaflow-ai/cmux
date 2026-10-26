@testable import CmuxNextDesign
import Testing

/// idle-budget's shipping measurement mode (p14-energy-100): an automation launch with
/// `CMUX_NEXT_BENCH_SHIPPING_DRAW=1` stops drawing occluded windows, as a user's launch does.
@Suite struct WindowDrawPolicyShippingDrawTests {
    private let automation = ["CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation"]

    @Test func shippingDrawMakesAnAutomationLaunchAUserLaunch() {
        var environment = automation
        environment[WindowDrawPolicy.shippingDrawKey] = "1"
        #expect(WindowDrawPolicy.isAutomationLaunch(environment) == false)
        #expect(WindowDrawPolicy.isAutomationLaunch(["CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_BENCH_SHIPPING_DRAW": "1"]) == false)
    }

    @Test func automationLaunchWithoutTheKeyStillDrawsOccludedWindowsInDebug() {
        #if DEBUG
        #expect(WindowDrawPolicy.isAutomationLaunch(automation))
        var environment = automation
        environment[WindowDrawPolicy.shippingDrawKey] = "0"
        #expect(WindowDrawPolicy.isAutomationLaunch(environment))
        #else
        #expect(WindowDrawPolicy.isAutomationLaunch(automation) == false)
        #endif
    }

    @Test func theKeyIsTheOneTheBenchSets() {
        #expect(WindowDrawPolicy.shippingDrawKey == "CMUX_NEXT_BENCH_SHIPPING_DRAW")
    }
}
