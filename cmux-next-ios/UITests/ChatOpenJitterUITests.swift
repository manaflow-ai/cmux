import XCTest

/// Leo, 2026-11-17: "the gui is fine on phone other than the jitter on load sometimes and layout
/// shift and the lack of themeing/background inheriting (these need to be improved)".
///
/// Opens a 200-turn Codex chat (each turn a prompt, a thought, a read, an edit with a diff, a test
/// run and a markdown answer with code and a table) from the Workspaces list, through the list rig
/// (`ListStressRig`, `CMUX_MOBILE_LIST_SCREEN=chat`) holding the screen with no scroll passes, and
/// keeps the frames from the push until the chat settles. Run with `video` for the open's
/// recording and with `profile` for its main-thread time (`cmux-next-ios-sim.sh test
/// ui=ChatOpenJitterUITests video`); the frame times themselves come from the same rig's
/// `chat-open` window (`cmux-next-ios-sim.sh listperf cases=chat-200`).
final class ChatOpenJitterUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testOpeningALongChatSettles() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_FRAMELOG"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = "chat"
        app.launchEnvironment["CMUX_MOBILE_LIST_COUNT"] = "200"
        app.launchEnvironment["CMUX_MOBILE_LIST_PASSES"] = "0"
        app.launchEnvironment["CMUX_MOBILE_LIST_OPEN_DELAY"] = "3"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore"]
        app.launch()
        defer { app.terminate() }

        // The rig opens the chat `OPEN_DELAY` seconds after launch; the frames around it are the
        // evidence (the waits only pace the captures).
        let transcript = app.collectionViews.firstMatch
        for frame in 0..<16 {
            attach(app, String(format: "open-%02d", frame))
            _ = XCTWaiter().wait(for: [XCTestExpectation(description: "pace")], timeout: 0.35)
        }
        XCTAssertTrue(transcript.waitForExistence(timeout: 30), "the chat opens\n\(app.debugDescription)")
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "settle")], timeout: 2)
        attach(app, "settled")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
