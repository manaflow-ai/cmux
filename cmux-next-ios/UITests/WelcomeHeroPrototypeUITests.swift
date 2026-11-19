import XCTest

/// Prototype picker for the welcome's top section (`WelcomeHero.swift`):
/// every variant is reachable from the picker, draws its own headline, and
/// leaves the sign-in rows in place; a pinned launch hides the picker.
/// Goes away with the prototype once a variant is picked.
final class WelcomeHeroPrototypeUITests: XCTestCase {
    private let headlines: [(name: String, text: String)] = [
        ("now", "Your Macs, in your pocket."),
        ("terminal", "Your agents, on your phone."),
        ("statement", "Your Macs. In your pocket."),
        ("mark", "Your Macs, in your pocket."),
        ("feed", "Know the moment an agent needs you."),
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPickerShowsEveryVariantWithTheSignInRows() throws {
        let app = launch()
        defer { app.terminate() }
        for (name, text) in headlines {
            let item = app.buttons["welcome.hero.\(name)"]
            XCTAssertTrue(item.waitForExistence(timeout: 20), "picker item \(name) missing")
            item.tap()
            let headline = element(app, text)
            XCTAssertTrue(headline.waitForExistence(timeout: 5), "\(name): headline '\(text)' missing")
            XCTAssertTrue(app.buttons["Continue with Google"].exists, "\(name): sign-in rows missing")
            XCTAssertTrue(app.buttons["Continue with email"].exists, "\(name): email row missing")
            // Let the entrance play out for the recording, then keep a still.
            _ = app.staticTexts["__never__"].waitForExistence(timeout: 2)
            capture("welcome-hero-\(name)")
        }
        // Replay re-mounts the current variant; it stays on screen.
        app.buttons["Replay"].tap()
        XCTAssertTrue(element(app, "Know the moment an agent needs you.").waitForExistence(timeout: 5))
    }

    @MainActor
    func testPinnedVariantHidesThePicker() throws {
        let app = launch(arguments: ["-cmux-mobile-welcome-hero", "statement"])
        defer { app.terminate() }
        XCTAssertTrue(element(app, "Your Macs. In your pocket.").waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["welcome.hero.now"].exists, "a pinned launch must not show the picker")
    }

    private func launch(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-cmux-mobile-no-restore",
                                "-cmuxMobile.prototype.welcomeHero", "0"]
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_CLEAR_AUTH"] = "1"
        app.launchArguments += arguments
        app.launch()
        return app
    }

    /// Any element with this accessibility label (a header may be a group).
    private func element(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
