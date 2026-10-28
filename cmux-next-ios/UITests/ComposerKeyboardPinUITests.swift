import XCTest

/// Every composer stays pinned right above the keyboard (verify/keyboard-pin.md):
/// the same gap after the keyboard shows, after an interactive dismissal and a
/// second show, through a rotation and back, and, on iPad, a floating keyboard
/// leaves the composer at its resting place until the keyboard docks again.
/// Frame-by-frame motion is measured from the app's own trace
/// (`-cmux-mobile-kbd-pin-trace`, `verify/scripts/kbd_pin_trace.py`); this test
/// checks where each step settles, with real touches on the real screens
/// (mock sign-in, mock sessions).
final class ComposerKeyboardPinUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testChiefComposerStaysOnKeyboard() throws {
        try exercise(demo: "chief-open", field: "conversation.composer.text")
    }

    @MainActor
    func testTerminalComposerStaysOnKeyboard() throws {
        try exercise(demo: "ws-terminal-idle", field: "terminal.composer.field")
    }

    @MainActor
    func testAgentChatComposerStaysOnKeyboard() throws {
        try exercise(demo: "kbd-chat", field: "chat.composer.field")
    }

    @MainActor
    private func exercise(demo: String, field id: String) throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", demo, "-cmux-mobile-kbd-pin-trace"]
        app.launch()

        let field = app.textViews[id]
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30), "composer field \(id)\n\(app.debugDescription)")
        if keyboard.exists {
            // A screen that focuses its composer on open: start from rest.
            dismissInteractively(app)
            XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5), "keyboard away before the run")
        }
        let rest = settledFrame(of: field)
        attach(app, "rest")

        // Show: the field settles right above the keyboard.
        field.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "tapping the field shows the keyboard")
        let docked = try pinnedGap(field, keyboard, "first show")
        attach(app, "shown")

        // Interactive dismissal: back to the same resting place.
        dismissInteractively(app)
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5), "dragging the content down takes the keyboard away")
        XCTAssertEqual(settledFrame(of: field).maxY, rest.maxY, accuracy: 1, "the field returns to its resting place")
        attach(app, "dismissed")

        // A second show lands on the same gap.
        field.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "the field still brings the keyboard back")
        XCTAssertEqual(try pinnedGap(field, keyboard, "second show"), docked, accuracy: 1, "same gap on every show")

        // Rotation and back, keyboard up.
        XCUIDevice.shared.orientation = .landscapeLeft
        if keyboard.waitForExistence(timeout: 5) {
            _ = try pinnedGap(field, keyboard, "landscape")
        }
        attach(app, "landscape")
        XCUIDevice.shared.orientation = .portrait
        if !keyboard.waitForExistence(timeout: 3) { field.tap() }
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "keyboard back in portrait")
        XCTAssertEqual(try pinnedGap(field, keyboard, "portrait again"), docked, accuracy: 1, "the gap survives a rotation")
        attach(app, "portrait-again")

        if UIDevice.current.userInterfaceIdiom == .pad {
            // A floating keyboard (pinch in) leaves the composer at rest; docking it again re-pins it.
            keyboard.pinch(withScale: 0.4, velocity: -1)
            let floated = settledFrame(of: keyboard)
            if floated.width < app.windows.firstMatch.frame.width - 1 {
                XCTAssertEqual(settledFrame(of: field).maxY, rest.maxY, accuracy: 1, "a floating keyboard leaves the composer at rest")
                attach(app, "floating")
                keyboard.pinch(withScale: 2.5, velocity: 1)
                _ = settledFrame(of: keyboard)
                XCTAssertEqual(try pinnedGap(field, keyboard, "docked again"), docked, accuracy: 1, "docking re-pins the composer")
            } else {
                XCTContext.runActivity(named: "keyboard did not float (\(floated))") { _ in }
            }
        }
    }

    /// The keyboard's top minus the field's bottom, once both are still.
    @MainActor
    private func pinnedGap(_ field: XCUIElement, _ keyboard: XCUIElement, _ step: String) throws -> CGFloat {
        let kb = settledFrame(of: keyboard)
        let fieldFrame = settledFrame(of: field)
        let gap = kb.minY - fieldFrame.maxY
        XCTAssertGreaterThanOrEqual(gap, 0, "\(step): the keyboard covers the field (field \(fieldFrame), keyboard \(kb))")
        XCTAssertLessThanOrEqual(gap, 40, "\(step): the field floats \(gap) pt above the keyboard (field \(fieldFrame), keyboard \(kb))")
        return gap
    }

    /// An element's frame once it holds still for a few polls.
    @MainActor
    private func settledFrame(of element: XCUIElement, timeout: TimeInterval = 4) -> CGRect {
        var last = element.frame
        var stable = 0
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, stable < 3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            let now = element.exists ? element.frame : .zero
            stable = now == last ? stable + 1 : 0
            last = now
        }
        return last
    }

    @MainActor
    private func dismissInteractively(_ app: XCUIApplication) {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.995))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.1)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
