@testable import CmuxNextApp
import CmuxNextCompat
import CoreGraphics
import Testing

/// idle-budget's shipping measurement mode launches without no-activate, so the app
/// can activate, and with `CMUX_NEXT_ISOLATED_LAUNCH=1`: its windows still open at the bench's fixed
/// frame, so every host draws the same pixels.
@Suite struct TestWindowPlacementIsolationTests {
    private let frame = ["CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1440,900", "CMUX_NEXT_TEST_WINDOW_SCREEN": "0"]

    @Test func theShippingEnvKeepsTheBenchFrame() {
        var environment = frame
        environment["CMUX_NEXT_ISOLATED_LAUNCH"] = "1"
        environment["CMUX_NEXT_BENCH_SHIPPING_DRAW"] = "1"
        let isolation = LaunchIsolation(environment: environment)
        #expect(isolation.noActivate == false)
        let placement = TestWindowPlacement.parse(environment, isolatedLaunch: isolation.isolated)
        #expect(placement == TestWindowPlacement(screen: .index(0), frame: CGRect(x: 40, y: 40, width: 1440, height: 900)))
    }

    @Test func aUsersLaunchIgnoresTheKnobs() {
        #expect(TestWindowPlacement.parse(frame, isolatedLaunch: LaunchIsolation(environment: frame).isolated) == nil)
    }
}
