import XCTest

/// Leo, 2026-11-23 (paraphrased): scrolling to the right on extra wide
/// terminal output does nothing; an extra wide table just doesn't work, and
/// didn't before either, so the phone needs a way to scroll sideways.
///
/// The terminal demo's `wide` phase prints a table 180 columns wide (each row
/// ends in `END` at column 180) on a phone that fits about 50. This test turns
/// on Wide in the key row (over the keyboard), swipes left over the terminal and checks that the
/// rows' right ends come on screen: the mirror is wider than the phone, the
/// page panned, and the last column on screen reaches the table's end. A
/// mostly vertical drag then leaves the sideways pan where it was (axis lock).
/// Screenshots at each step.
final class TerminalWideOutputUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testAWideTablePansSidewaysToItsRightEnd() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoEmbedded",
                                "-CmuxMobileTerminalDemoPhases", "wide"]
        app.launch()
        defer { app.terminate() }

        let probe = app.staticTexts["debug.terminal-demo"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30), "the terminal demo's step label\n\(app.debugDescription)")
        var demo = wait(probe, timeout: 60) { $0.hasPrefix("wide ready") }
        XCTAssertTrue(demo.hasPrefix("wide ready"), "the wide table is printed: \(demo)")
        attach(app, "1-phone-width")
        let phone = Self.values(demo)["phone"] ?? 0
        XCTAssertGreaterThan(phone, 0, "the phone's columns are known: \(demo)")
        XCTAssertLessThan(phone, 180, "the table is wider than the phone: \(demo)")

        Self.tapWideKey(app)

        demo = wait(probe, timeout: 15) { (Self.values($0)["cols"] ?? 0) >= 180 }
        attach(app, "2-wide-at-the-left-edge")
        XCTAssertGreaterThanOrEqual(Self.values(demo)["cols"] ?? 0, 180, "Wide gives the mirror the table's width: \(demo)")
        XCTAssertGreaterThan(Self.values(demo)["maxPanX"] ?? 0, 0, "the page pans sideways: \(demo)")

        // Sideways drags over the terminal, a little off horizontal as a thumb drags.
        let window = app.windows.firstMatch
        for _ in 0..<4 {
            let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.40))
            let to = window.coordinate(withNormalizedOffset: CGVector(dx: 0.10, dy: 0.42))
            from.press(forDuration: 0.02, thenDragTo: to, withVelocity: XCUIGestureVelocity(1500), thenHoldForDuration: 0.05)
            demo = wait(probe, timeout: 1) { (Self.values($0)["lastCol"] ?? 0) >= 178 }
            if (Self.values(demo)["lastCol"] ?? 0) >= 178 { break }
        }
        attach(app, "3-panned-to-the-right-end")
        let panned = Self.values(demo)
        XCTAssertGreaterThan(panned["panX"] ?? 0, 0, "a sideways swipe panned the page: \(demo)")
        XCTAssertGreaterThanOrEqual(panned["lastCol"] ?? 0, 178, "the table's right-hand columns are on screen: \(demo)")

        // Axis lock: a mostly vertical drag scrolls rows, not sideways.
        let top = window.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.30))
        let bottom = window.coordinate(withNormalizedOffset: CGVector(dx: 0.53, dy: 0.55))
        top.press(forDuration: 0.02, thenDragTo: bottom, withVelocity: XCUIGestureVelocity(600), thenHoldForDuration: 0.3)
        demo = wait(probe, timeout: 1) { _ in false }
        attach(app, "4-after-a-vertical-drag")
        let after = Self.values(demo)
        XCTAssertLessThanOrEqual(abs((after["panX"] ?? 0) - (panned["panX"] ?? 0)), 2,
                                 "a vertical drag kept the sideways pan: before \(panned["panX"] ?? -1), after \(demo)")
    }

    /// Typing in Wide follows the cursor sideways: a paste of 120 columns at
    /// the prompt carries the cursor far right of a page that fits about 50,
    /// and the page pans so its column is on screen. The pan runs again when
    /// the echo is drawn: the input alone (before its echo) still had the
    /// cursor at the prompt's start, so only following the echo shows it.
    @MainActor
    func testTypingInWidePansToTheCursor() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoEmbedded",
                                "-CmuxMobileTerminalDemoPhases", "wide", "-CmuxMobileTerminalDemoWideType"]
        app.launch()
        defer { app.terminate() }

        let probe = app.staticTexts["debug.terminal-demo"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30), "the terminal demo's step label\n\(app.debugDescription)")
        let demo = wait(probe, timeout: 90) { $0.hasPrefix("wide typed") }
        attach(app, "wide-typed-pans-to-the-cursor")
        XCTAssertTrue(demo.hasPrefix("wide typed"), "the paste was typed: \(demo)")
        let typed = Self.values(demo)
        let cursor = typed["cursorCol"] ?? -1
        XCTAssertGreaterThan(typed["maxPanX"] ?? 0, 0, "Wide is on and the page pans: \(demo)")
        XCTAssertGreaterThan(cursor, typed["phone"] ?? Int.max, "the cursor went past the phone's width: \(demo)")
        XCTAssertGreaterThan(typed["panX"] ?? 0, 0, "the page panned after the echo: \(demo)")
        XCTAssertTrue((typed["firstCol"] ?? Int.max) <= cursor && cursor < (typed["lastCol"] ?? 0),
                      "the cursor's column is on screen: \(demo)")
    }

    /// The gallery's other variants, as screenshots: (b) Wide View, the
    /// dedicated view (the page menu's Wide View: Wide on, the key row and
    /// composer away), at its left edge and panned to the right end; (c) the
    /// same turned to landscape. Rotation itself belongs to the landscape
    /// work (`lane/ios-first-frame-landscape`): this only records what the
    /// build shows, and asserts only the portrait steps.
    @MainActor
    func testWideViewGallery() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoEmbedded",
                                "-CmuxMobileTerminalDemoPhases", "wide", "-CmuxMobileTerminalDemoWideView"]
        app.launch()
        defer {
            XCUIDevice.shared.orientation = .portrait
            app.terminate()
        }

        let probe = app.staticTexts["debug.terminal-demo"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30), "the terminal demo's step label")
        var demo = wait(probe, timeout: 60) { $0.hasPrefix("wide ready") && (Self.values($0)["cols"] ?? 0) >= 180 }
        attach(app, "gallery-b1-wide-view")
        XCTAssertGreaterThanOrEqual(Self.values(demo)["cols"] ?? 0, 180, "Wide View is wide: \(demo)")
        XCTAssertFalse(app.buttons["terminal.key.wide"].isHittable, "Wide View hides the key row")

        let window = app.windows.firstMatch
        for _ in 0..<4 {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.40))
                .press(forDuration: 0.02, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.10, dy: 0.42)),
                       withVelocity: XCUIGestureVelocity(1500), thenHoldForDuration: 0.05)
            demo = wait(probe, timeout: 1) { (Self.values($0)["lastCol"] ?? 0) >= 178 }
            if (Self.values(demo)["lastCol"] ?? 0) >= 178 { break }
        }
        attach(app, "gallery-b2-wide-view-right-end")
        XCTAssertGreaterThanOrEqual(Self.values(demo)["lastCol"] ?? 0, 178, "Wide View pans to the right end: \(demo)")

        XCUIDevice.shared.orientation = .landscapeLeft
        _ = wait(probe, timeout: 2) { _ in false }
        attach(app, "gallery-c-wide-view-landscape")
    }

    /// Turns on Wide from the key row. The row shows only over the soft
    /// keyboard (#53325), so a tap on the composer raises both first; Wide
    /// sits at the row's end, by the zoom keys, so the row is scrolled to it.
    /// The keyboard goes down again after (its key), so the terminal has the
    /// page's height for the swipes that follow (in landscape the keyboard
    /// leaves only a strip of rows).
    @MainActor
    static func tapWideKey(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the terminal's composer\n\(app.debugDescription)", file: file, line: line)
        field.tap()
        let wideKey = app.buttons["terminal.key.wide"]
        XCTAssertTrue(wideKey.waitForExistence(timeout: 10), "the key row (over the keyboard) has a Wide key\n\(app.debugDescription)",
                      file: file, line: line)
        let keyRow = app.buttons["terminal.key.escape"]
        var swipes = 0
        while !wideKey.isHittable, swipes < 10 {
            (keyRow.exists ? keyRow : app.windows.firstMatch).swipeLeft()
            swipes += 1
        }
        XCTAssertTrue(wideKey.isHittable, "the Wide key is on screen after \(swipes) swipes of the key row", file: file, line: line)
        wideKey.tap()
        // The keyboard key sits at the row's leading edge, outside its scroller.
        let keyboardKey = app.descendants(matching: .any)["terminal.key.keyboard"]
        if app.keyboards.firstMatch.exists, keyboardKey.isHittable {
            keyboardKey.tap()
            _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)
        }
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
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let note = XCTAttachment(string: app.staticTexts["debug.terminal-demo"].label)
        note.name = name + "-probe"
        note.lifetime = .keepAlways
        add(note)
    }

    /// `key=N` words of the demo's label.
    private static func values(_ label: String) -> [String: Int] {
        var out: [String: Int] = [:]
        for word in label.split(separator: " ") {
            let pair = word.split(separator: "=", maxSplits: 1)
            if pair.count == 2, let value = Int(pair[1]) { out[String(pair[0])] = value }
        }
        return out
    }
}
