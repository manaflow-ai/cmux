import XCTest

/// The Chief composer's record button behaves as Messages' does on iOS 26
/// (`ComposerAudioFlow`): a tap only shows "Tap and hold to record and send
/// audio"; a hold records and keeps recording after the finger lifts; stop
/// opens the review ("x", play, waveform, "+ 0:0N", send); the pill records
/// more and "x" throws the recording away. Real touches on the real Chief
/// screen (mock sign-in, synthetic microphone).
final class ChiefVoiceRecordUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTapHintsHoldRecordsAndLocks() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_CONVERSATION_AUDIO_INPUT"] = "synthetic"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "chief-open"]
        app.launch()

        let record = app.buttons["conversation.composer.record"]
        XCTAssertTrue(record.waitForExistence(timeout: 30), "record button\n\(app.debugDescription)")
        XCTAssertTrue(wait(for: record, "isEnabled == true", timeout: 30), "record button enabled once Chief takes sends")
        attach(app, "1-rest")

        // A tap: the hint, no recording.
        record.tap()
        let hint = app.staticTexts["conversation.recording.holdHint"]
        XCTAssertTrue(hint.waitForExistence(timeout: 3), "tap shows the hold hint")
        XCTAssertEqual(hint.label, "Tap and hold to record and send audio")
        XCTAssertFalse(app.buttons["conversation.recording.stop"].exists, "a tap does not record")
        attach(app, "2-tap-hint")

        // A hold records; lifting the finger keeps it recording.
        record.press(forDuration: 1.2)
        let stop = app.buttons["conversation.recording.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "hold records")
        let timer = app.staticTexts["conversation.recording.time"]
        XCTAssertTrue(wait(for: timer, "NOT (label IN {'0:00', '0:01'})", timeout: 10), "still recording after the finger lifted: \(timer.label)")
        let reviewSend = app.buttons["conversation.recording.send"]
        XCTAssertFalse(reviewSend.exists && reviewSend.isHittable, "no review while recording")
        attach(app, "3-recording-locked")

        // Stop: the review strip.
        stop.tap()
        let send = app.buttons["conversation.recording.send"]
        let more = app.buttons["conversation.recording.continue"]
        XCTAssertTrue(wait(for: send, "hittable == true", timeout: 5), "review shows send")
        XCTAssertTrue(more.isHittable, "review shows the + pill")
        // Messages' sizes (ComposerAudioLayout): play 34.33 pt, send 38 x 28.
        let play = app.buttons["conversation.recording.play"]
        XCTAssertEqual(play.frame.width, 34.33, accuracy: 1, "play circle size")
        XCTAssertEqual(send.frame.width, 38, accuracy: 1, "send capsule width")
        XCTAssertEqual(send.frame.height, 28, accuracy: 1, "send capsule height")
        XCTAssertTrue(more.label.contains("Continue Recording"))
        XCTAssertEqual(app.buttons["conversation.composer.plus"].label, "Cancel Recording", "the + became an x")
        attach(app, "4-review")

        // "+ 0:0N" records more from where it stopped; stop returns to the review.
        let recorded = (more.value as? String) ?? "0:00"
        more.tap()
        XCTAssertTrue(wait(for: stop, "hittable == true", timeout: 5), "the pill records more")
        XCTAssertTrue(wait(for: timer, "label > '\(recorded)'", timeout: 10), "recording continues past \(recorded): \(timer.label)")
        attach(app, "5-recording-more")
        stop.tap()
        XCTAssertTrue(wait(for: send, "hittable == true", timeout: 5))

        // Play, then the x throws it away.
        app.buttons["conversation.recording.play"].tap()
        attach(app, "6-review-playing")
        app.buttons["conversation.composer.plus"].tap()
        XCTAssertTrue(wait(for: app.buttons["conversation.recording.send"], "exists == false", timeout: 5), "x discards the recording")
        XCTAssertEqual(app.buttons["conversation.composer.plus"].label, "Apps")
        attach(app, "7-discarded")

        // Hold, lift, stop, send: the audio message lands in the transcript.
        record.press(forDuration: 1.2)
        XCTAssertTrue(wait(for: timer, "NOT (label IN {'0:00', '0:01'})", timeout: 10))
        stop.tap()
        XCTAssertTrue(wait(for: send, "hittable == true", timeout: 5))
        send.tap()
        XCTAssertTrue(wait(for: app.buttons["conversation.recording.send"], "exists == false", timeout: 5), "send returns to the text field")
        attach(app, "8-sent")
    }

    private func wait(for element: XCUIElement, _ predicate: String, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
