import XCTest

/// Leo, 2026-11-23 (paraphrased): why is there no landscape mode; scrolling
/// right on extra wide Ghostty output does nothing, an extra wide table just
/// doesn't work, and the phone needs a way to scroll sideways.
///
/// The read-back of that ask (ask-6045d9eaa3) on the shipped code: the phone
/// is turned to landscape and each step checks one thing, with a screenshot:
///   a. the terminal tab's page menu opens and the window stays landscape (#54462);
///   b. a swipe of the top bar to the next tab and back keeps it landscape;
///   c. editing the browser tab's address bar keeps it landscape;
///   d. wide terminal output pans sideways under a left swipe once Wide is on
///      (a plain swipe over the phone's fitted grid is recorded, not asserted);
///   e. a wide Markdown table in an agent chat scrolls sideways under a left swipe.
/// "Landscape" is the app's own window: wider than tall. Every step is a
/// plain assertion except d2, which only records what a plain swipe does.
/// Run it with `cmux-next-ios-sim.sh test ui=LandscapeUITests video`.
final class LandscapeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: a-c: the workspace's terminal tab, its neighbours and the top bar

    @MainActor
    func testA_TerminalPageMenuKeepsLandscape() {
        let app = launchTerminalTab()
        XCTAssertTrue(turnSideways(app), "the terminal page turns landscape: \(size(app))")
        attach(app, "a1-landscape-before-menu")

        let menu = app.buttons["Page Menu"].firstMatch
        let copyDirectory = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Copy Directory'")).firstMatch
        XCTAssertFalse(copyDirectory.exists, "the page menu starts closed")
        let title = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'zsh'")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), "the top bar's title\n\(app.debugDescription)")
        // The title pill opens the page menu; a tap while the page still zooms in
        // (step ec551b50: the workspace at 926x426 in an 874x402 window), or on a
        // collapsed pill, is taken without opening it: up to three taps, as
        // PaneDragMoveUITests does.
        for attempt in 0..<3 where !copyDirectory.exists {
            if attempt == 1, menu.exists, menu.isHittable { menu.tap() } else { title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
            _ = copyDirectory.waitForExistence(timeout: 4)
        }
        XCTAssertTrue(copyDirectory.waitForExistence(timeout: 5), "the terminal page menu's Copy Directory action appears\n\(app.debugDescription)")
        attach(app, "a2-menu-open")
        XCTAssertTrue(isLandscape(app), "the page menu is open and the window stays landscape: \(size(app))")

        // Dismiss the menu (a tap outside it) and look again.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.15)).tap()
        XCTAssertTrue(waitFor(5) { !copyDirectory.exists }, "dismissing the page menu removes its actions")
        attach(app, "a3-menu-closed")
        XCTAssertTrue(isLandscape(app), "the menu closed and the window stays landscape: \(size(app))")
    }

    @MainActor
    func testB_SwipingBetweenTabsKeepsLandscape() {
        let app = launchTerminalTab()
        XCTAssertTrue(turnSideways(app), "the terminal page turns landscape: \(size(app))")
        attach(app, "b1-terminal-landscape")

        // ws-cmux's tabs: Claude, zsh, Swift docs: a swipe toward Swift docs (a browser), the other way back.
        let towardBrowser = swipeToBrowserTab(app)
        let browserAddress = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Address' OR label BEGINSWITH 'Show toolbar'")).firstMatch
        XCTAssertTrue(browserAddress.waitForExistence(timeout: 5), "the swipe reaches the browser tab\n\(app.debugDescription)")
        attach(app, "b2-swiped-to-browser-tab")
        let onBrowser = isLandscape(app)
        XCTAssertTrue(onBrowser, "landed on the browser tab, the window stays landscape: \(size(app))")

        swipeTopBar(app, toLeft: !(towardBrowser ?? false))
        _ = waitFor(5) { self.isLandscape(app) }
        attach(app, "b3-swiped-back-to-terminal")
        XCTAssertTrue(isLandscape(app), "swiped back to the terminal tab, the window is landscape: \(size(app))")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'zsh'")).firstMatch.waitForExistence(timeout: 5),
                      "the terminal tab is the one on screen\n\(app.debugDescription)")
    }

    @MainActor
    func testC_EditingTheAddressBarKeepsLandscape() {
        let app = launchTerminalTab()
        XCTAssertTrue(turnSideways(app), "the terminal page turns landscape: \(size(app))")
        // A terminal tab has no editable address (its title opens the page menu): the address bar
        // is the browser tab's, one swipe away.
        _ = swipeToBrowserTab(app)
        settle(1.5)
        let address = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Address' OR label BEGINSWITH 'Show toolbar'")).firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 10), "the browser tab's address bar\n\(app.debugDescription)")
        attach(app, "c1-browser-tab-before-edit")
        let before = isLandscape(app)
        address.tap()
        let field = app.textFields["Search or enter website"].firstMatch
        if !field.waitForExistence(timeout: 3) {
            // A collapsed toolbar's first tap only expands it.
            let expandedAddress = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Address'")).firstMatch
            XCTAssertTrue(expandedAddress.waitForExistence(timeout: 5), "the expanded browser address")
            expandedAddress.tap()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the browser address editor appears\n\(app.debugDescription)")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "editing the address opens the keyboard")
        XCTAssertTrue(isLandscape(app), "focusing the address stays landscape: \(size(app))")
        field.typeText("example.com")
        XCTAssertTrue(waitFor(5) { field.value as? String == "example.com" },
                      "the focused address actually changes to the typed value; got \(String(describing: field.value))")
        attach(app, "c2-address-bar-editing")
        let during = isLandscape(app)
        print("LANDSCAPE c before=\(before) during=\(during) size=\(size(app))")
        XCTAssertTrue(during, "editing the address bar, the window stays landscape: \(size(app))")
        XCTAssertEqual(before, during, "starting the edit does not turn the window (before \(before), during \(during))")
    }

    // MARK: d: wide Ghostty output

    @MainActor
    func testD_WideTerminalOutputPansSideways() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoEmbedded",
                                "-CmuxMobileTerminalDemoPhases", "wide"]
        app.launch()
        defer { app.terminate() }

        let probe = app.staticTexts["debug.terminal-demo"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30), "the terminal demo's probe\n\(app.debugDescription)")
        var demo = wait(probe, timeout: 60) { $0.hasPrefix("wide ready") }
        XCUIDevice.shared.orientation = .landscapeLeft
        _ = waitFor(10) { self.isLandscape(app) }
        demo = wait(probe, timeout: 3) { _ in false }
        attach(app, "d1-wide-output-landscape", probe: probe)
        print("LANDSCAPE d landscape=\(isLandscape(app)) size=\(size(app)) probe=\(demo)")
        XCTAssertTrue(isLandscape(app), "the terminal page is landscape: \(size(app))")

        // d2: a plain left swipe over the output, Wide untouched (Leo's "scrolling to the right does nothing").
        let before = Self.values(demo)
        swipeLeftOverTerminal(app)
        demo = wait(probe, timeout: 1.5) { (Self.values($0)["panX"] ?? 0) > 0 }
        attach(app, "d2-plain-swipe-left", probe: probe)
        let plain = Self.values(demo)
        print("LANDSCAPE d plain before=\(before) after=\(plain)")
        let plainMoved = (plain["panX"] ?? 0) > (before["panX"] ?? 0) || (plain["lastCol"] ?? 0) > (before["lastCol"] ?? 0)
        // Not a gap to close: on the phone's own grid Ghostty rewraps the
        // table to the page's width, so nothing is off screen to pan to. A
        // grid wider than the page (the Mac's under Prefer this Mac, or a
        // full-screen app at the Mac's width) pans under a plain swipe with
        // Wide off (TerminalHostGridLayout.maxPanX follows hostColumns).
        // Recorded, not asserted: whether it moves depends on the grid's width, not on this code.
        print("LANDSCAPE d plain moved=\(plainMoved)")

        // d3: Wide on (the key row's Wide key), then the same swipe. The key
        // row shows only over the soft keyboard (#53325): with the keyboard
        // down there was no Wide key to tap, and the grid stayed the phone's.
        TerminalWideOutputUITests.tapWideKey(app)
        demo = wait(probe, timeout: 15) { (Self.values($0)["cols"] ?? 0) >= 180 }
        let wideStart = Self.values(demo)
        attach(app, "d3-wide-on", probe: probe)
        XCTAssertGreaterThanOrEqual(wideStart["cols"] ?? 0, 180, "Wide gives the mirror the table's width: \(demo)")
        for _ in 0..<4 {
            swipeLeftOverTerminal(app)
            demo = wait(probe, timeout: 1) { (Self.values($0)["lastCol"] ?? 0) >= 178 }
            if (Self.values(demo)["lastCol"] ?? 0) >= 178 { break }
        }
        attach(app, "d4-wide-swiped-to-right-end", probe: probe)
        let panned = Self.values(demo)
        print("LANDSCAPE d wide start=\(wideStart) panned=\(panned) landscape=\(isLandscape(app))")
        XCTAssertGreaterThan(panned["panX"] ?? 0, wideStart["panX"] ?? 0, "a left swipe pans the wide output: \(demo)")
        XCTAssertGreaterThanOrEqual(panned["lastCol"] ?? 0, 178, "the output's right end comes on screen: \(demo)")
        XCTAssertTrue(isLandscape(app), "still landscape after panning: \(size(app))")
    }

    // MARK: e: a wide Markdown table in an agent chat

    @MainActor
    func testE_WideMarkdownTableScrollsSideways() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        // The keyboard closes on send, so nothing has to drag the transcript to put it away.
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "disclosure-chat",
                                "-cmuxMobile.settings.dismissKeyboardAfterSend", "YES"]
        app.launch()
        defer { app.terminate() }

        let bar = app.buttons["Reply to Claude"]
        XCTAssertTrue(bar.waitForExistence(timeout: 30), "the agent chat's composer bar\n\(app.debugDescription)")
        bar.tap()
        let field = app.textViews["chat.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the composer opens\n\(app.debugDescription)")
        for _ in 0..<5 where !((field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false) {
            field.tap()
            _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)],
                                 timeout: 2)
        }
        // The mock agent answers "wide table" with a twelve-column table (MockScript.wideTableAnswer).
        field.typeText("Show me a wide table of the dialer runs")
        app.buttons["Send"].firstMatch.tap()
        let first = app.staticTexts["mac-studio"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 30), "the table's cells arrive\n\(app.debugDescription)")
        _ = app.buttons["Stop"].firstMatch.waitForNonExistence(timeout: 20)
        // No swipeDown here: a drag down on the transcript scrolls it back to older messages
        // (step 224a96b3 landed on the subagent table), and the list drops the off-screen
        // table's cells from the tree, so its header was never found.
        settle(0.5)

        XCUIDevice.shared.orientation = .landscapeLeft
        settle(2.0)
        let landscape = isLandscape(app)
        print("LANDSCAPE e landscape=\(landscape) size=\(size(app))")
        XCTAssertTrue(landscape, "the agent chat turns landscape: \(size(app))")

        let header = app.staticTexts["Run"].firstMatch
        let end = app.staticTexts["END-COLUMN"].firstMatch
        // The turn may leave the list above its end: back to the newest message.
        let jump = app.buttons["Jump to bottom"].firstMatch
        if !header.waitForExistence(timeout: 3), jump.exists { jump.tap(); settle(1.0) }
        XCTAssertTrue(header.waitForExistence(timeout: 10), "the table's first header\n\(app.debugDescription)")
        if !header.isHittable, jump.exists { jump.tap(); settle(1.0) }
        let width = app.windows.firstMatch.frame.width
        let headerBefore = header.frame
        let endBefore = end.exists ? end.frame : .null
        attach(app, "e1-wide-table-before-swipe")
        print("LANDSCAPE e before header=\(headerBefore) end=\(endBefore) window=\(width)")
        XCTAssertGreaterThan(endBefore.maxX, width, "the table is wider than the screen: its last column ends at \(endBefore.maxX), the window is \(width) wide")

        // Swipe left along the table's header row.
        let rowY = headerBefore.midY
        let window = app.windows.firstMatch
        let origin = window.coordinate(withNormalizedOffset: .zero)
        for _ in 0..<3 {
            origin.withOffset(CGVector(dx: width * 0.85, dy: rowY))
                .press(forDuration: 0.02, thenDragTo: origin.withOffset(CGVector(dx: width * 0.10, dy: rowY + 4)),
                       withVelocity: XCUIGestureVelocity(1200), thenHoldForDuration: 0.1)
            settle(0.6)
            if end.exists, end.frame.maxX <= width { break }
        }
        let headerAfter = header.frame
        let endAfter = end.exists ? end.frame : .null
        attach(app, "e2-wide-table-after-swipe")
        print("LANDSCAPE e after header=\(headerAfter) end=\(endAfter)")
        XCTAssertLessThan(headerAfter.minX, headerBefore.minX - 40,
                          "a left swipe scrolls the table sideways: its first header moved from \(headerBefore.minX) to \(headerAfter.minX)")
        XCTAssertLessThan(endAfter.minX, endBefore.minX - 40,
                          "the last column comes in from the right: from \(endBefore.minX) to \(endAfter.minX)")
    }

    // MARK: Driving

    @MainActor
    private func launchTerminalTab() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "ws-terminal-idle"]
        app.launch()
        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "the workspace's terminal tab\n\(app.debugDescription)")
        settle(1.5)
        return app
    }

    /// Turns the phone to landscape and waits for the window to follow.
    @MainActor
    private func turnSideways(_ app: XCUIApplication) -> Bool {
        XCUIDevice.shared.orientation = .landscapeLeft
        let turned = waitFor(10) { self.isLandscape(app) }
        settle(0.8)
        return turned
    }

    /// A quick horizontal drag across the top bar's capsule (TabsKit's toolbar swipe).
    @MainActor
    private func swipeTopBar(_ app: XCUIApplication, toLeft: Bool) {
        let pill = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH 'zsh' OR label BEGINSWITH 'Address' OR label BEGINSWITH 'Show toolbar' OR label BEGINSWITH 'Swift docs' OR label BEGINSWITH 'New session'"
        )).firstMatch
        guard pill.waitForExistence(timeout: 5) else {
            XCTFail("the top bar's capsule\n\(app.debugDescription)")
            return
        }
        let from = pill.coordinate(withNormalizedOffset: CGVector(dx: toLeft ? 0.85 : 0.15, dy: 0.5))
        let to = pill.coordinate(withNormalizedOffset: CGVector(dx: toLeft ? -0.6 : 1.6, dy: 0.5))
        from.press(forDuration: 0.02, thenDragTo: to, withVelocity: .fast, thenHoldForDuration: 0)
    }

    /// Swipes the top bar from the zsh tab to its browser neighbour (Swift docs) and
    /// returns the direction that got there (`toLeft`), or nil. Step ec551b50: a drag
    /// to the left went to the Claude tab, the one before zsh, so the drag to the
    /// right is tried first; from Claude, two drags to the left pass zsh to the docs.
    @MainActor
    private func swipeToBrowserTab(_ app: XCUIApplication) -> Bool? {
        let address = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Address' OR label BEGINSWITH 'Show toolbar'")).firstMatch
        swipeTopBar(app, toLeft: false)
        if address.waitForExistence(timeout: 4) { return false }
        for _ in 0..<2 where !address.exists {
            swipeTopBar(app, toLeft: true)
            _ = address.waitForExistence(timeout: 4)
        }
        return address.exists ? true : nil
    }

    @MainActor
    private func swipeLeftOverTerminal(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.40))
            .press(forDuration: 0.02, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.10, dy: 0.42)),
                   withVelocity: XCUIGestureVelocity(1500), thenHoldForDuration: 0.05)
    }

    @MainActor
    private func isLandscape(_ app: XCUIApplication) -> Bool {
        let frame = app.windows.firstMatch.frame
        return frame.width > frame.height
    }

    @MainActor
    private func size(_ app: XCUIApplication) -> String {
        let frame = app.windows.firstMatch.frame
        return "\(Int(frame.width))x\(Int(frame.height))"
    }

    @MainActor
    private func settle(_ seconds: Double) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor
    private func waitFor(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    /// Reads the probe until `done` holds or `timeout` passes; returns the last label.
    @MainActor
    private func wait(_ probe: XCUIElement, timeout: TimeInterval, until done: (String) -> Bool) -> String {
        var label = probe.label
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !done(label) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            label = probe.label
        }
        return label
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String, probe: XCUIElement? = nil) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "\(name)-\(size(app))"
        shot.lifetime = .keepAlways
        add(shot)
        if let probe, probe.exists {
            let note = XCTAttachment(string: probe.label)
            note.name = name + "-probe"
            note.lifetime = .keepAlways
            add(note)
        }
    }

    /// `key=N` words of the terminal demo's label.
    private static func values(_ label: String) -> [String: Int] {
        var out: [String: Int] = [:]
        for word in label.split(separator: " ") {
            let pair = word.split(separator: "=", maxSplits: 1)
            if pair.count == 2, let value = Int(pair[1]) { out[String(pair[0])] = value }
        }
        return out
    }
}
