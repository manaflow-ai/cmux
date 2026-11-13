import XCTest

/// CMUX-10: the terminal's Jump to bottom button sits centered (as it first
/// shipped, and as the agent chat's jump circle does), in its own row above
/// the key row and below the terminal's rows, not between the key row and the
/// composer,
/// and Settings → Terminal → Jump to Bottom Button removes it. Runs on a
/// workspace's zsh tab with the mock session, whose intro (ls, git log, a
/// build log) leaves scrollback to scroll up into. The full-screen app rule
/// (never in vim) is the pure `JumpToBottomVisibility.showsInTerminal` rule,
/// covered by `TerminalJumpToBottomTests`.
final class TerminalJumpToBottomUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testJumpToBottomIsCentered() throws {
        let app = launch()
        let jump = app.buttons["terminal.jumpToBottom"]
        let field = app.textViews["terminal.composer.field"]

        XCTAssertTrue(scrollUp(app, until: jump), "scrolled up: Jump to bottom shows\n\(app.debugDescription)")
        let window = app.windows.firstMatch.frame
        XCTAssertLessThan(jump.frame.width, window.width / 2, "the element is the pill, not the full-width row")
        XCTAssertEqual(jump.frame.midX, window.midX, accuracy: 2, "Jump to bottom is centered (was trailing)")
        XCTAssertLessThan(jump.frame.maxY, field.frame.minY, "it sits above the composer field")
        let keyRow = app.descendants(matching: .any)["terminal.key.keyboard"]
        XCTAssertTrue(keyRow.exists, "the key row shows\n\(app.debugDescription)")
        XCTAssertLessThanOrEqual(jump.frame.maxY, keyRow.frame.minY,
                                 "Jump to bottom sits above the key row (was between it and the composer): jump \(jump.frame) keys \(keyRow.frame)")
        attach(app, "scrolled-up-centered")

