import XCTest

/// A pending terminal keeps its recovery action available while a person is
/// composing: Send remains the trailing action and Retry stays beside it.
final class TerminalRetryComposerUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testRetryStaysAlongsideDraftAndSend() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore", "-cmux-mobile-demo", "retry-terminal"]
        app.launch()
        defer { app.terminate() }

        let retry = app.buttons["terminal.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 30), "pending terminal exposes Retry\n\(app.debugDescription)")
        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "terminal composer\n\(app.debugDescription)")
        attach(app, "empty-retry")

        field.tap()
        field.typeText("keep this draft")
        let send = app.buttons["terminal.composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "Send returns for a populated draft\n\(app.debugDescription)")
        XCTAssertTrue(retry.exists, "Retry remains beside Send\n\(app.debugDescription)")
        attach(app, "draft-with-retry-and-send")

        send.press(forDuration: 1.0)
        let withoutReturn = app.buttons.matching(NSPredicate(format: "label == 'Send without Return'")).firstMatch
        XCTAssertTrue(withoutReturn.waitForExistence(timeout: 5), "Send context action remains available\n\(app.debugDescription)")
        XCTAssertEqual(field.value as? String, "keep this draft", "the draft remains while Send's context menu is open")
        attach(app, "send-context-menu")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
