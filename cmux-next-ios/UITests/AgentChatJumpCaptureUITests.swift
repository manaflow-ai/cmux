import XCTest

/// Captures the real jump control using the shipping app's offline DEBUG chat.
/// The synthetic waiting turn remains `.running` in AgentChatStore until answered;
/// its enabled Stop Agent action verifies the same gate that draws the ring/spinner.
/// This is visual evidence of that gate, not evidence of a live agent connection.
final class AgentChatJumpCaptureUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testRunningJumpControlCaptureAndReturnToBottom() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "kbd-chat"]
        app.launch()
        defer { app.terminate() }

        let more = app.navigationBars.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 30), "the pushed agent chat opens\n\(app.debugDescription)")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "capture starts with the keyboard down")

        // Check the running gate through a real menu action, without changing it.
        more.tap()
        let stop = app.buttons["Stop Agent"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "the chat's Stop Agent action is present")
        XCTAssertTrue(stop.isEnabled, "the fixture must activate AgentChatStore.isRunning")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.45)).tap()
        expect(stop, "exists == false", "dismiss the menu before capturing")

        let jump = app.buttons["Jump to bottom"].firstMatch
        expect(jump, "exists == false", "history initially follows the newest turn")

        // A real downward transcript drag reveals older history. This exceeds the
        // 120 pt show threshold; appearance proves actual scrollable distance, since
        // the production rule clamps rubber-banding out of that measurement.
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        XCTAssertGreaterThan(to.screenPoint.y - from.screenPoint.y, 120)
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0)
        expect(jump, "exists == true AND hittable == true", "scrolling away reveals the jump control")
        attach(app, "jump-working-scrolled-away")

        jump.tap()
        expect(jump, "exists == false", "jump returns to the bottom and hides the control")
        attach(app, "jump-returned-to-bottom")
    }

    @MainActor
    private func expect(_ element: XCUIElement, _ predicate: String, _ message: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 10), .completed, message)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
