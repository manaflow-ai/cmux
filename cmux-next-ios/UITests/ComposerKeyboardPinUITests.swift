import XCTest

/// The Chief and terminal composers stay pinned right above the keyboard (verify/keyboard-pin.md):
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
    private func exercise(demo: String, field id: String) throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", demo, "-cmux-mobile-kbd-pin-trace"]
        app.launch()

        let field = app.textViews[id]
        let probe = app.staticTexts["debug.kbd-pin"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "composer field \(id)\n\(app.debugDescription)")
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "the app's keyboard pin probe (-cmux-mobile-kbd-pin-trace)")
        if reading(probe).keyboardTop != nil {
            // A screen that focuses its composer on open: start from rest.
            dismissInteractively(app)
        }
        let rest = reading(probe) { $0.keyboardTop == nil }
        XCTAssertNil(rest.keyboardTop, "keyboard away before the run (\(rest.line))")
        attach(app, "rest")

        // Show: the field settles right above the keyboard.
        field.tap()
        let docked = pinnedGap(probe, "first show")
        attach(app, "shown")

        // Interactive dismissal: back to the same resting place.
        dismissInteractively(app)
        var dismissed = reading(probe) { $0.keyboardTop == nil }
        if dismissed.keyboardTop != nil {
            // A drag that started a text selection in the terminal: once more.
            dismissInteractively(app)
            dismissed = reading(probe) { $0.keyboardTop == nil }
        }
        XCTAssertNil(dismissed.keyboardTop, "dragging the content down takes the keyboard away (\(dismissed.line))")
        XCTAssertEqual(dismissed.fieldBottom, rest.fieldBottom, accuracy: 1, "the field returns to its resting place")
        attach(app, "dismissed")

        // A second show lands on the same gap.
        field.tap()
        XCTAssertEqual(pinnedGap(probe, "second show"), docked, accuracy: 1, "same gap on every show")

        // Rotation and back, keyboard up.
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = reading(probe)
        if landscape.keyboardTop != nil, landscape.docked {
            _ = pinnedGap(probe, "landscape")
        }
        attach(app, "landscape")
        XCUIDevice.shared.orientation = .portrait
        if reading(probe).keyboardTop == nil { field.tap() }
        XCTAssertEqual(pinnedGap(probe, "portrait again"), docked, accuracy: 1, "the gap survives a rotation")
        attach(app, "portrait-again")

        let screen = XCUIScreen.main.screenshot().image.size
        if screen.width > app.windows.firstMatch.frame.width + 1 {
            // A floating keyboard (pinch in) leaves the composer at rest; docking it again re-pins it.
            app.keyboards.firstMatch.pinch(withScale: 0.4, velocity: -1)
            let floating = reading(probe) { !$0.docked }
            if floating.keyboardTop != nil, !floating.docked {
                XCTAssertEqual(floating.fieldBottom, rest.fieldBottom, accuracy: 1, "a floating keyboard leaves the composer at rest (\(floating.line))")
                attach(app, "floating")
                app.keyboards.firstMatch.pinch(withScale: 2.5, velocity: 1)
                XCTAssertEqual(pinnedGap(probe, "docked again"), docked, accuracy: 1, "docking re-pins the composer")
            } else {
                XCTContext.runActivity(named: "keyboard did not float (\(floating.line))") { _ in }
            }
        }
    }

    /// One frame of the app's trace: the keyboard and the field as drawn.
    private struct Reading: Equatable {
        var line: String
        var keyboardTop: CGFloat?
        var fieldBottom: CGFloat
        /// A full-width keyboard (not floating, not split).
        var docked: Bool

        init(_ line: String) {
            self.line = line
            var values: [String: String] = [:]
            for pair in line.split(separator: " ") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { values[String(kv[0])] = String(kv[1]) }
            }
            keyboardTop = values["kb"].flatMap { Double($0) }.map { CGFloat($0) }
            fieldBottom = CGFloat(values["fb"].flatMap { Double($0) } ?? -1)
            let width = values["win"]?.split(separator: "x").first.flatMap { Double($0) } ?? 0
            docked = (values["kbw"].flatMap { Double($0) } ?? 0) >= width - 1
        }

        static func == (a: Reading, b: Reading) -> Bool {
            a.keyboardTop == b.keyboardTop && a.fieldBottom == b.fieldBottom
        }
    }

    /// The probe's reading once the keyboard and the field hold still.
    @MainActor
    /// `until`: first wait (up to the timeout) for a reading that passes it.
    private func reading(_ probe: XCUIElement, timeout: TimeInterval = 5, until: (Reading) -> Bool = { _ in true }) -> Reading {
        let deadline = Date().addingTimeInterval(timeout)
        var last = Reading(probe.value as? String ?? "")
        while Date() < deadline, !until(last) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            last = Reading(probe.value as? String ?? "")
        }
        var stable = 0
        while Date() < deadline, stable < 3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            let now = Reading(probe.value as? String ?? "")
            stable = now == last ? stable + 1 : 0
            last = now
        }
        return last
    }

    /// An iPhone app on an iPad running iOS 27 gets the iPad's own keyboard,
    /// drawn across the iPad's screen outside the app's window; the keyboard
    /// placeholder the probe reads stays at the iPhone keyboard's size there,
    /// so the gap is checked from the simulator's screenshots instead
    /// (verify/keyboard-pin.md, iPad).
    @MainActor
    private var probeReadsKeyboard: Bool {
        // The runner is an iPhone app too, so its idiom reads phone on an
        // iPad: an iPad shows as a screen larger than the app's window.
        let screen = XCUIScreen.main.screenshot().image.size
        let window = XCUIApplication().windows.firstMatch.frame.size
        let onPad = screen.width > window.width + 1 || screen.height > window.height + 1
        return !(onPad && ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27)
    }

    /// The keyboard's top minus the field's bottom, once both are still.
    @MainActor
    private func pinnedGap(_ probe: XCUIElement, _ step: String) -> CGFloat {
        let r = reading(probe) { $0.keyboardTop != nil }
        guard let top = r.keyboardTop else {
            XCTFail("\(step): no keyboard on screen (\(r.line))")
            return -1
        }
        guard probeReadsKeyboard else { return 0 }
        let gap = top - r.fieldBottom
        XCTAssertGreaterThanOrEqual(gap, 0, "\(step): the keyboard covers the field (\(r.line))")
        XCTAssertLessThanOrEqual(gap, 24, "\(step): the field floats \(gap) pt above the keyboard (\(r.line))")
        return gap
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
