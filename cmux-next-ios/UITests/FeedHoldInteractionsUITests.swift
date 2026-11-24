import XCTest

/// A hold on a Feed row works on its content, not the row (Aziz, 2026-11-23): on text it
/// selects the held word in place (the shared `InPlaceTextSelection`, its stand-in text view
/// `chat.inPlaceSelection`), with no lifted row, peek or row menu; on a link it shows Open Link
/// and Copy Link. The row's menu opens from its ••• button only. Run in light and dark; each
/// state is attached as a screenshot.
final class FeedHoldInteractionsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testHoldSelectsTextAndEllipsisOpensMenu() {
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            let mode = appearance == .dark ? "dark" : "light"
            let app = XCUIApplication()
            app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
            app.launchArguments += ["-cmux-mobile-tab", "feed", "-cmux-mobile-no-restore",
                                    "-cmuxMobile.setupComplete", "YES", "-cmuxMobile.settings.appearance", mode]
            app.launch()
            let choose = app.scrollViews["setup.teams.choose"]
            if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }
            let list = app.tables["feed.list"]
            XCTAssertTrue(list.waitForExistence(timeout: 30), "the Feed's table\n\(app.debugDescription)")
            let selection = app.textViews["chat.inPlaceSelection"]

            // Agent text: a hold selects the word, and the row's menu does not open.
            let pricing = list.cells["feed.row.f-pricing"]
            reveal(pricing, in: list)
            attach(app, "\(mode)-feed")
            let paragraph = pricing.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Fixed the pricing'")).firstMatch
            XCTAssertTrue(paragraph.waitForExistence(timeout: 5), "the agent's text\n\(app.debugDescription)")
            paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.25)).press(forDuration: 1.0)
            XCTAssertTrue(selection.waitForExistence(timeout: 5), "a hold on agent text selects in place\n\(app.debugDescription)")
            XCTAssertFalse(app.buttons["Mark as Read"].exists || app.buttons["Mark as Unread"].exists, "no row menu on a hold")
            XCTAssertFalse(app.buttons["Open Tab"].exists, "no row menu on a hold")
            attach(app, "\(mode)-hold-agent-text")
            dismiss(selection, in: app)

            // The person's message (the quote): selects in place too.
            let quote = pricing.staticTexts.matching(NSPredicate(format: "label CONTAINS 'pricing page breaks'")).firstMatch
            if quote.exists {
                quote.press(forDuration: 1.0)
                XCTAssertTrue(selection.waitForExistence(timeout: 5), "a hold on the person's message selects\n\(app.debugDescription)")
                attach(app, "\(mode)-hold-user-message")
                dismiss(selection, in: app)
            }

            // A code block.
            let code = pricing.staticTexts.matching(NSPredicate(format: "label CONTAINS 'grid-template-columns'")).firstMatch
            if code.exists {
                code.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).press(forDuration: 1.0)
                XCTAssertTrue(selection.waitForExistence(timeout: 5), "a hold on code selects\n\(app.debugDescription)")
                attach(app, "\(mode)-hold-code-block")
                dismiss(selection, in: app)
            }

            // The ••• button is the row's menu.
            pricing.buttons["Event actions"].tap()
            XCTAssertTrue(app.buttons["Open Tab"].waitForExistence(timeout: 5), "••• opens the row's menu\n\(app.debugDescription)")
            attach(app, "\(mode)-ellipsis-menu")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
            XCTAssertTrue(waitGone(app.buttons["Open Tab"]), "the menu closes")

            // A failed event's card text.
            let failed = list.cells["feed.row.f-failed"]
            reveal(failed, in: list)
            let failedText = failed.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'The e2e job failed'")).firstMatch
            XCTAssertTrue(failedText.waitForExistence(timeout: 5), "the failed card's text\n\(app.debugDescription)")
            failedText.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.25)).press(forDuration: 1.0)
            if !selection.waitForExistence(timeout: 3) {
                // Once more if the first hold landed while the list still settled.
                failedText.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.25)).press(forDuration: 1.2)
            }
            XCTAssertTrue(selection.waitForExistence(timeout: 5), "a hold on a failed card selects\n\(app.debugDescription)")
            attach(app, "\(mode)-hold-failed-card")
            dismiss(selection, in: app)

            // A link: Open Link and Copy Link, no selection.
            let linked = list.cells["feed.row.f-agent-quote"]
            reveal(linked, in: list)
            let linkText = linked.staticTexts.matching(NSPredicate(format: "label CONTAINS 'redirect docs'")).firstMatch
            XCTAssertTrue(linkText.waitForExistence(timeout: 5), "the linked text\n\(app.debugDescription)")
            linkText.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.85)).press(forDuration: 1.0)
            if app.buttons["Copy Link"].waitForExistence(timeout: 3) {
                XCTAssertTrue(app.buttons["Open Link"].exists, "Open Link beside Copy Link")
                attach(app, "\(mode)-hold-link")
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
                _ = waitGone(app.buttons["Copy Link"])
            } else {
                // The press missed the link's glyphs: it selected the text instead (still no row menu).
                XCTAssertFalse(app.buttons["Open Tab"].exists, "no row menu on a hold")
                attach(app, "\(mode)-hold-link-missed")
                dismiss(selection, in: app)
            }
            app.terminate()
        }
    }

    @MainActor private func dismiss(_ selection: XCUIElement, in app: XCUIApplication) {
        // A tap elsewhere clears the selection (and opens nothing).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        XCTAssertTrue(waitGone(selection), "a tap outside clears the selection\n\(app.debugDescription)")
    }

    /// Scrolls the list with slow swipes until `cell` starts in its upper part.
    @MainActor private func reveal(_ cell: XCUIElement, in list: XCUIElement) {
        for _ in 0..<12 {
            let top = list.frame.minY + 100, limit = list.frame.minY + list.frame.height * 0.45
            if cell.exists, cell.frame.minY >= top, cell.frame.minY <= limit {
                // Let the list stop coasting: a hold on a moving list is the scroll's, not a hold.
                Thread.sleep(forTimeInterval: 1.0)
                return
            }
            if cell.exists, cell.frame.minY < top { list.swipeDown(velocity: .slow) } else { list.swipeUp(velocity: .slow) }
        }
    }

    @MainActor private func waitGone(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
