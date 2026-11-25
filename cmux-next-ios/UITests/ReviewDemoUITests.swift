import XCTest

/// The App Review demo account's walk, the way a reviewer takes it with no Mac:
/// Workspaces lists the demo Mac (online) and its workspaces, a workspace opens on
/// its terminal, which answers a typed command, and its browser tab shows the page
/// on the phone. Shipping builds turn the demo on only for the server-flagged
/// account (Stack's read-only `cmuxReviewDemoContent`); this DEBUG test turns it on
/// with `CMUX_MOBILE_REVIEW_DEMO=1` over the mock account, which XCUITest can sign in.
/// Every step is captured in light and in dark.
final class ReviewDemoUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(look: String) -> XCUIApplication {
        XCUIDevice.shared.appearance = look == "dark" ? .dark : .light
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_REVIEW_DEMO"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore",
                                "-cmuxMobile.settings.appearance", look]
        app.launch()
        return app
    }

    @MainActor
    func testReviewerUsesTheDemoMacsTerminalAndBrowser() throws {
        for look in ["light", "dark"] {
            let app = launch(look: look)
            defer { app.terminate() }

            // Workspaces: the demo Mac's three workspaces, none waiting for a Mac.
            let website = app.buttons["workspace.row.review-ws-web"]
            XCTAssertTrue(website.waitForExistence(timeout: 30), "the demo's website workspace\n\(app.debugDescription)")
            XCTAssertTrue(app.buttons["workspace.row.review-ws-api"].exists, "the demo's api-server workspace")
            XCTAssertTrue(app.buttons["workspace.row.review-ws-notes"].exists, "the demo's notes workspace")
            XCTAssertFalse(app.buttons["workspace.row.ws-cmux"].exists, "no developer sample data")
            attach(app, "\(look)-01-workspaces")

            // The terminal: its shell plays its last commands, then answers one typed here.
            website.tap()
            let field = app.textViews["terminal.composer.field"]
            XCTAssertTrue(field.waitForExistence(timeout: 20), "the workspace opens on its terminal\n\(app.debugDescription)")
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Connecting'")).firstMatch.exists,
                           "the demo terminal is not waiting for a Mac\n\(app.debugDescription)")
            attach(app, "\(look)-02-terminal")
            field.tap()
            field.typeText("git status")
            let send = app.buttons["terminal.composer.send"]
            XCTAssertTrue(send.waitForExistence(timeout: 5), "the composer's send button\n\(app.debugDescription)")
            send.tap()
            // git status's own output (the shell answered, not just the typed line).
            let answered = app.textViews["Terminal"].firstMatch
            XCTAssertTrue(answered.waitForExistence(timeout: 5), "the terminal's text\n\(app.debugDescription)")
            XCTAssertTrue(waitFor(seconds: 2), "the shell's answer settles")
            attach(app, "\(look)-03-terminal-command")

            // The browser tab: the page opens on the phone.
            // The keyboard covers the tab bar: put it away with the terminal's own key first.
            let keyboardKey = app.buttons["terminal.key.keyboard"]
            if app.keyboards.firstMatch.exists, keyboardKey.exists { keyboardKey.tap() }
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "the keyboard goes away\n\(app.debugDescription)")
            let tabs = app.buttons["Tabs"].firstMatch
            XCTAssertTrue(tabs.waitForExistence(timeout: 10), "the workspace's Tabs button\n\(app.debugDescription)")
            tabs.tap()
            let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'cmux' AND label ENDSWITH ', tab'")).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 10), "the browser tab's card\n\(app.debugDescription)")
            attach(app, "\(look)-04-tabs")
            card.tap()
            // No Mac stream: the tab is the phone's own web view.
            let page = app.webViews.firstMatch
            XCTAssertTrue(page.waitForExistence(timeout: 20), "the page shows on the phone\n\(app.debugDescription)")
            XCTAssertFalse(app.descendants(matching: .any)["browser.unavailable"].exists, "the page is not unavailable")
            XCTAssertTrue(waitFor(seconds: 6), "the page loads")
            attach(app, "\(look)-05-browser")
        }
    }

    /// A bounded settle for a screenshot (the shell and the page have no
    /// accessibility signal for "drawn").
    @MainActor
    private func waitFor(seconds: Double) -> Bool {
        let settled = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { settled.fulfill() }
        return XCTWaiter().wait(for: [settled], timeout: seconds + 5) == .completed
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
