import XCTest

/// Prototype picker for the welcome's top section (`WelcomeHero.swift`,
/// round 3): every direction is reachable from the picker, draws its own
/// wordmark, and leaves the sign-in rows in place; a pinned launch hides the
/// picker. Goes away with the prototype once a direction is picked.
final class WelcomeHeroPrototypeUITests: XCTestCase {
    private let directions = ["raster", "draft", "keys", "circuit", "tube"]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPickerShowsEveryDirectionWithTheSignInRows() throws {
        let app = launch()
        defer { app.terminate() }
        for name in directions {
            let item = app.buttons["welcome.hero.\(name)"]
            XCTAssertTrue(item.waitForExistence(timeout: 20), "picker item \(name) missing")
            item.tap()
            XCTAssertTrue(element(app, id: "welcome.wordmark.\(name)").waitForExistence(timeout: 5), "\(name): wordmark missing")
            XCTAssertTrue(element(app, label: "Your Macs, in your pocket").exists, "\(name): tagline missing")
            XCTAssertTrue(app.buttons["Continue with Google"].exists, "\(name): sign-in rows missing")
            XCTAssertTrue(app.buttons["Continue with email"].exists, "\(name): email row missing")
            // Let the entrance play out for the recording, then keep a still.
            _ = app.staticTexts["__never__"].waitForExistence(timeout: 2)
            capture("welcome-hero-\(name)")
        }
        // Replay re-mounts the current direction; it stays on screen.
        app.buttons["Replay"].tap()
        XCTAssertTrue(element(app, id: "welcome.wordmark.tube").waitForExistence(timeout: 5))
    }

    @MainActor
    func testPinnedDirectionHidesThePicker() throws {
        let app = launch(arguments: ["-cmux-mobile-welcome-hero", "circuit"])
        defer { app.terminate() }
        XCTAssertTrue(element(app, id: "welcome.wordmark.circuit").waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["welcome.hero.raster"].exists, "a pinned launch must not show the picker")
        XCTAssertTrue(app.buttons["Continue with Google"].exists)
    }

    private func launch(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-cmux-mobile-no-restore",
                                "-cmuxMobile.prototype.welcomeHero.v3", "1"]
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_CLEAR_AUTH"] = "1"
        app.launchArguments += arguments
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Any element with this accessibility label.
    private func element(_ app: XCUIApplication, label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
