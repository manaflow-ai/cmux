import XCTest

/// Leo, 2026-11-22, on the key row's agent launchers sitting right after the
/// arrows and pressing Return on one tap: "surely we can think of more
/// ergonomic ways to do things...?", and the keyboard hiding; he picked
/// option B of the debate (cmux#50880). The row now has nothing but keys
/// next to the arrows, the launchers last after a hairline, a launcher tap
/// that only types (long-press: Run Now), 44 pt hit areas, and one keyboard
/// key at the trailing edge (long-press: Hide Toolbar Too). Each state is
/// shot in dark and light (`keyrow-*` attachments).
final class KeyRowLaunchersLastUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(_ arguments: [String], dark: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-AppleInterfaceStyle", dark ? "Dark" : "Light"] + arguments
        app.launch()
        return app
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "keyrow-\(name)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Drags the scroller (between the pinned keys) toward its end until `key` is hittable.
    private func scroll(_ app: XCUIApplication, row keyboardKey: XCUIElement, until key: XCUIElement) {
        let window = app.windows.firstMatch.frame
        let rowY = (keyboardKey.frame.midY - window.minY) / window.height
        for _ in 0..<10 where !(key.exists && key.isHittable) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: rowY))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: rowY)))
        }
    }

    @MainActor
    func testLaunchersAreLastAndTheKeyboardKeyIsTrailing() {
        for dark in [true, false] {
            let style = dark ? "dark" : "light"
            let app = launch(["-cmux-mobile-demo", "ws-terminal-idle"], dark: dark)
            let keyboardKey = app.buttons["terminal.key.keyboard"]
            let control = app.buttons["terminal.key.control"]
            let right = app.buttons["terminal.key.right"]
            XCTAssertTrue(keyboardKey.waitForExistence(timeout: 30), "key row\n\(app.debugDescription)")
            XCTAssertTrue(control.exists, "the scroller starts with ⌃")
            // One keyboard control, at the trailing edge; Hide Toolbar is no longer a key.
            XCTAssertGreaterThan(keyboardKey.frame.minX, app.frame.width * 0.75, "keyboard key at the trailing edge")
            XCTAssertFalse(app.buttons["terminal.key.hide-chrome"].exists, "no Hide Toolbar key")
            XCTAssertFalse(app.buttons["terminal.keyboardToggle"].exists, "no second keyboard toggle")
            // 44 pt wide hit areas (Apple HIG, Accessibility).
            XCTAssertGreaterThanOrEqual(control.frame.width, 44, "⌃'s hit area")
            XCTAssertGreaterThanOrEqual(keyboardKey.frame.width, 44, "the keyboard key's hit area")
            shoot(app, "rest-\(style)")

            // Next to → is a key, never a launcher.
            scroll(app, row: keyboardKey, until: right)
            XCTAssertTrue(right.exists, "→ in the row\n\(app.debugDescription)")
            XCTAssertGreaterThanOrEqual(right.frame.width, 44, "→'s hit area")
            let afterRight = app.buttons.allElementsBoundByIndex.filter {
                $0.identifier.hasPrefix("terminal.key.") && $0.frame.minX >= right.frame.maxX - 1
                    && abs($0.frame.midY - right.frame.midY) < 4
            }.min { $0.frame.minX < $1.frame.minX }
            if let next = afterRight {
                XCTAssertFalse(next.identifier.hasPrefix("terminal.key.launcher-"), "the key after → is \(next.identifier)")
            }
            shoot(app, "arrows-\(style)")

            // The launchers come last, after the zoom keys.
            let claude = app.buttons["terminal.key.launcher-claude"]
            let zoomIn = app.buttons["terminal.key.zoom-in"]
            scroll(app, row: keyboardKey, until: app.buttons["terminal.key.launcher-ollama"])
            XCTAssertTrue(claude.exists && zoomIn.exists, "the row's end\n\(app.debugDescription)")
            if claude.exists, zoomIn.exists {
                XCTAssertGreaterThan(claude.frame.minX, zoomIn.frame.maxX, "Claude comes after zoom")
            }
            shoot(app, "launchers-\(style)")

            // A launcher's long-press offers Run Now; a tap only types.
            if claude.exists {
                claude.press(forDuration: 1.2)
                let run = app.buttons["Run Now"]
                XCTAssertTrue(run.waitForExistence(timeout: 5), "Run Now on long-press\n\(app.debugDescription)")
                shoot(app, "launcher-menu-\(style)")
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
            }

            // The keyboard key's long-press: Hide Toolbar Too folds the dock.
            keyboardKey.press(forDuration: 1.2)
            let hide = app.buttons["Hide Toolbar Too"]
            XCTAssertTrue(hide.waitForExistence(timeout: 5), "Hide Toolbar Too on long-press\n\(app.debugDescription)")
            shoot(app, "keyboard-menu-\(style)")
            if hide.exists {
                hide.tap()
                XCTAssertTrue(control.waitForNonExistence(timeout: 5), "Hide Toolbar Too hides the key row")
                shoot(app, "hidden-\(style)")
            }
            app.terminate()
        }
    }

    /// The key row gallery (`TerminalKeyBarGallery`): each layout at rest and whole.
    @MainActor
    func testKeyBarGallery() {
        for dark in [true, false] {
            let app = launch(["-cmux-mobile-recovery-gallery", "keybar"], dark: dark)
            let row = app.descendants(matching: .any)["keyBarGallery.agentsLast"]
            XCTAssertTrue(row.waitForExistence(timeout: 30), "the gallery\n\(app.debugDescription)")
            shoot(app, "gallery-\(dark ? "dark" : "light")")
            app.terminate()
        }
    }
}
