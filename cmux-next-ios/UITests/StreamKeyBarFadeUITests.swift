import XCTest

/// A streamed page's key bar (the keys above the keyboard of a browser tab) fades its
/// keys at the scroller's edges like the terminal's key row, instead of cutting them.
/// Drawn by the production `StreamKeyBar` in `-cmux-mobile-recovery-gallery
/// streamkeys[-before|-keyboard|-keyboard-before]`: start, middle and end, with the fade
/// and without it ("before"), light and dark, default and accessibility text sizes.
/// Run with the fleet step's `video` word for a recording of the drags.
final class StreamKeyBarFadeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func launch(_ scene: String, _ look: String, largeText: Bool) -> XCUIApplication {
        XCUIDevice.shared.appearance = look == "dark" ? .dark : .light
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmux-mobile-recovery-gallery", scene, "-cmux-mobile-no-restore",
                                "-cmux-mobile-gallery-appearance", look]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        return app
    }

    /// Drags the bar's keys sideways by most of its width, slowly, and holds so no momentum follows.
    @MainActor
    private func drag(_ bar: XCUIElement, left: Bool) {
        let from = bar.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.8 : 0.15, dy: 0.5))
        let to = bar.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.15 : 0.8, dy: 0.5))
        from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.4)
    }

    @MainActor
    private func rows(_ look: String, largeText: Bool) {
        let size = largeText ? "-ax" : ""
        for (scene, label) in [("streamkeys", "after"), ("streamkeys-before", "before")] {
            let app = launch(scene, look, largeText: largeText)
            let bars = app.otherElements.matching(identifier: "browser.keys")
            XCTAssertTrue(bars.firstMatch.waitForExistence(timeout: 30), "rows\n\(app.debugDescription)")
            shot(app, "rows-\(label)-\(look)\(size)-1")
            app.swipeUp()
            shot(app, "rows-\(label)-\(look)\(size)-2")
            app.terminate()
        }
    }

    @MainActor
    private func keyboard(_ look: String, largeText: Bool) {
        let size = largeText ? "-ax" : ""
        for (scene, label) in [("streamkeys-keyboard", "after"), ("streamkeys-keyboard-before", "before")] {
            let app = launch(scene, look, largeText: largeText)
            let bar = app.otherElements["browser.keys"]
            XCTAssertTrue(bar.waitForExistence(timeout: 30), "key bar\n\(app.debugDescription)")
            shot(app, "keyboard-\(label)-\(look)\(size)-1-start")
            drag(bar, left: true)
            shot(app, "keyboard-\(label)-\(look)\(size)-2-middle")
            drag(bar, left: true)
            drag(bar, left: true)
            shot(app, "keyboard-\(label)-\(look)\(size)-3-end")
            app.terminate()
        }
    }

    @MainActor func testRowsLight() { rows("light", largeText: false) }
    @MainActor func testRowsDark() { rows("dark", largeText: false) }
    @MainActor func testRowsLargeTextLight() { rows("light", largeText: true) }
    @MainActor func testKeyboardLight() { keyboard("light", largeText: false) }
    @MainActor func testKeyboardDark() { keyboard("dark", largeText: false) }
    @MainActor func testKeyboardLargeTextDark() { keyboard("dark", largeText: true) }

    /// For the recording: the live row dragged to the end and back, with the fade.
    @MainActor
    func testScrollVideo() {
        for look in ["light", "dark"] {
            let app = launch("streamkeys-keyboard", look, largeText: false)
            let bar = app.otherElements["browser.keys"]
            XCTAssertTrue(bar.waitForExistence(timeout: 30), "key bar\n\(app.debugDescription)")
            for left in [true, true, true, false, false, false] { drag(bar, left: left) }
            app.terminate()
        }
    }
}
