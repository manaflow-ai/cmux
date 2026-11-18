import XCTest

/// Screenshots of the three review variants of where an agent terminal's Chat / Terminal swap
/// lives (`TerminalChatToggleVariant`, ask-1105ee4cc6), in dark and light, from the DEBUG gallery
/// (`TerminalChatToggleGalleryRoot`): the production tabs chrome and terminal page on a mock Codex
/// session. Each still is a kept attachment named `toggle-<variant>-<look>-<state>`.
///
/// - menu: the page as it opens (nothing on it), then the page menu with Show Chat leading.
/// - navbar: the page with the small Chat button, then after a tap (the chat face).
/// - gesture: the page with its first-show hint, the page once the hint has gone, then after a
///   swipe in from the trailing edge (the chat face).
final class TerminalChatToggleVariantsCaptureUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    private func launch(_ variant: String, dark: Bool) -> XCUIApplication {
        XCUIDevice.shared.appearance = dark ? .dark : .light
        let app = XCUIApplication()
        app.launchArguments += [
            "-cmux-mobile-terminal-chat-toggle-gallery",
            "-cmux-mobile-terminal-chat-toggle-variant", variant,
            "-cmuxMobile.settings.terminalChatToggle", "YES",
            "-cmux-mobile-term-fake-codex-idle",
            "-cmuxMobile.setupComplete", "YES",
        ]
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launch()
        XCTAssertTrue(app.otherElements["terminalChatToggleGallery"].waitForExistence(timeout: 20)
            || app.buttons["Page Menu"].waitForExistence(timeout: 10), "gallery did not draw")
        return app
    }

    @MainActor
    private func keep(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func settle(_ seconds: TimeInterval) {
        // A bounded wait for the terminal to draw; the mock session has no signal to wait on.
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor
    func testMenuVariant() {
        for dark in [true, false] {
            let look = dark ? "dark" : "light"
            let app = launch("menu", dark: dark)
            settle(2.5)
            keep("toggle-menu-\(look)-page")
            let menu = app.buttons["Page Menu"].firstMatch
            if menu.waitForExistence(timeout: 5) {
                menu.tap()
                settle(1.2)
                XCTAssertTrue(app.buttons["Show Chat"].waitForExistence(timeout: 5), "no Show Chat row (\(look))")
                keep("toggle-menu-\(look)-menu-open")
            } else {
                XCTFail("no Page Menu button (\(look))")
            }
            app.terminate()
        }
    }

    @MainActor
    func testNavbarVariant() {
        for dark in [true, false] {
            let look = dark ? "dark" : "light"
            let app = launch("navbar", dark: dark)
            settle(2.5)
            let button = app.buttons["terminalChat.variant.navbar"]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "no Chat button (\(look))")
            keep("toggle-navbar-\(look)-page")
            if button.exists {
                button.tap()
                settle(1.2)
                keep("toggle-navbar-\(look)-chat-face")
            }
            app.terminate()
        }
    }

    @MainActor
    func testGestureVariant() {
        for dark in [true, false] {
            let look = dark ? "dark" : "light"
            let app = launch("gesture", dark: dark)
            settle(1.5)
            XCTAssertTrue(app.staticTexts["terminalChat.variant.hint"].exists || app.otherElements["terminalChat.variant.hint"].exists
                || app.staticTexts["Swipe in from the right edge for Chat"].exists, "no hint (\(look))")
            keep("toggle-gesture-\(look)-hint")
            settle(5)
            keep("toggle-gesture-\(look)-page")
            let window = app.windows.firstMatch
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.45))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.45))
            start.press(forDuration: 0.05, thenDragTo: end)
            settle(1.2)
            keep("toggle-gesture-\(look)-chat-face")
            app.terminate()
        }
    }
}
