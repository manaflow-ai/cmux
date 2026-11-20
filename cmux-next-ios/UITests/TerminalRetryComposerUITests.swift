import XCTest

/// A pending terminal keeps its recovery action available while a person is
/// composing: Send remains the trailing action and Retry stays beside it.
final class TerminalRetryComposerUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testRetryStaysAlongsideDraftAndSend() throws {
        let normal = XCUIApplication()
        normal.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        normal.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore", "-cmux-mobile-demo", "ws-terminal-idle"]
        normal.launch()
        let normalField = normal.textViews["terminal.composer.field"]
        XCTAssertTrue(normalField.waitForExistence(timeout: 20), "normal terminal composer\n\(normal.debugDescription)")
        waitUntilHittable(normalField)
        let normalFieldHeight = normalField.frame.height
        let normalSend = normal.buttons["terminal.composer.send"]
        XCTAssertTrue(normalSend.waitForExistence(timeout: 5), "normal Send control\n\(normal.debugDescription)")
        let normalSendHeight = normalSend.frame.height
        XCTAssertGreaterThan(normalFieldHeight, 0, "the normal field is laid out")
        XCTAssertGreaterThan(normalSendHeight, 0, "the normal Send control is laid out")
        normal.terminate()

        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore", "-cmux-mobile-demo", "retry-terminal"]
        app.launch()
        defer { app.terminate() }

        let retry = app.buttons["terminal.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 30), "pending terminal exposes Retry\n\(app.debugDescription)")
        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "terminal composer\n\(app.debugDescription)")
        waitUntilHittable(field)
        waitUntilHittable(retry)
        XCTAssertGreaterThan(retry.frame.height, 0, "Retry must be visible, not only present in accessibility")
        XCTAssertEqual(field.frame.height, normalFieldHeight, accuracy: 1,
                       "empty Retry keeps the normal composer height")
        XCTAssertLessThanOrEqual(retry.frame.height, normalSendHeight + 1,
                                 "empty Retry matches the normal Send control height")
        attach(app, "empty-retry")

        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "tapping the visible composer opens the keyboard")
        field.typeText("keep this draft")
        let send = app.buttons["terminal.composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "Send returns for a populated draft\n\(app.debugDescription)")
        XCTAssertTrue(retry.exists, "Retry remains beside Send\n\(app.debugDescription)")
        XCTAssertEqual(field.frame.height, normalFieldHeight, accuracy: 1,
                       "populated Retry + Send keep the normal composer height")
        XCTAssertLessThanOrEqual(retry.frame.height, normalSendHeight + 1,
                                 "populated Retry matches the normal Send control height")
        attach(app, "draft-with-retry-and-send")

        send.press(forDuration: 1.0)
        let withoutReturn = app.buttons.matching(NSPredicate(format: "label == 'Send without Return'")).firstMatch
        XCTAssertTrue(withoutReturn.waitForExistence(timeout: 5), "Send context action remains available\n\(app.debugDescription)")
        XCTAssertEqual(field.value as? String, "keep this draft", "the draft remains while Send's context menu is open")
        attach(app, "send-context-menu")
    }

    @MainActor
    func testSwitcherRetryCardShowsFailedTurn() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore", "-cmux-mobile-demo", "switcher-retry"]
        app.launch()
        defer { app.terminate() }

        let card = app.buttons.matching(NSPredicate(format: "label == 'Refactor transport layer, tab'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30), "failed-turn tab card\n\(app.debugDescription)")
        attach(app, "failed-turn-grid-card")

        card.tap()
        XCTAssertTrue(app.staticTexts["Agent stopped"].waitForExistence(timeout: 10),
                      "failed-turn card opens its failure state\n\(app.debugDescription)")
        attach(app, "failed-turn-chat-card")
    }

    @MainActor
    private func waitUntilHittable(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed,
                       "the control must be on screen and accept a tap: \(element.debugDescription)")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
