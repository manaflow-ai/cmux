@testable import CmuxNextCompat
import Testing

/// An isolated launch (agent or bench) leaves the account alone whether or not it may activate
/// (idle-budget's shipping mode activates the app but must not claim the `cmux` shim).
@Suite struct LaunchIsolationTests {
    @Test func noActivateIsIsolated() {
        let isolation = LaunchIsolation(environment: ["CMUX_NEXT_NO_ACTIVATE": "1"])
        #expect(isolation.noActivate)
        #expect(isolation.isolated)
    }

    @Test func anIsolatedLaunchMayActivate() {
        let isolation = LaunchIsolation(environment: ["CMUX_NEXT_ISOLATED_LAUNCH": "1"])
        #expect(isolation.noActivate == false)
        #expect(isolation.isolated)
    }

    @Test func aUsersLaunchIsNeither() {
        let isolation = LaunchIsolation(environment: ["CMUX_NEXT_ISOLATED_LAUNCH": "0"])
        #expect(isolation.noActivate == false)
        #expect(isolation.isolated == false)
    }
}
