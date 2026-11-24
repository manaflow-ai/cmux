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

    /// The list's offset, top and content height (the rig's `list.scroll.probe`).
    @MainActor
    private func offset(_ app: XCUIApplication) -> (y: CGFloat, top: CGFloat, h: CGFloat)? {
        let probe = app.descendants(matching: .any)["list.scroll.probe"].firstMatch
        guard probe.exists else { return nil }
        var values: [String: CGFloat] = [:]
        for part in probe.label.split(separator: " ") {
            let pair = part.split(separator: "=")
            if pair.count == 2, let value = Double(pair[1]) { values[String(pair[0])] = CGFloat(value) }
        }
        guard let y = values["y"], let top = values["top"], let h = values["h"] else { return nil }
        return (y, top, h)
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
        // The rig leaves the chat at its newest turn (by default it jumps to the top a few seconds
        // after the open, as a reader leaving the newest turn: that jump read as a reset, 8cbc6b30).
        app.launchEnvironment["CMUX_MOBILE_LIST_LEAVE_NEWEST"] = "0"
        app.launchEnvironment["CMUX_MOBILE_LIST_SCROLL_PROBE"] = "1"
        app.launchEnvironment["CMUX_MOBILE_STALL_WATCHDOG"] = "1"
        app.launchEnvironment["CMUX_MOBILE_STALL_LOG"] = stallLog
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore"]
        app.launch()
        defer { app.terminate() }

        // The newest answer is the log: the chat opens on it.
        let log = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "frame header mismatch")).firstMatch
        XCTAssertTrue(log.waitForExistence(timeout: 60), "the chat opens on its newest answer, the log\n\(app.debugDescription)")
        XCTAssertTrue(app.descendants(matching: .any)["list.scroll.probe"].waitForExistence(timeout: 20), "the rig's scroll probe shows")
        attach(app, "chat-tall-1-end")
        // The prompt above the log (MockStressContent.prompt(2)).
        let prompt = app.staticTexts["Add tests for the transport switch"].firstMatch

        // Nothing moves the transcript but the test's swipes: a still screen stays still.
        var stray: [String] = []
        if let start = offset(app) {
            pause(3)
            if let later = offset(app), abs(later.y - start.y) > 0.5 {
                stray.append("before any swipe: y \(start.y) -> \(later.y)")
            }
        }
        var lines: [String] = []
        var largest: CGFloat = 0
        var jump: CGFloat = 0
        var holds = 0
        let screen = app.windows.firstMatch.frame.height
        for swipe in 0..<80 where !onScreen(app, prompt) {
            guard let before = offset(app) else { break }
            app.swipeDown()
            pause(1)
            guard let landed = offset(app) else { break }
            // Held still: no gesture, so no move.
            pause(1)
            guard let held = offset(app) else { break }
            holds += 1
            let still = abs(held.y - landed.y)
            largest = max(largest, still)
            lines.append("swipe \(swipe): y \(before.y) -> \(landed.y), held \(held.y), content \(landed.h) pt")
            if still > 0.5 { stray.append("swipe \(swipe): moved \(held.y - landed.y) pt while held still (y \(held.y), top \(held.top))") }
            // Reading up, the offset only goes down; a swipe moves at most about three screens.
            if landed.y - before.y > jump { jump = landed.y - before.y }
            if before.y - landed.y > 3 * screen { stray.append("swipe \(swipe): moved \(before.y - landed.y) pt, more than a swipe moves") }
        }
        let summary = "chat tall row: largest move of a still reader \(largest) pt over \(holds) holds; largest move toward the end in a swipe \(jump) pt; stray moves \(stray.count)"
        print("CMUX_CHAT_TALL_ROW \(summary)")
        for line in lines { print("CMUX_CHAT_TALL_ROW \(line)") }
        let note = XCTAttachment(string: ([summary] + stray + lines).joined(separator: "\n"))
        note.name = "chat-tall-shift"
        note.lifetime = .keepAlways
        add(note)
        attach(app, "chat-tall-2-prompt")
        XCTAssertTrue(stray.isEmpty, "the transcript moved without a gesture (a rig or director scroll, or a reset): \(stray)")
        XCTAssertTrue(onScreen(app, prompt), "scrolled up past the tall answer to its prompt: \(summary)\n\(app.debugDescription)")
        XCTAssertLessThanOrEqual(jump, 4, "a swipe up the chat never moves it back toward its end: \(summary)")
        XCTAssertGreaterThan(holds, 3, "the reader held still on the way: \(summary)")
        XCTAssertLessThanOrEqual(largest, 0.5, summary)
        XCTAssertEqual(app.state, .runningForeground, "no crash")
    }
}
