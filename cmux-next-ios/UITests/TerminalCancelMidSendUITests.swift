import XCTest

/// Stop partway through a send (#53651, Leo's attachment-send work, gcp-agent-lane-13/ios-attachment-send:
/// "Start a large video upload from the composer, tap Stop partway through, and assert two things: the
/// composer can be edited in the same frame, and no message is sent").
///
/// `-cmux-mobile-demo ws-terminal-cancel-send` puts a draft and a 412 MB video in the zsh tab's composer,
/// carried by a demo upload queue whose bytes take 12 s to move. The test taps Send (it turns into Stop
/// while the send waits for the video), taps Stop a few seconds in, and checks at once that Stop is Send
/// again and the field takes typing; then it waits past the moment the video reaches the Mac and checks
/// that nothing went: the draft (with the new typing) and the video are still in the composer, which a
/// send clears (TerminalModel.finishAttachmentSend is the only way out).
final class TerminalCancelMidSendUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testStopPartwayFreesTheComposerAndSendsNothing() throws {
        XCUIDevice.shared.orientation = .portrait
        let uploadSeconds = 12.0
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_DEMO_UPLOAD_SECONDS"] = String(uploadSeconds)
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "ws-terminal-cancel-send"]
        app.launch()
        defer { app.terminate() }

        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "composer field\n\(app.debugDescription)")
        let draft = "What happens in this clip?"
        XCTAssertTrue(waitFor(timeout: 10) { (field.value as? String) == draft }, "the demo draft is in the field: \(String(describing: field.value))")
        let tile = app.descendants(matching: .any)["terminal.attachment"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "the video's tile is in the tray\n\(app.debugDescription)")
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the keyboard comes up")

        let send = app.buttons["terminal.composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertEqual(send.label, "Send")
        let sentAt = Date()
        send.tap()
        XCTAssertTrue(waitFor(timeout: 3) { send.label == "Cancel sending" }, "Send turns into Stop while the video uploads: \(send.label)")
        attach(app, "sending")

        // Partway: a few seconds into a 12 s upload. Stop still showing proves the send is waiting.
        Thread.sleep(forTimeInterval: max(0, 3 - Date().timeIntervalSince(sentAt)))
        let uploading = app.descendants(matching: .any)["Uploading"].firstMatch
        let percent = uploading.exists ? (uploading.value as? String ?? "?") : "badge not exposed"
        XCTAssertEqual(send.label, "Cancel sending", "still sending when Stop is tapped")
        let stoppedAfter = Date().timeIntervalSince(sentAt)
        send.tap()

        // The same frame: no wait before these reads.
        XCTAssertEqual(send.label, "Send", "Stop is Send again at once")
        XCTAssertTrue(field.isHittable, "the field takes touches at once")
        if !app.keyboards.firstMatch.exists { field.tap() }
        field.typeText(" Frame by frame")
        XCTAssertEqual(field.value as? String, draft + " Frame by frame", "typing lands in the field right after Stop")
        attach(app, "stopped")

        // Past the moment the video is whole on the Mac, plus slack: a send that was not
        // called off would have cleared the draft and the tray by now.
        Thread.sleep(forTimeInterval: uploadSeconds - stoppedAfter + 3)
        XCTAssertEqual(field.value as? String, draft + " Frame by frame", "no message was sent: the draft is still there")
        XCTAssertTrue(tile.exists, "no message was sent: the video is still in the tray")
        XCTAssertEqual(send.label, "Send", "the composer stays idle")
        attach(app, "after-upload-finished")

        let numbers = XCTAttachment(string: "cancel-mid-send stopped_after_s=\(String(format: "%.2f", stoppedAfter)) of \(uploadSeconds) upload_badge=\(percent)")
        numbers.name = "cancel-mid-send-numbers"
        numbers.lifetime = .keepAlways
        add(numbers)
    }

    private func waitFor(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
