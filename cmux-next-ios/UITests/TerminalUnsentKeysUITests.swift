import XCTest

/// Leo, 2026-11-23: "that message is [nonsense] and should be removed. it shows up
/// even when you didnt type into the terminal... it even layout shifts... but
/// fundamentally, we want to/we arguably already have the state
/// management/lifecycle such that you dont need to worry about it. things just
/// work. send or not or you just kept it etc"
///
/// The `ws-terminal-outage` demo drops the link, has the session drop input the
/// person never typed on screen, brings the link back, then drops a composer
/// send in a second outage. Sampled through the whole run: the "not sent" row
/// never appears and the composer field never moves; the dropped send's text is
/// back in the composer.
final class TerminalUnsentKeysUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testAnOutageSaysNothingAndMovesNothing() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "ws-terminal-outage"]
        app.launch()
        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "composer field\n\(app.debugDescription)")
        let notice = app.descendants(matching: .any)["terminal.composer.notSent"]
        let unsentText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "not sent")).firstMatch

        // The demo opens the tab at ~1 s and drops the link at ~4 s: sample from
        // before the drop to after the second reattach (~13 s).
        Thread.sleep(forTimeInterval: 2.0)
        let restTop = field.frame.minY
        let restBottom = field.frame.maxY
        attach("1-attached")
        var samples = 0, noticeSamples = 0, shiftedSamples = 0, noticeShows = 0
        var showing = false
        var shots = 0
        let end = Date().addingTimeInterval(14)
        while Date() < end {
            samples += 1
            let shows = notice.exists || unsentText.exists
            if shows { noticeSamples += 1 }
            if shows, !showing { noticeShows += 1 }
            if shows, shots < 2 { shots += 1; attach("notice-\(shots)") }
            showing = shows
            let frame = field.frame
            // The composer's top grows with its draft ("make test" is one line, as is
            // the empty field); only its bottom and a one-line top count as a shift.
            if abs(frame.maxY - restBottom) > 0.5 || abs(frame.minY - restTop) > 0.5 { shiftedSamples += 1 }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        attach("2-after-outages")
        let summary = "samples=\(samples) notice_shows=\(noticeShows) notice_samples=\(noticeSamples) shifted_samples=\(shiftedSamples)"
        print("TerminalUnsentKeysUITests: \(summary)")
        let note = XCTAttachment(string: summary)
        note.name = "numbers"
        note.lifetime = .keepAlways
        add(note)
        XCTAssertEqual(noticeShows, 0, "a 'not sent' notice showed with nothing typed (\(summary))")
        XCTAssertEqual(shiftedSamples, 0, "the composer moved during the outage (\(summary))")
        // Rule: a composer send that never reached the Mac comes back to the composer, silently.
        XCTAssertEqual(field.value as? String, "make test", "the dropped send's text is back in the composer")
    }

    /// A draft in the composer survives the app going to the background and back, and
    /// nothing says "not sent" or warns about the draft (the tab's draft store,
    /// `GhosttyTerminalTabContent`'s `drafts`, keeps `draftToKeep` as it changes).
    @MainActor
    func testADraftSurvivesTheBackgroundWithNoWarning() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "ws-terminal-idle"]
        app.launch()
        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "composer field\n\(app.debugDescription)")
        field.tap()
        field.typeText("half a command")
        attach("1-draft")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
        app.activate()
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        attach("2-back")
        XCTAssertEqual(field.value as? String, "half a command", "the draft is still in the composer")
        XCTAssertFalse(app.descendants(matching: .any)["terminal.composer.notSent"].exists, "no not-sent row")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "not sent")).firstMatch.exists,
                       "no not-sent or draft warning")
    }

    @MainActor
    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
