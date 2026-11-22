import XCTest

/// SUB-11 and SUB-12 (landscape): a subagent's transcript at its edges, on the list rig's generated
/// chat (`CMUX_MOBILE_LIST_SCREEN=subagent`, ListStressChatScreens): 1 item; 0 items and no task
/// (the pill and the footer only); 1000 items in one main-actor turn (`CMUX_MOBILE_LIST_EDGE=burst`:
/// the transcript takes them and still scrolls to its end); a row taller than the screen
/// (`LIST_GIANT=1`: scrolled past to the footer); turning the iPhone keeps the line being read where
/// it was (a phone's screen stays portrait). The removed subagent and the Mac offline mid-run are
/// SubagentTranscriptUITests' (`LIST_EDGE=removed|offline`).
final class SubagentTranscriptEdgeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    private func launch(count: Int, stream: Bool = false, giant: Bool = false, edge: String? = nil) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = "subagent"
        app.launchEnvironment["CMUX_MOBILE_LIST_COUNT"] = "\(count)"
        app.launchEnvironment["CMUX_MOBILE_LIST_PASSES"] = "0"
        app.launchEnvironment["CMUX_MOBILE_LIST_SETTLE"] = "0"
        if let edge {
            app.launchEnvironment["CMUX_MOBILE_LIST_EDGE"] = edge
            app.launchEnvironment["CMUX_MOBILE_LIST_EDGE_AFTER"] = "3"
        }
        if stream { app.launchEnvironment["CMUX_MOBILE_LIST_STREAM"] = "1" }
        if giant { app.launchEnvironment["CMUX_MOBILE_LIST_GIANT"] = "1" }
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore"]
        app.launch()
        XCTAssertTrue(app.navigationBars["WireGuard dialer"].waitForExistence(timeout: 40), "the transcript opens\n\(app.debugDescription)")
        return app
    }

    @MainActor
    private func scrollToFooter(_ app: XCUIApplication, _ footer: XCUIElement, swipes: Int = 40) {
        for _ in 0..<swipes where !onScreen(app, footer) { app.swipeUp(velocity: .fast) }
    }

    /// The transcript's state footer: "Done" alone also names the nested subagent card's header.
    @MainActor
    private func footer(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts["chat.subagent.footer"].firstMatch
    }

    /// Wholly on screen, by its frame (off screen, a lazy row has no activation point and
    /// `isHittable` fails the test instead of answering).
    @MainActor
    private func onScreen(_ app: XCUIApplication, _ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        return !frame.isEmpty && app.windows.firstMatch.frame.contains(frame)
    }

    @MainActor
    func testOneItem() {
        let app = launch(count: 1)
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Subagent of Rig chat"].exists, "the pill")
        XCTAssertTrue(app.staticTexts["Check the WireGuard dialer's retry path and measure its backoff"].exists, "the task")
        let done = footer(app)
        XCTAssertTrue(done.waitForExistence(timeout: 10) && done.label == "Done" && onScreen(app, done), "the footer is on the first screen\n\(app.debugDescription)")
        edgeShot(app, "sub11-one-item")
    }

    @MainActor
    func testZeroItemsAndNoTaskShowPillAndFooter() {
        let app = launch(count: 0)
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Subagent of Rig chat"].exists, "the pill")
        XCTAssertFalse(app.staticTexts["Check the WireGuard dialer's retry path and measure its backoff"].exists, "no task bubble")
        XCTAssertTrue(footer(app).waitForExistence(timeout: 10) && footer(app).label == "Done", "the footer\n\(app.debugDescription)")
        edgeShot(app, "sub11-zero-items")
    }

    @MainActor
    func testThousandItemBurstLands() {
        let app = launch(count: 10, edge: "burst")
        defer { app.terminate() }
        edgeShot(app, "sub11-burst-1-before")
        // 3 s after the open, the rig's burst lands. The burst's last answer token is at the transcript's end, before its footer.
        let last = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "burst499")).firstMatch
        let done = footer(app)
        for _ in 0..<60 where !(last.exists && onScreen(app, done)) { app.swipeUp(velocity: .fast) }
        XCTAssertTrue(last.exists, "the burst's last item shows\n\(app.debugDescription)")
        XCTAssertTrue(onScreen(app, done), "the transcript scrolls to its footer after the burst")
        XCTAssertEqual(app.state, .runningForeground, "no crash")
        edgeShot(app, "sub11-burst-2-end")
    }

    @MainActor
    func testRowTallerThanTheScreenScrollsPast() {
        let app = launch(count: 10, giant: true)
        defer { app.terminate() }
        let done = footer(app)
        edgeShot(app, "sub11-tall-1-top")
        scrollToFooter(app, done)
        XCTAssertTrue(onScreen(app, done), "scrolled past the tall row to the footer\n\(app.debugDescription)")
        XCTAssertEqual(app.state, .runningForeground, "no crash")
        edgeShot(app, "sub11-tall-2-footer")
    }

    /// SUB-12, landscape.
    @MainActor
    func testRotationKeepsTheLineBeingRead() throws {
        let app = launch(count: 40)
        defer { app.terminate() }
        let window = app.windows.firstMatch
        app.swipeUp()
        let before = RowFrames.settled(window, key: RowFrames.text)
        let reader = try XCTUnwrap(RowFrames.reader(before, in: window), "a line being read")
        var lines = ["reader '\(reader)' at \(before[reader]!)", "window \(window.frame)"]
        edgeShot(app, "sub12-1-portrait")
        for (step, orientation) in [UIDeviceOrientation.landscapeLeft, .portrait, .landscapeRight, .portrait].enumerated() {
            XCUIDevice.shared.orientation = orientation
            let frames = RowFrames.settled(window, key: RowFrames.text)
            let turned = window.frame
            edgeShot(app, "sub12-\(step + 2)-\(orientation == .portrait ? "portrait" : "landscape")")
            lines.append("step \(step) orientation \(orientation.rawValue): window \(turned), reader \(frames[reader].map { "\($0)" } ?? "off screen")")
            XCTAssertTrue(turned.width < turned.height, "a phone's screen stays portrait (window \(turned))")
            let now = try XCTUnwrap(frames[reader], "the line being read stays on screen at step \(step)")
            XCTAssertLessThanOrEqual(abs(now.minY - before[reader]!.minY), RowFrames.shiftBar,
                                     "the line being read moved \(now.minY - before[reader]!.minY) pt at step \(step)")
        }
        edgeNote(lines.joined(separator: "\n"), "sub12-frames")
    }
}
