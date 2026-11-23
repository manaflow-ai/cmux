import XCTest

/// The listperf cases of `verify/listperf/final.sh` as UI tests, for a profiler that records a
/// UI test run (`cmux-next-ios-sim.sh test ui=ListPerfProfileUITests/<method> profile`). Each
/// launches the app with exactly that case's rig environment, as `rig.sh run` does, and waits
/// for the rig to exit after its passes. They check nothing: the trace is the result.
final class ListPerfProfileUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    /// Launch with `CMUX_MOBILE_LIST_SCREEN=screen` and `CMUX_MOBILE_<K>=V` for each setting,
    /// and wait (up to 240 s, rig.sh's WAIT) for the rig to exit when done.
    @MainActor
    private func run(_ screen: String, _ settings: [String: String]) {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_FRAMELOG"] = "1"
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = screen
        app.launchEnvironment["CMUX_MOBILE_LIST_EXIT_WHEN_DONE"] = "1"
        for (key, value) in settings { app.launchEnvironment["CMUX_MOBILE_\(key)"] = value }
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore"]
        app.launch()
        if !app.wait(for: .notRunning, timeout: 240) {
            print("CMUX_LISTPERF_PROFILE \(screen): still running after 240 s")
            app.terminate()
        }
    }

    // final.sh: "events-filter      inspector   LIST_COUNT=500 LIST_LIVE_HZ=20 LIST_FILTER=tool_call"
    @MainActor func testEventsFilter() { run("inspector", ["LIST_COUNT": "500", "LIST_LIVE_HZ": "20", "LIST_FILTER": "tool_call"]) }
    // final.sh: "events-500         inspector   LIST_COUNT=500"
    @MainActor func testEvents500() { run("inspector", ["LIST_COUNT": "500"]) }
    // final.sh: "events-burst       inspector   LIST_COUNT=500 LIST_STREAM=1"
    @MainActor func testEventsBurst() { run("inspector", ["LIST_COUNT": "500", "LIST_STREAM": "1"]) }
    // final.sh: "subagent-2000      subagent    LIST_COUNT=2000 LIST_PASSES=1"
    @MainActor func testSubagent2000() { run("subagent", ["LIST_COUNT": "2000", "LIST_PASSES": "1"]) }
    // final.sh: "subagent-stream    subagent    LIST_COUNT=40 LIST_STREAM=1"
    @MainActor func testSubagentStream() { run("subagent", ["LIST_COUNT": "40", "LIST_STREAM": "1"]) }
    // final.sh: "subagents-list-60  subagents   LIST_COUNT=60 LIST_LIVE_HZ=4"
    @MainActor func testSubagentsList60() { run("subagents", ["LIST_COUNT": "60", "LIST_LIVE_HZ": "4"]) }
}
