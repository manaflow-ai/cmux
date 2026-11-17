import XCTest

/// The user, 2026-11-11 (iPhone): "ios chief recorded audio in composer bar
/// disappears when i background the app and return". Coming back from the
/// background, Chief's link reconnects and its screen is rebuilt on a new
/// store; the typed text went to the new screen, the recording did not, so
/// the review strip was gone and the clip with it.
///
/// Each test records on the real Chief screen (mock sign-in, synthetic
/// microphone), leaves the app and comes back, in dark and in light:
/// - a recording stopped for review is still in review, same length;
/// - a recording still running is stopped into review, nothing lost;
/// - a recording in review survives the app being killed in the background
///   and launched again.
final class ChiefVoiceDraftUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.appearance = .dark
    }

    @MainActor
    func testTheReviewSurvivesTheBackground() throws {
        for look in [XCUIDevice.Appearance.dark, .light] {
            XCUIDevice.shared.appearance = look
            let app = launch(look)
            let length = recordToReview(app, look: look)
            attach(app, "\(look.name)-1-review")
            for trip in 1...2 {
                background(app, trip: trip)
                assertReview(app, length: length, "after background trip \(trip)")
                attach(app, "\(look.name)-2-back-\(trip)")
            }
            sendAndCheck(app, look: look)
            app.terminate()
        }
    }

    @MainActor
    func testARunningRecordingStopsIntoTheReviewInTheBackground() throws {
        for look in [XCUIDevice.Appearance.dark, .light] {
            XCUIDevice.shared.appearance = look
            let app = launch(look)
            startRecording(app)
            let timer = app.staticTexts["conversation.recording.time"]
            XCTAssertTrue(wait(for: timer, "NOT (label IN {'0:00', '0:01'})", timeout: 10), "recording: \(timer.label)")
            attach(app, "\(look.name)-1-recording")
            let reached = Self.seconds(timer.label)
            background(app, trip: 1)
            let more = app.buttons["conversation.recording.continue"]
            XCTAssertTrue(wait(for: app.buttons["conversation.recording.send"], "hittable == true", timeout: 10),
                          "the running recording came back as a review\n\(app.debugDescription)")
            attach(app, "\(look.name)-2-back")
            let kept = Self.seconds((more.value as? String) ?? "0:00")
            XCTAssertGreaterThanOrEqual(kept, reached, "nothing recorded before the background was lost")
            // It records on from there.
            more.tap()
            XCTAssertTrue(wait(for: app.buttons["conversation.recording.stop"], "hittable == true", timeout: 5), "records more")
            attach(app, "\(look.name)-3-recording-more")
            app.buttons["conversation.recording.stop"].tap()
            XCTAssertTrue(wait(for: app.buttons["conversation.recording.send"], "hittable == true", timeout: 5))
            XCTAssertGreaterThan(Self.seconds((more.value as? String) ?? "0:00"), kept, "continued on top of the kept audio")
            attach(app, "\(look.name)-4-review")
            sendAndCheck(app, look: look)
            app.terminate()
        }
    }

    @MainActor
    func testTheReviewSurvivesARelaunch() throws {
        for look in [XCUIDevice.Appearance.dark, .light] {
            XCUIDevice.shared.appearance = look
            var app = launch(look)
            let length = recordToReview(app, look: look)
            // The system ends an app in the background (memory, or swiped away
            // in the switcher): it always got there through the background.
            XCUIDevice.shared.press(.home)
            XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10), "in the background")
            app.terminate()
            app = launch(look, clearingDrafts: false)
            XCTAssertTrue(wait(for: app.buttons["conversation.recording.send"], "hittable == true", timeout: 30),
                          "the review is back after a relaunch\n\(app.debugDescription)")
            assertReview(app, length: length, "after a relaunch")
            attach(app, "\(look.name)-2-relaunched")
            // The x throws it away for good: the next launch has no recording.
            app.buttons["conversation.composer.plus"].tap()
            XCTAssertTrue(wait(for: app.buttons["conversation.recording.send"], "exists == false", timeout: 5), "x discards")
            XCUIDevice.shared.press(.home)
            XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
            app.terminate()
            app = launch(look, clearingDrafts: false)
            XCTAssertTrue(app.buttons["conversation.composer.record"].waitForExistence(timeout: 30))
            XCTAssertFalse(app.buttons["conversation.recording.send"].waitForExistence(timeout: 3), "a discarded recording stays gone")
            attach(app, "\(look.name)-3-discarded-relaunch")
            app.terminate()
        }
    }

    // MARK: Steps

    @MainActor
    private func launch(_ look: XCUIDevice.Appearance, clearingDrafts: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        // Each test starts with no kept recording; a relaunch inside a test keeps it.
        if clearingDrafts { app.launchEnvironment["CMUX_UITEST_CLEAR_AUDIO_DRAFTS"] = "1" }
        app.launchEnvironment["CMUX_CONVERSATION_AUDIO_INPUT"] = "synthetic"
        // The app draws in its own appearance setting, not only the system's.
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmuxMobile.settings.appearance", look.name,
                                "-cmux-mobile-demo", "chief-open"]
        app.launch()
        return app
    }

    @MainActor
    private func startRecording(_ app: XCUIApplication) {
        let record = app.buttons["conversation.composer.record"]
        XCTAssertTrue(record.waitForExistence(timeout: 30), "record button\n\(app.debugDescription)")
        XCTAssertTrue(wait(for: record, "isEnabled == true", timeout: 30), "record button enabled")
        record.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["conversation.recording.stop"].waitForExistence(timeout: 5), "hold records")
    }

    /// Records about three seconds and stops into the review; returns its length.
    @MainActor
    private func recordToReview(_ app: XCUIApplication, look: XCUIDevice.Appearance) -> Int {
        startRecording(app)
        let timer = app.staticTexts["conversation.recording.time"]
        XCTAssertTrue(wait(for: timer, "NOT (label IN {'0:00', '0:01', '0:02'})", timeout: 10), "recording: \(timer.label)")
        attach(app, "\(look.name)-0-recording")
        app.buttons["conversation.recording.stop"].tap()
        let send = app.buttons["conversation.recording.send"]
        XCTAssertTrue(wait(for: send, "hittable == true", timeout: 5), "review")
        return Self.seconds((app.buttons["conversation.recording.continue"].value as? String) ?? "0:00")
    }

    @MainActor
    private func background(_ app: XCUIApplication, trip: Int) {
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10), "in the background (trip \(trip))")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "back in front (trip \(trip))")
    }

    @MainActor
    private func assertReview(_ app: XCUIApplication, length: Int, _ when: String) {
        let send = app.buttons["conversation.recording.send"]
        XCTAssertTrue(wait(for: send, "hittable == true", timeout: 10), "the recording's review is still there \(when)\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["conversation.recording.play"].isHittable, "play \(when)")
        let more = app.buttons["conversation.recording.continue"]
        XCTAssertEqual(Self.seconds((more.value as? String) ?? "0:00"), length, "same length \(when)")
        XCTAssertEqual(app.buttons["conversation.composer.plus"].label, "Cancel Recording", "the + is still the x \(when)")
    }

    /// The kept recording sends as an audio message.
    @MainActor
    private func sendAndCheck(_ app: XCUIApplication, look: XCUIDevice.Appearance) {
        app.buttons["conversation.recording.send"].tap()
        XCTAssertTrue(wait(for: app.buttons["conversation.recording.send"], "exists == false", timeout: 5), "sent")
        attach(app, "\(look.name)-9-sent")
    }

    /// "0:07" or "+ 0:07" as seconds.
    static func seconds(_ label: String) -> Int {
        let clock = label.split(separator: " ").last.map(String.init) ?? label
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return 0 }
        return parts[0] * 60 + parts[1]
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

private extension XCUIDevice.Appearance {
    var name: String { self == .light ? "light" : "dark" }
}
