import XCTest

/// Chief's reply thread behaves like Messages' (verify/imsg-replies): the
/// thread is its own transcript, so my reply in it shows its delivery
/// status even though the main transcript, where Chief wrote after it,
/// shows none; the send button reads "Send Reply" while replying; and a
/// sent reply joins the open thread, which stays open in reply mode. Real
/// touches on the mock Chief (mock sign-in): its history has my "🙌 thanks"
/// (read) replying to Chief's TabsKit message, with Chief's heads-up after.
final class ReplyThreadUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testReplyThreadShowsItsOwnStatusAndSendsAReply() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "chief-open"]
        app.launch()

        let field = app.textViews["conversation.composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "Chief's composer\n\(app.debugDescription)")
        // Chief's message after mine takes the status away in the main transcript.
        let reply = app.cells["conversation.message.msg_local_7"]
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "my \"🙌 thanks\" reply\n\(app.debugDescription)")
        XCTAssertFalse(reply.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Read")).firstMatch.exists,
                       "no status under my reply in the main transcript")
        // Its quote of Chief's message opens the thread.
        let quote = reply.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Claude finished the TabsKit")).firstMatch
        XCTAssertTrue(quote.waitForExistence(timeout: 5), "the quote above my reply\n\(reply.debugDescription)")
        quote.tap()

        let thread = app.otherElements["conversation.replyThread"]
        XCTAssertTrue(thread.waitForExistence(timeout: 5), "the reply thread opens")
        // In the thread my reply is the last message: Messages shows its status there.
        let status = thread.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Read")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5), "my message in the thread keeps its status\n\(thread.debugDescription)")
        attach(app, "thread")

        let send = app.buttons["conversation.composer.send"]
        if !field.hasKeyboardFocus { field.tap() }
        field.typeText("On it")
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertEqual(send.label, "Send Reply", "the send button names what it sends while replying")
        attach(app, "draft")

        send.tap()
        let sent = thread.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "On it")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 5), "the reply joins the open thread\n\(thread.debugDescription)")
        XCTAssertTrue(thread.exists, "the thread stays open after a reply is sent")
        // Reply mode keeps the header's X (XCUITest doesn't expose a text view's placeholder).
        XCTAssertEqual(app.buttons["conversation.header.trailing"].label, "Close", "the composer stays in reply mode")
        attach(app, "sent")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

private extension XCUIElement {
    var hasKeyboardFocus: Bool { (value(forKey: "hasKeyboardFocus") as? Bool) ?? false }
}
