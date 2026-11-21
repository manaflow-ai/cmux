import XCTest

/// A profiling target, not a check: the list rig's `ws-500-live8` case (verify/listperf/final.sh:
/// 500 seeded workspaces, live Mac updates at 8 Hz) run under a UI test, so
/// `scripts/ci/cmux-next-ios-sim.sh test ui=ListLiveProfileUITests profile` records a Time Profiler
/// trace of the Workspaces list taking live events while the rig scrolls its passes. The launch
/// environment is listperf's for that case (CMUX_MOBILE_LIST_* plus mock auth, exit when done); the
/// test waits for the rig to finish its passes and exit the app, bounded at 120 s.
final class ListLiveProfileUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testWorkspaces500Live8() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_FRAMELOG"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = "workspaces"
        app.launchEnvironment["CMUX_MOBILE_LIST_COUNT"] = "500"
        app.launchEnvironment["CMUX_MOBILE_LIST_LIVE_HZ"] = "8"
        app.launchEnvironment["CMUX_MOBILE_LIST_EXIT_WHEN_DONE"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore"]
        app.launch()
        defer { if app.state != .notRunning { app.terminate() } }
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 5) { app.buttons["Manaflow"].tap() }
        // The rig scrolls its passes, then exits the app.
        let exited = app.wait(for: .notRunning, timeout: 120)
        print("LISTLIVEPROFILE exited=\(exited) state=\(app.state.rawValue)")
    }
}
