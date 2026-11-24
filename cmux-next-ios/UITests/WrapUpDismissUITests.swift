import XCTest

/// The turn's summary card (the agent's wrap-up recap) closes with its × and stays closed when the
/// app opens the chat again (#51353): before, the phone drew it with no way to dismiss it.
/// Attaches a screenshot of each step, the evidence for the PR.
final class WrapUpDismissUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTheSummaryCardDismissesAndStaysGoneAfterRelaunch() {
        XCUIDevice.shared.orientation = .portrait
        // The first launch clears dismissals an earlier run kept; the relaunch keeps them.
        let app = Self.launch(reset: true)

        let card = app.descendants(matching: .any)["agentChat.nextStep"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30), "the summary card shows under the last answer\n\(app.debugDescription)")
        let recap = app.descendants(matching: .any)["agentChat.nextStep.recap"].firstMatch
        XCTAssertTrue(recap.exists, "the card holds the recap")
        attach(app, "1-card-with-x")

        let close = app.buttons["agentChat.nextStep.dismiss"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), "the card has a ×\n\(app.debugDescription)")
        XCTAssertEqual(close.label, "Dismiss")
        close.tap()
        expect(card, "exists == false", "the × removes the card")
        attach(app, "2-dismissed")

        // Opened again: the dismissal was kept on the phone, so the card stays gone.
        app.terminate()
        let again = Self.launch()
        defer { again.terminate() }
        let more = again.navigationBars.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 30), "the chat opens again\n\(again.debugDescription)")
        let answer = again.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "signal_due")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 20), "the answer above the card is there\n\(again.debugDescription)")
        XCTAssertFalse(again.descendants(matching: .any)["agentChat.nextStep"].firstMatch.exists,
                       "the dismissed card stays gone after a relaunch\n\(again.debugDescription)")
        attach(again, "3-after-relaunch")
    }

    @MainActor
    private static func launch(reset: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "wrap-up-chat"]
        if reset { app.launchArguments.append("-cmux-mobile-reset-wrap-up-dismissals") }
        app.launch()
        return app
    }

    private func expect(_ element: XCUIElement, _ format: String, _ message: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 10), .completed, message)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
