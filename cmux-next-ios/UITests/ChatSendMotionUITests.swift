import XCTest

/// Leo, 2026-11-15, after trying NEXT on his iPhone: "Tho the animation for sending messages is
/// kinda ass". Sends three messages (one of three lines) in an idle chat with history, once per
/// send motion (`ChatSendMotion`, `-cmuxMobile.dev.sendMotion`), with the mock agent echoing each
/// prompt after a Mac's round trip (`-cmuxMobile.dev.mockEchoMs 300`). The fleet records the
/// screen (`cmux-next-ios-sim.sh test ui=ChatSendMotionUITests/testSendMotionC video`) for the
/// before and after videos. Each sent bubble is in the transcript before the echo could be.
final class ChatSendMotionUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor func testSendMotionA() throws { try sendThree(motion: "A") }
    @MainActor func testSendMotionB() throws { try sendThree(motion: "B") }
    @MainActor func testSendMotionC() throws { try sendThree(motion: "C") }
    /// The motion before the change (rows jump to the bottom, the bubble fades in), for comparison.
    @MainActor func testSendMotionOff() throws { try sendThree(motion: "off") }

    @MainActor
    private func sendThree(motion: String) throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "disclosure-chat",
                                "-cmuxMobile.dev.sendMotion", motion, "-cmuxMobile.dev.mockEchoMs", "300"]
        app.launch()
        defer { app.terminate() }

        let more = app.navigationBars.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 30), "the pushed agent chat opens\n\(app.debugDescription)")
        // Let the chat open and rest before the first send.
        pause(1.5)
        let messages = ["What is in the README?", "Check the build\nthen run the linter\nand summarize both", "Thanks"]
        for (index, message) in messages.enumerated() {
            let field = openComposer(app)
            for line in message.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if line.offset > 0 { field.typeText("\n") }
                field.typeText(String(line.element))
            }
            pause(0.6)
            app.buttons["Send"].firstMatch.tap()
            // The motion plays, the turn starts.
            pause(1.6)
            attach(app, "\(motion)-sent-\(index + 1)")
            // What the glide did (DEBUG `ChatSendTrace`), kept as a text attachment of the run.
            let trace = app.descendants(matching: .any)["chat.sendSettle.trace"].firstMatch
            let traceText = XCTAttachment(string: trace.exists ? (trace.value as? String ?? "-") : "absent")
            traceText.name = "\(motion)-trace-\(index + 1)"
            traceText.lifetime = .keepAlways
            add(traceText)
            if motion != "off", trace.exists { assertGlides(trace.value as? String ?? "", "\(motion) send \(index + 1)") }
            // The demo's short turn ends on its own; a turn still running after a while is stopped
            // so the next message goes into an idle chat.
            let stop = app.buttons["Stop"].firstMatch
            let ended = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: stop)],
                                         timeout: 15)
            if ended != .completed, stop.exists { stop.tap() }
            pause(0.8)
        }
        pause(1.0)
    }

    /// The rows above the bubble glide from where they were: the first display frame of the send
    /// moves them a frame's share of the spring, not a jump (the glide's clock starts at the frame
    /// it is first drawn in, however long the Send tap kept the main thread).
    @MainActor
    private func assertGlides(_ trace: String, _ name: String) {
        let lines = trace.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        // This send's lines: from its arm on.
        let sent = lines.lastIndex(where: { $0.hasPrefix("arm ") }).map { Array(lines[$0...]) } ?? []
        guard let end = sent.last(where: { $0.hasPrefix("end after") }),
            let reach = number(after: "reach ", in: end), let first = number(after: "first step ", in: end) else {
            return XCTFail("\(name): the trace has no finished glide: \(trace)")
        }
        XCTAssertLessThanOrEqual(first, max(6, reach * 0.12), "\(name): the first frame moved the rows \(first) of \(reach) pt: \(end)")
        // The glide's first frame follows the frame the composer clears in: nothing left of the
        // Send (the keyboard going down) holds the main thread past two 60 Hz frames.
        if let lag = number(after: "start lag ", in: end) {
            XCTAssertLessThanOrEqual(lag, 34, "\(name): the glide's first frame came \(lag) ms after the send drew its rows: \(end)")
        } else {
            XCTFail("\(name): the trace has no start lag: \(end)")
        }
    }

    private func number(after label: String, in text: String) -> Double? {
        guard let range = text.range(of: label) else { return nil }
        return Double(text[range.upperBound...].prefix { $0.isNumber || $0 == "-" })
    }

    /// The composer's field, focused (the chat shows its composer collapsed until tapped).
    @MainActor
    private func openComposer(_ app: XCUIApplication) -> XCUIElement {
        let field = app.textViews["chat.composer.field"]
        if !field.exists {
            let bar = app.buttons["Reply to Claude"].firstMatch
            if bar.waitForExistence(timeout: 10) { bar.tap() }
        }
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the composer opens\n\(app.debugDescription)")
        for _ in 0..<5 where !((field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false) {
            field.tap()
            _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)],
                                 timeout: 2)
        }
        return field
    }

    private func pause(_ seconds: TimeInterval) {
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "pause")], timeout: seconds)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
