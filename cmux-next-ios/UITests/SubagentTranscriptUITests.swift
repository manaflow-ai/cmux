import XCTest

/// A subagent's transcript and the Subagents list on the list rig's generated chat
/// (`CMUX_MOBILE_LIST_SCREEN=subagent|subagents`, ListStressChatScreens): the "Subagent of" pill,
/// the task, rows, the state footer; a nested subagent's row pushes its own transcript and back
/// pops one level; a Subagents row pushes its transcript; the empty list. Each step attaches a
/// screenshot.
final class SubagentTranscriptUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ screen: String, count: Int, stream: Bool = false, edge: String? = nil, after: Double? = nil, hz: Double? = nil) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = screen
        app.launchEnvironment["CMUX_MOBILE_LIST_COUNT"] = "\(count)"
        app.launchEnvironment["CMUX_MOBILE_LIST_PASSES"] = "0"
        app.launchEnvironment["CMUX_MOBILE_LIST_SETTLE"] = "0"
        if stream { app.launchEnvironment["CMUX_MOBILE_LIST_STREAM"] = "1" }
        if let edge { app.launchEnvironment["CMUX_MOBILE_LIST_EDGE"] = edge }
        if let after { app.launchEnvironment["CMUX_MOBILE_LIST_EDGE_AFTER"] = "\(after)" }
        if let hz { app.launchEnvironment["CMUX_MOBILE_LIST_LIVE_HZ"] = "\(hz)" }
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore"]
        app.launch()
        return app
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testNestedSubagentPushesItsTranscriptAndBackPopsOneLevel() {
        let app = launch("subagent", count: 40)
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["WireGuard dialer"].waitForExistence(timeout: 40), "the transcript opens\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Subagent of Rig chat"].exists, "the pill names the parent")
        XCTAssertTrue(app.staticTexts["Check the WireGuard dialer's retry path and measure its backoff"].exists, "the task shows")
        attach(app, "1-transcript-top")

        let nested = app.buttons["Relay probe, Done"].firstMatch
        for _ in 0..<12 where !(nested.exists && nested.isHittable) { app.swipeUp() }
        XCTAssertTrue(nested.isHittable, "the nested subagent's row is reachable\n\(app.debugDescription)")
        attach(app, "2-nested-row")
        nested.tap()
        XCTAssertTrue(app.navigationBars["Relay probe"].waitForExistence(timeout: 10), "the nested transcript opens\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Subagent of WireGuard dialer"].exists, "its pill names its parent subagent")
        attach(app, "3-nested-transcript")
        app.navigationBars["Relay probe"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["WireGuard dialer"].waitForExistence(timeout: 10), "back pops one level")
        XCTAssertTrue(nested.isHittable, "back returns to the same place")
        for _ in 0..<12 where !app.staticTexts["Done"].exists { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Done"].exists, "the footer says the subagent finished\n\(app.debugDescription)")
        attach(app, "4-footer-done")
    }

    @MainActor
    func testRunningTranscriptStreams() {
        // Text only: every token goes into the one answer, so a transcript that missed text growing
        // inside an existing item would show none of them (no new items carry them in).
        let app = launch("subagent", count: 10, stream: true, edge: "text")
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["WireGuard dialer"].waitForExistence(timeout: 40), "the transcript opens\n\(app.debugDescription)")
        // Tokens stream into the running subagent's answer. A running transcript opens on its end
        // (following it), so the newest tokens are on screen: the newest one shown keeps growing.
        let tokens = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "token"))
        XCTAssertTrue(tokens.firstMatch.waitForExistence(timeout: 20), "streamed tokens show\n\(app.debugDescription)")
        func newest() -> Int {
            tokens.allElementsBoundByIndex.compactMap { element in
                element.label.split(separator: " ").compactMap { Int($0.dropFirst("token".count)) }.max()
            }.max() ?? 0
        }
        let first = newest()
        pass(3)
        let later = newest()
        print("CMUX_STREAM newest token \(first) then \(later) 3 s later")
        XCTAssertGreaterThan(later, first + 50, "tokens keep arriving on screen (\(first) -> \(later), 50 a second)")
        attach(app, "running")
    }

    @MainActor
    func testSubagentsListPushesATranscript() {
        let app = launch("subagents", count: 6)
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["Subagents"].waitForExistence(timeout: 40), "the list opens\n\(app.debugDescription)")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Subagent 1")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "a nested row shows\n\(app.debugDescription)")
        attach(app, "1-list")
        row.tap()
        XCTAssertTrue(app.navigationBars["Subagent 1"].waitForExistence(timeout: 10), "the row pushes its transcript\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Subagent of Subagent 0"].exists, "the pill names its parent")
        attach(app, "2-pushed")
        app.navigationBars["Subagent 1"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Subagents"].waitForExistence(timeout: 10), "back to the list")
    }

    @MainActor
    func testEmptySubagentsList() {
        let app = launch("subagents", count: 0)
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["No subagents"].waitForExistence(timeout: 40), "the empty state\n\(app.debugDescription)")
        attach(app, "empty")
    }

    /// The element is wholly on screen, by its frame: off screen, a lazy row can have no
    /// activation point, and `isHittable` fails the test there instead of answering.
    @MainActor
    private func onScreen(_ app: XCUIApplication, _ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        return !frame.isEmpty && app.windows.firstMatch.frame.contains(frame)
    }

    /// Lets `seconds` of the live stream go by.
    @MainActor
    private func pass(_ seconds: TimeInterval) {
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "the stream runs")], timeout: seconds)
    }

    /// SUB-8: at the end, the running transcript follows its new rows; scrolled away, the row
    /// being read stays put while rows arrive below; back at the end, it follows again.
    @MainActor
    func testRunningTranscriptFollowsAtTheEndAndHoldsTheReaderAway() {
        // The stream starts 30 s after launch: the reader reaches the end of a still transcript
        // first (a live one grows faster than swipes reach its end, and never idles for them).
        // 10 tokens a second (a row every 2.5 s): XCUITest swipes take seconds each, and must be
        // able to reach the end of a transcript that grows while they run.
        let app = launch("subagent", count: 20, stream: true, edge: "late", after: 30, hz: 10)
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["WireGuard dialer"].waitForExistence(timeout: 40), "the transcript opens\n\(app.debugDescription)")
        let footer = app.staticTexts["chat.subagent.footer"].firstMatch
        for _ in 0..<20 where !onScreen(app, footer) { app.swipeUp(velocity: .fast) }
        XCTAssertTrue(onScreen(app, footer), "the reader reaches the end\n\(app.debugDescription)")
        attach(app, "1-at-end")
        // The stream starts and runs: the end stays in view.
        let streaming = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "token")).firstMatch
        XCTAssertTrue(streaming.waitForExistence(timeout: 45), "the stream starts\n\(app.debugDescription)")
        pass(5)
        XCTAssertTrue(onScreen(app, footer), "at the end, the transcript follows 5 s of new rows\n\(app.debugDescription)")
        attach(app, "2-followed")

        app.swipeDown()
        app.swipeDown()
        pass(1)
        // A row that is not streaming (a streamed answer's text changes as it grows).
        let read = app.staticTexts.allElementsBoundByIndex.first { $0.isHittable && $0.label.count > 3 && !$0.label.contains("token") && $0.identifier != "chat.subagent.footer" }
        guard let read else { XCTFail("a row to read shows\n\(app.debugDescription)"); return }
        let label = read.label
        let before = read.frame
        attach(app, "3-scrolled-away")
        pass(4)
        let after = app.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch.frame
        XCTAssertEqual(after.minY, before.minY, accuracy: 1, "the row being read stays put while rows arrive below")
        XCTAssertFalse(onScreen(app, footer),
                       "scrolled away, the transcript does not follow")
        attach(app, "4-held")

        for _ in 0..<30 where !onScreen(app, footer) { app.swipeUp(velocity: .fast) }
        pass(4)
        XCTAssertTrue(onScreen(app, footer), "back at the end, it follows again\n\(app.debugDescription)")
        attach(app, "5-follows-again")
    }

    /// SUB-11: the subagent's chat goes while its transcript is open: "Subagent not found".
    @MainActor
    func testRemovedSubagentSaysNotFound() {
        let app = launch("subagent", count: 20, stream: true, edge: "removed")
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["WireGuard dialer"].waitForExistence(timeout: 40), "the transcript opens\n\(app.debugDescription)")
        attach(app, "1-open")
        XCTAssertTrue(app.staticTexts["Subagent not found"].waitForExistence(timeout: 20), "the removed subagent says so\n\(app.debugDescription)")
        XCTAssertEqual(app.state, .runningForeground, "no crash")
        attach(app, "2-not-found")
    }

    /// SUB-11: the Mac goes offline mid-run: the rows stay, the footer says so, no spinner.
    @MainActor
    func testMacOfflineMidRunStopsTheFooter() {
        let app = launch("subagent", count: 20, stream: true, edge: "offline")
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["WireGuard dialer"].waitForExistence(timeout: 40), "the transcript opens\n\(app.debugDescription)")
        let footer = app.staticTexts["chat.subagent.footer"].firstMatch
        for _ in 0..<20 where !onScreen(app, footer) { app.swipeUp() }
        attach(app, "1-running")
        let offline = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Mac offline"), object: footer)
        XCTAssertEqual(XCTWaiter().wait(for: [offline], timeout: 20), .completed, "the footer says the Mac is offline, has '\(footer.label)'")
        let tokens = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "token"))
        func shown() -> [String] { tokens.allElementsBoundByIndex.map(\.label) }
        let text = shown()
        XCTAssertFalse(text.isEmpty, "the streamed rows show at the end\n\(app.debugDescription)")
        pass(3)
        XCTAssertEqual(shown(), text, "nothing streams while offline, and the rows shown stay")
        XCTAssertEqual(footer.label, "Mac offline", "the footer stays")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Ran swift build")).firstMatch.exists, "the rows stay")
        attach(app, "2-offline")
    }

    /// SUB-8 under the real load, 50 tokens a second: the reader rests on the end (the screen's
    /// position, no gesture) while the transcript grows; over every layout pass while it grows,
    /// the end stays within the 60 pt band (the rig's FollowProbe measures it in the app).
    @MainActor
    func testFollowAtFiftyHzKeepsTheEndInTheBand() {
        let app = launch("subagent", count: 20, stream: true, edge: "follow", after: 5, hz: 50)
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["WireGuard dialer"].waitForExistence(timeout: 40), "the transcript opens\n\(app.debugDescription)")
        let probe = app.staticTexts["chat.subagent.followprobe"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 10), "the probe shows\n\(app.debugDescription)")
        attach(app, "1-at-end")
        // 15 s of stream: 750 tokens, 30 tool calls.
        pass(20)
        let label = probe.label
        attach(app, "2-after-15s-at-50hz")
        let note = XCTAttachment(string: label)
        note.name = "follow-probe"
        note.lifetime = .keepAlways
        add(note)
        print("CMUX_FOLLOW_PROBE \(label)")
        let numbers = label.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count == 3 else { XCTFail("the probe reports, has '\(label)'"); return }
        let (gap, passes, growths) = (numbers[0], numbers[1], numbers[2])
        XCTAssertGreaterThan(growths, 100, "the transcript grew while measured: \(label)")
        XCTAssertGreaterThanOrEqual(passes, growths, label)
        XCTAssertLessThanOrEqual(gap, 60, "the end stayed within 60 pt of the screen: \(label)")
        XCTAssertTrue(onScreen(app, app.staticTexts["chat.subagent.footer"].firstMatch), "the end (the footer) is on screen\n\(app.debugDescription)")
    }

    /// SUB-8: the reader breaks out of following with their finger. A running transcript followed
    /// at its end (50 tokens a second), the reader drags the content down 200 pt and lets go: it
    /// stays where the finger left it, with no snap back to the end, while items keep arriving.
    @MainActor
    func testADragUpMidStreamBreaksOutOfFollowing() {
        let app = launch("subagent", count: 20, stream: true, edge: "follow", after: 3, hz: 50)
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["WireGuard dialer"].waitForExistence(timeout: 40), "the transcript opens\n\(app.debugDescription)")
        let footer = app.staticTexts["chat.subagent.footer"].firstMatch
        let streaming = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "token")).firstMatch
        XCTAssertTrue(streaming.waitForExistence(timeout: 30), "the stream starts\n\(app.debugDescription)")
        pass(2)
        XCTAssertTrue(onScreen(app, footer), "following at the end before the drag")
        attach(app, "1-following")
        // The finger moves 200 pt down the screen: the content moves down, the reader goes up it.
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 200)), withVelocity: 300, thenHoldForDuration: 0.3)
        pass(1)
        // A row that is not streaming, read after the drag: it must stay put while items arrive.
        let read = app.staticTexts.allElementsBoundByIndex.first { $0.isHittable && $0.label.count > 3 && !$0.label.contains("token") && $0.identifier != "chat.subagent.footer" }
        guard let read else { XCTFail("a row to read shows\n\(app.debugDescription)"); return }
        let label = read.label
        let before = read.frame.minY
        attach(app, "2-after-drag")
        var largest: CGFloat = 0
        for _ in 0..<6 {
            pass(0.5)
            let now = app.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
            largest = max(largest, abs((now.exists ? now.frame.minY : .infinity) - before))
        }
        print("CMUX_DRAG_BREAKOUT largest move of the read row after the drag \(largest) pt")
        XCTAssertLessThanOrEqual(largest, 1, "the transcript stays where the finger left it, no snap back to the end")
        XCTAssertFalse(onScreen(app, footer), "the end is not followed after the drag")
        attach(app, "3-held-after-drag")
    }
}
