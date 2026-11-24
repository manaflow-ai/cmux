import XCTest

/// The signed-out welcome (`WelcomeGlide`): the cmux wordmark plays its whole
/// reveal and settles centered, in light and in dark, above the sign-in rows,
/// and the rows answer a held, dragging finger the way system glass does.
final class WelcomeGlideUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The reveal plays to the end and settles on the lockup, light and dark:
    /// read from the screenshot, ink runs from the canvas's left edge (the
    /// chevron) to its right edge (the x), with the tagline and the sign-in
    /// rows below. The recording shows each reveal whole.
    @MainActor
    func testTheWordmarkRevealsAndSettlesInLightAndDark() throws {
        for dark in [false, true] {
            let app = launch(arguments: appearance(dark))
            let mark = element(app, id: "welcome.wordmark")
            XCTAssertTrue(mark.waitForExistence(timeout: 20), "wordmark missing")
            // The canvas is the wordmark element less its 40 pt side padding.
            let canvas = mark.frame.insetBy(dx: 40, dy: 0)
            func settled(_ ink: ClosedRange<CGFloat>?) -> Bool {
                guard let ink else { return false }
                return ink.lowerBound < canvas.minX + 8 && ink.upperBound > canvas.maxX - 8
            }
            // The reveal is 2.4 s plus the launch hold, but its clock advances
            // with rendered frames, so a loaded simulator plays it slower than
            // wall time: wait for the settled lockup, up to 12 s.
            var span = inkSpan(app, in: mark.frame)
            let deadline = Date().addingTimeInterval(12)
            while !settled(span), Date() < deadline {
                _ = app.staticTexts["__never__"].waitForExistence(timeout: 0.5)
                span = inkSpan(app, in: mark.frame)
            }
            capture("welcome-\(dark ? "dark" : "light")")
            XCTAssertTrue(element(app, label: "Your Macs, in your pocket").exists, "tagline missing")
            XCTAssertTrue(app.buttons["Continue with Google"].exists, "sign-in rows missing")
            XCTAssertTrue(app.buttons["Continue with email"].exists, "email row missing")
            let ink = try XCTUnwrap(span, "the wordmark draws nothing")
            XCTAssertLessThan(ink.lowerBound, canvas.minX + 8, "the chevron is not home (ink \(ink), canvas \(canvas))")
            XCTAssertGreaterThan(ink.upperBound, canvas.maxX - 8, "the word is not home (ink \(ink), canvas \(canvas))")
            app.terminate()
        }
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
            let app = launch(arguments: appearance(dark))
            XCTAssertTrue(element(app, id: "welcome.wordmark").waitForExistence(timeout: 20))
            let github = app.buttons["Continue with GitHub"]
            XCTAssertTrue(github.waitForExistence(timeout: 5))
            // Let the reveal settle so the recording shows only the press.
            _ = app.staticTexts["__never__"].waitForExistence(timeout: 2.5)
            let start = github.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let away = github.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 4.5))
            start.press(forDuration: 1.5, thenDragTo: away, withVelocity: .slow, thenHoldForDuration: 1.0)
            XCTAssertTrue(element(app, id: "welcome.wordmark").exists, "dragging off a row must not sign in")
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
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-cmux-mobile-no-restore"]
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