        jump.tap()
        XCTAssertTrue(jump.waitForNonExistence(timeout: 5), "a tap goes to the bottom and hides it")
        attach(app, "after-jump")
    }

    /// Keyboard up, the stack rides the keyboard: the pill stays above the
    /// key row, centered.
    @MainActor
    func testJumpToBottomAboveKeyRowWithKeyboardUp() throws {
        let app = launch()
        let field = app.textViews["terminal.composer.field"]
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the keyboard shows")
        let jump = app.buttons["terminal.jumpToBottom"]
        XCTAssertTrue(scrollUp(app, until: jump), "scrolled up with the keyboard up: Jump to bottom shows\n\(app.debugDescription)")
        let keyRow = app.descendants(matching: .any)["terminal.key.keyboard"]
        XCTAssertLessThanOrEqual(jump.frame.maxY, keyRow.frame.minY, "above the key row: jump \(jump.frame) keys \(keyRow.frame)")
        XCTAssertEqual(jump.frame.midX, app.windows.firstMatch.frame.midX, accuracy: 2, "centered")
        attach(app, "keyboard-up-scrolled-up")
    }

    /// Hide Toolbar folds the key row and the composer; scrolled up, the pill
    /// is the stack's only row, on the solid backing (not over the rows).
    @MainActor
    func testJumpToBottomWithHideToolbar() throws {
        let app = launch()
        let keyboardKey = app.descendants(matching: .any)["terminal.key.keyboard"]
        let hide = app.buttons["Hide Toolbar"]
        let window = app.windows.firstMatch.frame
        let rowY = (keyboardKey.frame.midY - window.minY) / window.height
        for _ in 0..<8 where !(hide.exists && hide.isHittable) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: rowY))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.38, dy: rowY)))
        }
        XCTAssertTrue(hide.waitForExistence(timeout: 5), "Hide Toolbar at the row's end\n\(app.debugDescription)")
        hide.tap()
        XCTAssertTrue(keyboardKey.waitForNonExistence(timeout: 5), "Hide Toolbar hides the key row")
        let jump = app.buttons["terminal.jumpToBottom"]
        XCTAssertTrue(scrollUp(app, until: jump), "scrolled up with the toolbar hidden: Jump to bottom shows\n\(app.debugDescription)")
        XCTAssertEqual(jump.frame.midX, window.midX, accuracy: 2, "centered")
        attach(app, "hide-toolbar-scrolled-up")
        jump.tap()
        XCTAssertTrue(jump.waitForNonExistence(timeout: 5), "a tap goes to the bottom and hides it")
        attach(app, "hide-toolbar-after-jump")
    }

    /// The pill appearing does not move the rows (CMUX-10, "the terminal may
    /// jump when the button is introduced"): the stack grows by the pill's
    /// row, but only the page's bottom inset follows, not its offset. Three
    /// slow drags of the same length end held (no momentum): the first stays
    /// under the show threshold, the second crosses it (the pill appears
    /// mid-drag), the third moves with the pill already shown. The rows move
    /// the same distance in the second and third; a jump would add the row's
    /// 36 pt (108 px) to the second.
    @MainActor
    func testPillAppearingDoesNotMoveRows() throws {
        let app = launch()
        let jump = app.buttons["terminal.jumpToBottom"]
        func drag(points: CGFloat) {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            let end = start.withOffset(CGVector(dx: 0, dy: points))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: XCUIGestureVelocity(120), thenHoldForDuration: 0.6)
        }
        // The mock intro's scrollback is about 200 pt: a build log gives the
        // drags room. Then wait for the output to stop.
        let field = app.textViews["terminal.composer.field"]
        field.tap()
        field.typeText("cargo build")
        app.buttons["terminal.composer.send"].tap()
        dismissKeyboard(app)
        try waitForStill(app, scale: try scale(app))
        drag(points: 50)
        XCTAssertFalse(jump.waitForExistence(timeout: 1), "50 pt up: under the 120 pt threshold, no pill yet")
        let before = app.screenshot()
        drag(points: 140)
        XCTAssertTrue(jump.waitForExistence(timeout: 2), "the second drag crosses the threshold: the pill shows")
        let shown = app.screenshot()
        drag(points: 140)
        XCTAssertTrue(jump.exists, "still shown")
        let after = app.screenshot()
        attach(shown, "pill-appeared-mid-drag")

        let scale = try scale(app)
        let appearing = try rowShift(from: before, to: shown, scale: scale)
        let steady = try rowShift(from: shown, to: after, scale: scale)
        XCTAssertGreaterThan(steady, 80, "the third drag moved the rows (\(steady) pt)")
        XCTAssertEqual(appearing, steady, accuracy: 8,
                       "rows moved \(appearing) pt while the pill appeared vs \(steady) pt with it shown: the pill made the page jump")
    }

    /// The composer's keyboard down, so a drag does not dismiss it and
    /// change the layout between two stills.
    @MainActor
    private func dismissKeyboard(_ app: XCUIApplication) {
        guard app.keyboards.firstMatch.waitForExistence(timeout: 2) else { return }
        app.descendants(matching: .any)["terminal.key.keyboard"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "the keyboard went down")
    }

    @MainActor
    private func scale(_ app: XCUIApplication) throws -> CGFloat {
        CGFloat(try XCTUnwrap(app.screenshot().image.cgImage).height) / app.windows.firstMatch.frame.height
    }

    /// Waits (up to 15 s) until two stills a second apart show the rows in
    /// the same place: the mock intro has finished streaming.
    @MainActor
    private func waitForStill(_ app: XCUIApplication, scale: CGFloat) throws {
        var previous = app.screenshot()
        for _ in 0..<15 {
            Thread.sleep(forTimeInterval: 1)
            let next = app.screenshot()
            if try rowShift(from: previous, to: next, scale: scale) == 0, try meanDifference(previous, next) < 1 { return }
            previous = next
        }
        XCTFail("the terminal kept moving for 15 s")
    }

    @MainActor
    private func meanDifference(_ a: XCUIScreenshot, _ b: XCUIScreenshot) throws -> Double {
        let ga = try gray(a), gb = try gray(b)
        var cost = 0.0, count = 0
        for i in stride(from: 0, to: min(ga.pixels.count, gb.pixels.count), by: 97) {
            cost += Double(abs(Int(ga.pixels[i]) - Int(gb.pixels[i])))
            count += 1
        }
        return cost / Double(max(count, 1))
    }

    /// How far the rows moved down between two stills, in points: the shift
    /// that best overlays the band of rows under the status bar.
    @MainActor
    private func rowShift(from a: XCUIScreenshot, to b: XCUIScreenshot, scale: CGFloat) throws -> CGFloat {
        let ga = try gray(a), gb = try gray(b)
        let width = ga.width, top = Int(120 * scale), bottom = Int(420 * scale), maxShift = Int(300 * scale)
        var best = (shift: 0, cost: Double.infinity)
        for shift in 0...maxShift {
            var cost = 0.0, count = 0
            for y in stride(from: top, to: bottom, by: 3) where y + shift < gb.height {
                for x in stride(from: 0, to: width, by: 6) {
                    cost += Double(abs(Int(ga.pixels[y * width + x]) - Int(gb.pixels[(y + shift) * width + x])))
                    count += 1
                }
            }
            let mean = cost / Double(max(count, 1))
            if mean < best.cost { best = (shift, mean) }
        }
        return CGFloat(best.shift) / scale
    }

    @MainActor
    private func gray(_ shot: XCUIScreenshot) throws -> (pixels: [UInt8], width: Int, height: Int) {
        let image = try XCTUnwrap(shot.image.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (pixels, width, height)
    }

    @MainActor
    private func attach(_ shot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A tap scrolls to the bottom (an animated glide, recorded by the run's
    /// video), lands on the newest line, and hides the pill. Scrolled up
    /// through a build log, so the glide covers more than a screen.
    @MainActor
    func testJumpToBottomGlidesToTheEnd() throws {
        let app = launch()
        let field = app.textViews["terminal.composer.field"]
        field.tap()
        field.typeText("cargo build")
        app.buttons["terminal.composer.send"].tap()
        dismissKeyboard(app)
        try waitForStill(app, scale: try scale(app))
        let atBottom = app.screenshot()
        let jump = app.buttons["terminal.jumpToBottom"]
        for _ in 0..<3 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)),
                       withVelocity: XCUIGestureVelocity(800), thenHoldForDuration: 0.3)
        }
        XCTAssertTrue(jump.waitForExistence(timeout: 3), "scrolled up: the pill shows")
        attach(app, "glide-start")
        jump.tap()
        XCTAssertTrue(jump.waitForNonExistence(timeout: 5), "the pill hides")
        try waitForStill(app, scale: try scale(app))
        let landed = app.screenshot()
        attach(landed, "glide-landed")
        XCTAssertEqual(try rowShift(from: atBottom, to: landed, scale: try scale(app)), 0, "landed back at the bottom")
        XCTAssertLessThan(try meanDifference(atBottom, landed), 3, "the same rows as before scrolling up")
    }

    @MainActor
    func testSettingOffRemovesJumpToBottom() throws {
        // Control: with the setting on, the same scroll shows it.
        let on = launch()
        XCTAssertTrue(scrollUp(on, until: on.buttons["terminal.jumpToBottom"]), "control: shows with the setting on")
        on.terminate()

        let app = launch(extraArguments: ["-cmuxMobile.settings.terminalJumpToBottom", "NO"])
        let jump = app.buttons["terminal.jumpToBottom"]
        XCTAssertFalse(scrollUp(app, until: jump), "Settings → Terminal → Jump to Bottom Button off removes it")
        attach(app, "setting-off-scrolled-up")
    }

    @MainActor
    private func launch(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "ws-terminal-idle"] + extraArguments
        app.launch()
        XCTAssertTrue(app.textViews["terminal.composer.field"].waitForExistence(timeout: 20), "composer field\n\(app.debugDescription)")
        return app
    }

    /// Drags the rows down (content scrolls up) until `target` shows: up to
    /// 12 drags, each followed by a short wait on the element itself, so the
    /// mock intro's scrollback has time to stream in.
    @MainActor
    private func scrollUp(_ app: XCUIApplication, until target: XCUIElement) -> Bool {
        for _ in 0..<12 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)))
            if target.waitForExistence(timeout: 1) { return true }
        }
        return false
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
