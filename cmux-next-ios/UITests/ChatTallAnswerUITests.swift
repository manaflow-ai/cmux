import XCTest

/// The shared block builder's tall-row check on the agent chat (the same 240-line log answer the
/// subagent transcript's `testRowTallerThanTheScreenScrollsPast` reads): the chat opens on its
/// newest turn, whose answer is the log, and the reader scrolls up through it a swipe at a time.
/// The transcript never jumps back toward its end during a swipe, a still reader's row moves at
/// most 0.5 pt, the reader reaches the prompt above the log, and the main thread never stalls.
final class ChatTallAnswerUITests: XCTestCase {
    /// The app's main-thread stall stacks (MainStallWatchdog), on the host.
    private let stallLog = "/tmp/cmux-stall-\(UUID().uuidString).txt"

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        if let text = try? String(contentsOfFile: stallLog, encoding: .utf8) {
            let attachment = XCTAttachment(string: text)
            attachment.name = "main-stall-stacks"
            attachment.lifetime = .keepAlways
            add(attachment)
            print("CMUX_MAIN_STALL \(text.components(separatedBy: "main thread busy").count - 1) stalls")
            try? FileManager.default.removeItem(atPath: stallLog)
        }
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    private func pause(_ seconds: TimeInterval) {
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "the reader holds still")], timeout: seconds)
    }

    /// Wholly on screen, by its frame.
    @MainActor
    private func onScreen(_ app: XCUIApplication, _ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        return !frame.isEmpty && app.windows.firstMatch.frame.contains(frame)
    }

    @MainActor
    func testATallAnswerScrollsThroughWithoutAJump() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = "chat"
        app.launchEnvironment["CMUX_MOBILE_LIST_COUNT"] = "3"
        app.launchEnvironment["CMUX_MOBILE_LIST_PASSES"] = "0"
        app.launchEnvironment["CMUX_MOBILE_LIST_SETTLE"] = "0"
        app.launchEnvironment["CMUX_MOBILE_LIST_TALL_ANSWER"] = "1"
        app.launchEnvironment["CMUX_MOBILE_STALL_WATCHDOG"] = "1"
        app.launchEnvironment["CMUX_MOBILE_STALL_LOG"] = stallLog
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore"]
        app.launch()
        defer { app.terminate() }

        // The newest answer is the log: the chat opens on it.
        let log = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "frame header mismatch")).firstMatch
        XCTAssertTrue(log.waitForExistence(timeout: 60), "the chat opens on its newest answer, the log\n\(app.debugDescription)")
        attach(app, "chat-tall-1-end")
        // The prompt above the log (MockStressContent.prompt(2)).
        let prompt = app.staticTexts["Add tests for the transport switch"].firstMatch
        func held() -> CGFloat? { log.exists && !log.frame.isEmpty ? log.frame.minY : nil }
        var largest: CGFloat = 0
        var holds = 0
        // Reading up, the log's text only moves down the screen; a jump to the end moves it up.
        var lastTop: CGFloat?
        var jump: CGFloat = 0
        for _ in 0..<60 where !onScreen(app, prompt) {
            app.swipeDown()
            pause(1)
            let top = held()
            if let top, let lastTop, lastTop - top > jump { jump = lastTop - top }
            lastTop = top ?? lastTop
            guard let before = held() else { continue }
            pause(1)
            guard let after = held() else { continue }
            holds += 1
            largest = max(largest, abs(after - before))
        }
        let line = "chat tall row: largest move of a still reader's row \(largest) pt over \(holds) holds; largest jump toward the end in a swipe \(jump) pt"
        print("CMUX_CHAT_TALL_ROW \(line)")
        let note = XCTAttachment(string: line)
        note.name = "chat-tall-shift"
        note.lifetime = .keepAlways
        add(note)
        attach(app, "chat-tall-2-prompt")
        XCTAssertTrue(onScreen(app, prompt), "scrolled up past the tall answer to its prompt\n\(app.debugDescription)")
        XCTAssertLessThanOrEqual(jump, 4, "a swipe up the chat never moves it back toward its end: \(line)")
        XCTAssertGreaterThan(holds, 3, "the reader held still on the way: \(line)")
        XCTAssertLessThanOrEqual(largest, 0.5, line)
        XCTAssertEqual(app.state, .runningForeground, "no crash")
    }
}
