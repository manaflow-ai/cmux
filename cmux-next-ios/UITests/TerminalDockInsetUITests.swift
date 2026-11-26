import XCTest

/// The terminal's bottom dock (key row and composer) on load, on reattach,
/// with the keyboard up and down, through a rotation and back from the
/// background. Leo, 2026-11-17: "The reconnect takes an extra line and the
/// freaking built in keyboard accounting is there when I'm loading back in
/// even when there's no keyboard!"
///
/// Two geometry rules, read from the app's own keyboard pin probe
/// (`-cmux-mobile-kbd-pin-trace`, verify/keyboard-pin.md):
/// - no keyboard drawn means no keyboard inset: the dock's guide (`dg`) is
///   at the window's bottom edge, so the key row and composer rest on the
///   toolbar line;
/// - a reattach adds no row: the key row to composer distance is the same
///   while the link is down as while it is up (the state is in the title
///   pill's subtitle; Reconnect is in the page menu).
///
/// Each step attaches a screenshot (load, keyboard up and down, return from
/// the background, rotation, reattach) for the pull request.
final class TerminalDockInsetUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testNoKeyboardInsetWithoutAKeyboard() throws {
        XCUIDevice.shared.orientation = .portrait
        let (app, probe) = launch(demo: "ws-terminal-idle")
        let field = app.textViews["terminal.composer.field"]
        let keyboardKey = app.buttons["terminal.key.keyboard"]

        let rest = assertNoInset(probe, "load")
        attach(app, "1-load")

        // Keyboard up: the dock rides it.
        field.tap()
        let up = reading(probe) { $0.keyboardTop != nil }
        XCTAssertNotNil(up.keyboardTop, "keyboard up (\(up.line))")
        if let top = up.keyboardTop, let guide = up.dockGuide {
            XCTAssertEqual(guide, top, accuracy: 1, "the dock's guide is the keyboard's top (\(up.line))")
        }
        attach(app, "2-keyboard-up")

        // Keyboard down with the key row's keyboard key: back on the toolbar line.
        XCTAssertTrue(keyboardKey.waitForExistence(timeout: 5))
        keyboardKey.tap()
        let down = assertNoInset(probe, "keyboard down")
        XCTAssertEqual(down.fieldBottom, rest.fieldBottom, accuracy: 1, "the composer returns to its resting place (\(down.line))")
        attach(app, "3-keyboard-down")

        // Rotation with the keyboard down: no inset either way.
        XCUIDevice.shared.orientation = .landscapeLeft
        _ = assertNoInset(probe, "landscape")
        attach(app, "4-landscape")
        XCUIDevice.shared.orientation = .portrait
        let back = assertNoInset(probe, "portrait again")
        XCTAssertEqual(back.fieldBottom, rest.fieldBottom, accuracy: 1, "the composer rests where it did before the rotation (\(back.line))")
        attach(app, "5-portrait-again")

