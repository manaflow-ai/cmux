import XCTest

/// Prototype picker for the welcome's top section (`WelcomeHero.swift`,
/// round 4): every direction is reachable from the picker, draws its own
/// wordmark, and leaves the sign-in rows in place; a pinned launch hides the
/// picker. Goes away with the prototype once a direction is picked.
final class WelcomeHeroPrototypeUITests: XCTestCase {
    private let directions = ["lockup", "site", "bloom", "morph", "glide", "decode", "shimmer", "raster", "draft", "keys", "circuit", "tube", "glide450", "glide600", "glide900"]

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
        // Replay re-mounts the current direction (the last one tapped); it stays on screen.
        let last = try XCTUnwrap(directions.last)
        app.buttons["Replay"].tap()
        XCTAssertTrue(element(app, id: "welcome.wordmark.\(last)").waitForExistence(timeout: 5), "\(last): wordmark missing after Replay")
    }

    @MainActor
    func testPinnedDirectionHidesThePicker() throws {
        let app = launch(arguments: ["-cmux-mobile-welcome-hero", "morph"])
        defer { app.terminate() }
        XCTAssertTrue(element(app, id: "welcome.wordmark.morph").waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["welcome.hero.raster"].exists, "a pinned launch must not show the picker")
        XCTAssertTrue(app.buttons["Continue with Google"].exists)
    }

    /// Glide at each cursor speed (300, 450, 600 and 900 ms per blink)
    /// plays its whole reveal on a pinned launch, in light then in dark: the
    /// cursor blinks in the middle, the word types out centered, then slides
    /// right as the cursor flies home. The step's recording is the evidence
    /// for the speeds; each launch waits the same time, so the clips line up.
    @MainActor
    func testGlideRevealsAtEveryBlinkSpeedInLightAndDark() throws {
        for dark in [false, true] {
            for name in ["glide", "glide450", "glide600", "glide900"] {
                let app = launch(arguments: ["-cmux-mobile-welcome-hero", name] + appearance(dark))
                XCTAssertTrue(element(app, id: "welcome.wordmark.\(name)").waitForExistence(timeout: 20), "\(name): wordmark missing")
                XCTAssertFalse(app.buttons["welcome.hero.morph"].exists, "a pinned launch must not show the picker")
                // The slowest reveal is 3.8 s; every launch waits the same.
                _ = app.staticTexts["__never__"].waitForExistence(timeout: 4.5)
                XCTAssertTrue(element(app, label: "Your Macs, in your pocket").exists, "\(name): tagline missing")
                XCTAssertTrue(app.buttons["Continue with Google"].exists)
                capture("\(name)-\(dark ? "dark" : "light")")
                app.terminate()
            }
        }
    }

    /// A direction picked while the launch intro is still finishing plays its
    /// whole reveal. The intro's end used to pause the shared animation clock
    /// mid-reveal, freezing the new direction where it stood (sometimes on a
    /// blank frame, the cursor off before any letter). Glide 900, picked about
    /// 1.5 s in, runs 3.8 s, past the intro's end; 6 s later its wordmark must
    /// be the settled lockup: ink from the canvas's left edge (the chevron) to
    /// its right edge (the x).
    @MainActor
    func testADirectionPickedDuringTheIntroPlaysToTheEnd() throws {
        let app = launch()
        defer { app.terminate() }
        let item = app.buttons["welcome.hero.glide900"]
        XCTAssertTrue(item.waitForExistence(timeout: 20))
        _ = app.staticTexts["__never__"].waitForExistence(timeout: 1.5)
        item.tap()
        let mark = element(app, id: "welcome.wordmark.glide900")
        XCTAssertTrue(mark.waitForExistence(timeout: 5))
        _ = app.staticTexts["__never__"].waitForExistence(timeout: 6)
        capture("picked-during-intro")
        // The canvas is the wordmark element less its 40 pt side padding.
        let canvas = mark.frame.insetBy(dx: 40, dy: 0)
        let ink = try XCTUnwrap(inkSpan(app, in: mark.frame), "the wordmark draws nothing: the reveal froze on a blank frame")
        XCTAssertLessThan(ink.lowerBound, canvas.minX + 8, "the reveal froze before the chevron reached the left (ink \(ink), canvas \(canvas))")
        XCTAssertGreaterThan(ink.upperBound, canvas.maxX - 8, "the reveal froze before the word reached the right (ink \(ink), canvas \(canvas))")
    }

    /// The x range, in points, of what is drawn inside `frame` on screen (any
    /// pixel clearly unlike the frame's corner, the background), or nil when
    /// nothing is drawn there.
    @MainActor
    private func inkSpan(_ app: XCUIApplication, in frame: CGRect) -> ClosedRange<CGFloat>? {
        guard let image = XCUIScreen.main.screenshot().image.cgImage else { return nil }
        let width = image.width, height = image.height
        let scale = CGFloat(width) / app.windows.firstMatch.frame.width
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        func level(_ x: Int, _ y: Int) -> Int {
            let i = (y * width + x) * 4
            return Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])
        }
        let x0 = max(0, Int(frame.minX * scale)), x1 = min(width - 1, Int(frame.maxX * scale))
        let y0 = max(0, Int(frame.minY * scale)), y1 = min(height - 1, Int(frame.maxY * scale))
        guard x0 < x1, y0 < y1 else { return nil }
        let background = level(x0 + 2, y0 + 2)
        var first: Int?, last: Int?
        for x in x0...x1 {
            var marked = 0
            for y in stride(from: y0, through: y1, by: 2) where abs(level(x, y) - background) > 90 { marked += 1 }
            if marked >= 2 { first = first ?? x; last = x }
        }
        guard let first, let last else { return nil }
        return CGFloat(first) / scale...CGFloat(last) / scale
    }

    /// The sign-in rows answer a held finger the way system glass does: held,
    /// a row stays lit and stretches toward the finger as it drags; dragged
    /// off and released, nothing is sent and the welcome stays. In light and
    /// dark; the step's recording is the evidence for the motion.
    @MainActor
    func testSignInRowsHoldAndFollowADrag() throws {
        for dark in [false, true] {
            let app = launch(arguments: ["-cmux-mobile-welcome-hero", "morph"] + appearance(dark))
            XCTAssertTrue(element(app, id: "welcome.wordmark.morph").waitForExistence(timeout: 20))
            let github = app.buttons["Continue with GitHub"]
            XCTAssertTrue(github.waitForExistence(timeout: 5))
            // Let the reveal settle so the recording shows only the press.
            _ = app.staticTexts["__never__"].waitForExistence(timeout: 2.5)
            let start = github.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let away = github.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 4.5))
            start.press(forDuration: 1.5, thenDragTo: away, withVelocity: .slow, thenHoldForDuration: 1.0)
            XCTAssertTrue(element(app, id: "welcome.wordmark.morph").exists, "dragging off a row must not sign in")
            XCTAssertTrue(github.exists)
            capture("held-drag-\(dark ? "dark" : "light")")
            app.terminate()
        }
    }

    /// The app's own appearance setting (Settings > Appearance), which it
    /// applies to every window: the simulator's appearance, set from a UI
    /// test, does not reach the app on the fleet.
    private func appearance(_ dark: Bool) -> [String] {
        ["-cmuxMobile.settings.appearance", dark ? "dark" : "light"]
    }

    private func launch(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-cmux-mobile-no-restore",
                                "-cmuxMobile.prototype.welcomeHero.v4", "1"]
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
