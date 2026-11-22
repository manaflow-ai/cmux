import XCTest

/// Voice mode replaces the composer's dictation mic (Aziz 2026-11-03): the waveform in the agent
/// chat's composer and in the terminal's starts a GPT Realtime line to the agent. Here the
/// Realtime connection is the DEBUG scripted link (CMUX_MOBILE_VOICE_MODE_DEMO=1, the API's own
/// event shapes, no key or microphone): it "says" a prompt, which must reach the agent as a
/// turn, and each reading voice mode asks for is played back as captions, which must never hold
/// code or a diff.
///
/// The frames attached while it runs (`voice-chat-NNN`, `voice-terminal-NNN`) are the recording.
final class VoiceModeUITests: XCTestCase {
    static let prompt = "Run the tests again and tell me what failed."

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ demo: String) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_VOICE_MODE_DEMO"] = "1"
        app.launchEnvironment["CMUX_MOBILE_VOICE_MODE_DEMO_PROMPT"] = Self.prompt
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", demo]
        app.launch()
        return app
    }

    @MainActor
    func testAgentChatVoiceModeSendsSpeechAndReadsRepliesWithoutCode() {
        let app = launch("voice-chat")
        defer { app.terminate() }
        var recorder = FrameRecorder(test: self, app: app, name: "voice-chat")

        let voice = app.buttons["agentChat.composer.voice"]
        XCTAssertTrue(voice.waitForExistence(timeout: 30), "the empty composer shows the voice button\n\(app.debugDescription)")
        XCTAssertEqual(voice.label, "Voice Mode")
        XCTAssertFalse(app.buttons["Start dictation"].exists, "no dictation mic")
        recorder.frames(seconds: 1)
        voice.tap()

        let bar = app.otherElements["voiceMode.bar"].firstMatch
        let caption = app.staticTexts["voiceMode.caption"].firstMatch
        XCTAssertTrue(caption.waitForExistence(timeout: 10), "the voice bar shows\n\(app.debugDescription)")
        // The scripted user speaks: the words appear live, then reach the agent as its next turn.
        var captions = recorder.frames(seconds: 6, caption: caption)
        let sent = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND identifier != %@", "tell me what failed", "voiceMode.caption")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 15), "the spoken prompt is sent to the agent\n\(app.debugDescription)")
        // The agent answers; voice mode reads its words aloud (captions), and nothing else.
        captions += recorder.frames(seconds: 18, caption: caption)
        print("CMUX_VOICE captions: \(captions)")
        XCTAssertTrue(captions.contains { $0.contains("Run the tests again") }, "the user's words were captioned: \(captions)")
        let spoken = captions.filter { !$0.contains("Run the tests again") && !$0.isEmpty }
        XCTAssertTrue(spoken.contains { $0.count > 12 }, "the agent's reply was read aloud: \(captions)")
        for line in captions {
            XCTAssertFalse(line.contains("```") || line.contains("@@") || line.contains("diff --git"), "code read aloud: \(line)")
        }

        app.buttons["voiceMode.end"].firstMatch.tap()
        XCTAssertTrue(waitGone(bar), "End closes voice mode")
        XCTAssertEqual(voice.label, "Voice Mode")
        recorder.frames(seconds: 1)
    }

    @MainActor
    func testTerminalComposerHasVoiceModeInsteadOfDictation() {
        let app = launch("voice-terminal")
        defer { app.terminate() }
        var recorder = FrameRecorder(test: self, app: app, name: "voice-terminal")

        let voice = app.buttons["terminal.composer.voice"]
        XCTAssertTrue(voice.waitForExistence(timeout: 30), "the terminal composer shows the voice button\n\(app.debugDescription)")
        XCTAssertFalse(app.buttons["terminal.composer.mic"].exists, "the dictation mic is gone")
        recorder.frames(seconds: 1)
        voice.tap()
        let caption = app.staticTexts["voiceMode.caption"].firstMatch
        XCTAssertTrue(caption.waitForExistence(timeout: 10), "the voice bar shows\n\(app.debugDescription)")
        let captions = recorder.frames(seconds: 8, caption: caption)
        XCTAssertTrue(captions.contains { $0.contains("Run the tests again") }, "the user's words were captioned: \(captions)")
        XCTAssertEqual(voice.label, "End Voice Mode", "the button is on while voice mode runs")
        voice.tap()
        XCTAssertTrue(waitGone(app.otherElements["voiceMode.bar"].firstMatch), "a second tap ends voice mode")
        recorder.frames(seconds: 1)
    }

    private func waitGone(_ element: XCUIElement) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: 10) == .completed
    }
}

/// Screenshots as fast as the simulator gives them, attached in order: the frames of the recording.
@MainActor
private struct FrameRecorder {
    let test: XCTestCase
    let app: XCUIApplication
    let name: String
    var index = 0

    /// Frames for `seconds`; with a caption, its distinct texts in order.
    @discardableResult
    mutating func frames(seconds: TimeInterval, caption: XCUIElement? = nil) -> [String] {
        var texts: [String] = []
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = String(format: "%@-%03d", name, index)
            shot.lifetime = .keepAlways
            test.add(shot)
            index += 1
            if let caption, caption.exists {
                let text = caption.label
                if texts.last != text { texts.append(text) }
            }
        }
        return texts
    }
}
