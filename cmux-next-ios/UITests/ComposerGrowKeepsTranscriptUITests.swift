import XCTest

/// User report 2026-11-12 (iPhone, agent chat): with the transcript scrolled up, a newline in the
/// composer moved the transcript; every line the composer grew or lost shifted what the reader
/// was looking at. A reader scrolled up keeps their view while the composer changes height (the
/// taller composer covers more of the bottom, as in Messages); a reader on the newest turn still
/// sees it ride above the composer.
final class ComposerGrowKeepsTranscriptUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testScrolledUpTranscriptStaysPutWhileComposerGrows() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "kbd-chat"]
        app.launch()
        defer { app.terminate() }

        let field = app.textViews["chat.composer.field"]
        if !field.waitForExistence(timeout: 30) { app.buttons["Reply to Claude"].firstMatch.tap() }
        XCTAssertTrue(field.waitForExistence(timeout: 10), "chat composer field\n\(app.debugDescription)")
        if !app.keyboards.firstMatch.exists { field.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the keyboard comes up")
        field.typeText("one")

        // Scroll up with a drag that stays above the composer (one that reaches it takes the
        // keyboard down).
        let jump = app.buttons["Jump to bottom"].firstMatch
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(jump.waitForExistence(timeout: 10), "scrolled away from the newest turn")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "the keyboard stays up")
        attach(app, "scrolled-up-1-line")

        let before = visibleRows(app)
        XCTAssertFalse(before.isEmpty, "rows to watch in the transcript\n\(app.debugDescription)")
        let oneLine = field.frame

        // Grow three lines, then take them back.
        for _ in 0..<3 { field.typeText("\nanother line") }
        let grown = field.frame
        XCTAssertGreaterThan(grown.height, oneLine.height + 20, "the composer grew")
        attach(app, "scrolled-up-4-lines")
        assertSame(before, visibleRows(app), "after the composer grew three lines")

        for _ in 0..<("\nanother line".count * 3) { field.typeText(XCUIKeyboardKey.delete.rawValue) }
        XCTAssertEqual(field.frame.height, oneLine.height, accuracy: 1, "the composer is one line again")
        attach(app, "scrolled-up-back-to-1-line")
        assertSame(before, visibleRows(app), "after the composer shrank back")
    }

    /// The other half: a reader on the newest turn keeps seeing it, riding above the taller composer.
    @MainActor
    func testFollowingTranscriptRidesAboveGrowingComposer() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "kbd-chat"]
        app.launch()
        defer { app.terminate() }

        let field = app.textViews["chat.composer.field"]
        if !field.waitForExistence(timeout: 30) { app.buttons["Reply to Claude"].firstMatch.tap() }
        XCTAssertTrue(field.waitForExistence(timeout: 10), "chat composer field\n\(app.debugDescription)")
        if !app.keyboards.firstMatch.exists { field.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the keyboard comes up")
        field.typeText("one")
        XCTAssertFalse(app.buttons["Jump to bottom"].firstMatch.exists, "following the newest turn")
        let before = lowestRowBottom(app, above: field.frame.minY)

        for _ in 0..<3 { field.typeText("\nanother line") }
        attach(app, "following-4-lines")
        let top = field.frame.minY
        let after = lowestRowBottom(app, above: top)
        XCTAssertFalse(app.buttons["Jump to bottom"].firstMatch.exists, "still following the newest turn")
        XCTAssertLessThan(after, before - 20, "the newest turn rose with the composer (\(before) -> \(after))")
        XCTAssertGreaterThan(after, top - 120, "the newest turn sits right above the composer (row \(after), composer \(top))")
    }

    /// The bottom of the lowest transcript text drawn above `limit` (screen y).
    @MainActor
    private func lowestRowBottom(_ app: XCUIApplication, above limit: CGFloat) -> CGFloat {
        app.collectionViews.firstMatch.staticTexts.allElementsBoundByIndex
            .map(\.frame).filter { $0.height > 0 && $0.maxY <= limit + 1 }
            .map(\.maxY).max() ?? 0
    }

    /// Transcript text elements in the middle of the screen (clear of the header and the
    /// composer), by label: their screen y.
    @MainActor
    private func visibleRows(_ app: XCUIApplication) -> [String: CGFloat] {
        let height = app.windows.firstMatch.frame.height
        var rows: [String: CGFloat] = [:]
        let texts = app.collectionViews.firstMatch.staticTexts.allElementsBoundByIndex
        for text in texts.prefix(60) {
            let frame = text.frame
            let label = text.label
            guard !label.isEmpty, frame.height > 0, frame.minY > height * 0.15, frame.maxY < height * 0.35 else { continue }
            rows[label] = frame.minY
        }
        return rows
    }

    @MainActor
    private func assertSame(_ before: [String: CGFloat], _ after: [String: CGFloat], _ when: String) {
        var compared = 0
        for (label, y) in before {
            guard let now = after[label] else { continue }
            compared += 1
            XCTAssertEqual(now, y, accuracy: 1, "\(when): \"\(label.prefix(40))\" moved from \(y) to \(now)")
        }
        XCTAssertGreaterThan(compared, 0, "\(when): the watched rows are still on screen (before \(before), after \(after))")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
