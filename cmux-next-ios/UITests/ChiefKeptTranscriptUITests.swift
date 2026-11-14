import XCTest

/// The user, 2026-11-06: Chief keeps its newest messages on the phone, "so I don't just see a
/// loading spinner when I come back from app background", like Messages and WhatsApp. Opens
/// the mock Chief, sends the app to the background, relaunches it with the newest page held
/// back 5 s (`-cmux-mobile-chief-slow-history`), and checks the kept messages show at once with
/// no spinner. Before, the relaunch showed the spinner until the page arrived.
final class ChiefKeptTranscriptUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testARelaunchShowsTheKeptMessagesBeforeThePage() throws {
        let first = launch(slowHistory: false)
        let mine = first.cells["conversation.message.msg_local_7"]
        XCTAssertTrue(mine.waitForExistence(timeout: 30), "Chief's transcript\n\(first.debugDescription)")
        attach(first, "0-chief-open")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(first.wait(for: .runningBackground, timeout: 10), "the app in the background")
        first.terminate()

        let again = launch(slowHistory: true)
        let field = again.textViews["conversation.composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "Chief's composer\n\(again.debugDescription)")
        // The page is 5 s away: only the kept messages can show this soon.
        XCTAssertTrue(again.cells["conversation.message.msg_local_7"].waitForExistence(timeout: 2),
                      "the kept messages show at once\n\(again.debugDescription)")
        XCTAssertFalse(again.descendants(matching: .any)["conversation.initialLoading"].exists, "no spinner over them")
        attach(again, "2-relaunch-kept")
        // Frames across the 5 s the page is held back and after it lands (the evidence video is
        // made of these: the fleet's simulator step records no screen video). The waits only pace
        // the captures; nothing waits on them.
        for frame in 0..<16 {
            XCTAssertFalse(again.descendants(matching: .any)["conversation.initialLoading"].exists, "no spinner at frame \(frame)")
            attach(again, String(format: "frame-%02d", frame))
            _ = XCTWaiter().wait(for: [XCTestExpectation(description: "pace")], timeout: 0.5)
        }
        XCTAssertTrue(again.cells["conversation.message.msg_local_7"].exists, "the server's page keeps the rows")
    }

    @MainActor
    private func launch(slowHistory: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "chief-open"]
        if slowHistory { app.launchArguments.append("-cmux-mobile-chief-slow-history") }
        app.launch()
        return app
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
