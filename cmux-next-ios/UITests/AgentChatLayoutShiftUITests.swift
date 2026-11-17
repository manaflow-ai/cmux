import XCTest

/// Leo, 2026-11-17: "the gui is fine on phone other than the jitter on load sometimes and layout
/// shift and the lack of themeing/background inheriting (these need to be improved)".
///
/// The layout-shift flow end to end, for the PR's before and after recordings
/// (`scripts/ci/cmux-next-ios-sim.sh test ui=AgentChatLayoutShiftUITests video`): the list rig opens
/// a 60-turn agent chat (`CMUX_MOBILE_LIST_SCREEN=chat`), types and sends a prompt, and the mock
/// streams a long markdown answer with code blocks and tables while the reader stays on the newest
/// turn. The counts come from the kit's `TranscriptLayoutShiftTests`, which samples every row's
/// drawn frame each display frame; this test only drives the flow and keeps stills of it.
final class AgentChatLayoutShiftUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testChatOpensAndStreamsAtTheNewestTurn() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = "chat"
        app.launchEnvironment["CMUX_MOBILE_LIST_COUNT"] = "60"
        app.launchEnvironment["CMUX_MOBILE_LIST_PASSES"] = "0"
        app.launchEnvironment["CMUX_MOBILE_LIST_LARGE_DIFF"] = "0"
        app.launchEnvironment["CMUX_MOBILE_LIST_SEND"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LIST_STREAM"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LIST_LEAVE_NEWEST"] = "0"
        app.launchEnvironment["CMUX_MOBILE_LIST_OPEN_DELAY"] = "2"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES"]
        app.launch()
        defer { app.terminate() }

        // The chat opens, the prompt is typed and sent, and the answer streams: about 20 s in all.
        // The waits only pace the stills; the recording is the evidence.
        for frame in 0 ..< 24 {
            attach(app, String(format: "frame-%02d", frame))
            _ = XCTWaiter().wait(for: [XCTestExpectation(description: "pace")], timeout: 1)
        }
        XCTAssertTrue(app.state == .runningForeground, "the app stayed up through the stream")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