        // Keyboard up through a rotation, then down: no inset left behind.
        field.tap()
        _ = reading(probe) { $0.keyboardTop != nil }
        XCUIDevice.shared.orientation = .landscapeLeft
        _ = reading(probe)
        attach(app, "6-landscape-keyboard-up")
        XCUIDevice.shared.orientation = .portrait
        _ = reading(probe)
        if keyboardKey.exists, keyboardKey.isHittable { keyboardKey.tap() }
        let settled = assertNoInset(probe, "keyboard down after a rotation")
        XCTAssertEqual(settled.fieldBottom, rest.fieldBottom, accuracy: 1, "(\(settled.line))")
        attach(app, "7-rotated-keyboard-down")
    }

    /// Back from the background ("loading back in"): whatever the keyboard
    /// did meanwhile, the dock follows the keyboard on screen now.
    @MainActor
    func testNoKeyboardInsetAfterTheBackground() throws {
        XCUIDevice.shared.orientation = .portrait
        let (app, probe) = launch(demo: "ws-terminal-idle")
        let field = app.textViews["terminal.composer.field"]
        let rest = assertNoInset(probe, "load")

        // Keyboard down, background, back.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
        app.activate()
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        let back = assertNoInset(probe, "back from the background, keyboard down")
        XCTAssertEqual(back.fieldBottom, rest.fieldBottom, accuracy: 1, "(\(back.line))")
        attach(app, "1-back-keyboard-down")

        // Keyboard up, background, back: the keyboard may come back with the
        // app or not; either way the dock matches what is on screen.
        field.tap()
        _ = reading(probe) { $0.keyboardTop != nil }
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
        app.activate()
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        let returned = reading(probe)
        attach(app, "2-back-keyboard-was-up")
        if returned.keyboardTop == nil {
            _ = assertNoInset(probe, "back from the background, keyboard gone")
        } else if let top = returned.keyboardTop, let guide = returned.dockGuide {
            XCTAssertEqual(guide, top, accuracy: 1, "the dock rides the keyboard that came back (\(returned.line))")
        }
    }

    /// A reattach past the quiet bound: the title pill keeps its usual words (no
    /// "Reattaching…": Leo, 2026-11-24, "all the connecting... indicators ... nah let's
    /// not do that"), the dock keeps its rows, and Reconnect in the page menu ends it.
    @MainActor
    func testReattachTakesNoRow() throws {
        XCUIDevice.shared.orientation = .portrait
        let (app, probe) = launch(demo: "ws-terminal-reattach")
        let field = app.textViews["terminal.composer.field"]
        let control = app.buttons["terminal.key.control"]
        XCTAssertTrue(control.waitForExistence(timeout: 10))
        // Within the quiet bound (10 s) nothing has changed on screen yet.
        let attachedGap = field.frame.minY - control.frame.maxY
        let attachedBottom = field.frame.maxY
        attach(app, "1-attached")

        // On purpose (Leo's item 3): past the quiet bound the pill still says no waiting word.
        let waiting = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "Reattaching", "Connecting")).firstMatch
        XCTAssertFalse(waiting.waitForExistence(timeout: 14), "the title pill says a waiting word past the quiet bound\n\(app.debugDescription)")
        attach(app, "2-reattaching")
        let gap = field.frame.minY - control.frame.maxY
        XCTAssertEqual(gap, attachedGap, accuracy: 1, "a reattach adds no row between the key row and the composer")
        XCTAssertEqual(field.frame.maxY, attachedBottom, accuracy: 1, "nor moves the composer")
        XCTAssertFalse(app.otherElements["terminal.connectionLine"].exists, "no connection line by the composer")
        _ = assertNoInset(probe, "reattaching")

        // Reconnect, from the page menu (no layout space while the link is down).
        // A terminal's title pill (its tab title, "zsh") opens its page menu.
        let pill = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "zsh")).firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "the title pill\n\(app.debugDescription)")
        pill.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let reconnect = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reconnect")).firstMatch
        XCTAssertTrue(reconnect.waitForExistence(timeout: 5), "Reconnect in the page menu\n\(app.debugDescription)")
        attach(app, "3-page-menu-reconnect")
        reconnect.tap()
        XCTAssertTrue(reconnect.waitForNonExistence(timeout: 5), "attached again: the menu closes")
        attach(app, "4-reconnected")
    }

    // MARK: Helpers

    @MainActor
    private func launch(demo: String) -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", demo, "-cmux-mobile-kbd-pin-trace"]
        app.launch()
        let field = app.textViews["terminal.composer.field"]
        let probe = app.staticTexts["debug.kbd-pin"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "composer field\n\(app.debugDescription)")
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "the app's keyboard pin probe")
        return (app, probe)
    }

    /// No keyboard is drawn, and the dock's guide is at the window's bottom.
    @MainActor
    @discardableResult
    private func assertNoInset(_ probe: XCUIElement, _ step: String) -> Reading {
        let r = reading(probe) { $0.keyboardTop == nil && ($0.dockGuide ?? 0) >= $0.windowHeight - 0.5 }
        XCTAssertNil(r.keyboardTop, "\(step): a keyboard is on screen (\(r.line))")
        guard let guide = r.dockGuide else {
            XCTFail("\(step): no dock guide in the probe (\(r.line))")
            return r
        }
        XCTAssertGreaterThanOrEqual(guide, r.windowHeight - 0.5,
                                    "\(step): a \(r.windowHeight - guide) pt keyboard inset with no keyboard (\(r.line))")
        return r
    }

    private struct Reading: Equatable {
        var line: String
        var keyboardTop: CGFloat?
        var fieldBottom: CGFloat
        var dockGuide: CGFloat?
        var windowHeight: CGFloat

        init(_ line: String) {
            self.line = line
            var values: [String: String] = [:]
            for pair in line.split(separator: " ") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { values[String(kv[0])] = String(kv[1]) }
            }
            keyboardTop = values["kb"].flatMap { Double($0) }.map { CGFloat($0) }
            fieldBottom = CGFloat(values["fb"].flatMap { Double($0) } ?? -1)
            dockGuide = values["dg"].flatMap { Double($0) }.map { CGFloat($0) }
            windowHeight = CGFloat(values["win"]?.split(separator: "x").last.flatMap { Double($0) } ?? 0)
        }

        static func == (a: Reading, b: Reading) -> Bool {
            a.keyboardTop == b.keyboardTop && a.fieldBottom == b.fieldBottom && a.dockGuide == b.dockGuide
        }
    }

    /// The probe's reading once it holds still; first waits (up to the
    /// timeout) for one that passes `until`.
    @MainActor
    private func reading(_ probe: XCUIElement, timeout: TimeInterval = 6, until: (Reading) -> Bool = { _ in true }) -> Reading {
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

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
