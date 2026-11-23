import XCTest

/// The picture for Lawrence's 2026-11-20 report ("this preview thing is not very good") on the phone: my reply to the
/// Chief's before/after table, with the quote above it and the table's bubble, on the mock Chief
/// (`-cmux-mobile-chief-markdown-quote`, through the real ChiefWire). A capture only: it checks that the reply drew;
/// `ChiefQuotePreviewTests` checks the words. The same file runs on the tree before the fix.
final class ChiefMarkdownQuoteCaptureUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testCaptureTheQuoteOfAMarkdownMessage() throws {
        for dark in [false, true] {
            XCUIDevice.shared.appearance = dark ? .dark : .light
            let app = XCUIApplication()
            app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
            app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "chief-open",
                                    "-cmux-mobile-chief-markdown-quote", "-cmuxMobile.settings.appearance", dark ? "dark" : "light"]
            app.launch()
            let field = app.textViews["conversation.composer.text"]
            XCTAssertTrue(field.waitForExistence(timeout: 30), "Chief's composer\n\(app.debugDescription)")
            let reply = app.cells["conversation.message.msg_local_11"]
            XCTAssertTrue(reply.waitForExistence(timeout: 15), "my reply to the table\n\(app.debugDescription)")
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = dark ? "chief-markdown-quote-dark" : "chief-markdown-quote-light"
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
        XCUIDevice.shared.appearance = .light
    }
}
