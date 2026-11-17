import XCTest

/// Leo, 2026-11-17: "the gui is fine on phone other than the jitter on load sometimes and layout
/// shift and the lack of themeing/background inheriting (these need to be improved)". Opens the
/// shipping app's offline DEBUG agent chat (`-cmux-mobile-demo disclosure-chat`) under a Mac's
/// appearance frame (`-cmux-mobile-mac-appearance`, ChatLookFixture.swift) and reads the chat's
/// ground from the screenshot, in the left margin beside the transcript:
/// - `default` (a Mac at its defaults: hostd sends no `chat`): the stock black or white ground;
/// - `mocha` (a dark theme the person chose): the theme's #1e1e2e;
/// - `mocha-wallpaper` (with a picture behind the window): the picture under #1e1e2e at 0.45, so
///   neither the stock ground nor the flat theme color;
/// - `solarized-bubbles` (a light theme): the theme's #fdf6e3 on a phone in dark mode.
final class ChatMacLookUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTheAgentChatTakesTheMacsThemeAndPicture() throws {
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.appearance = .dark

        let stock = try ground(fixture: "default")
        XCTAssertTrue(Self.near(stock, (0, 0, 0)) || Self.near(stock, (255, 255, 255)),
                      "a Mac at its defaults leaves the stock chat ground, got \(stock)")

        let mocha = try ground(fixture: "mocha")
        XCTAssertTrue(Self.near(mocha, (0x1e, 0x1e, 0x2e)), "the chat's ground is the Mac theme's background, got \(mocha)")

        let picture = try ground(fixture: "mocha-wallpaper", sampleY: 0.30)
        XCTAssertFalse(Self.near(picture, (0, 0, 0)), "the Mac's picture shows behind the chat, got \(picture)")
        XCTAssertFalse(Self.near(picture, (0x1e, 0x1e, 0x2e)), "the picture shows through the theme's tint, got \(picture)")

        let solarized = try ground(fixture: "solarized-bubbles")
        XCTAssertTrue(Self.near(solarized, (0xfd, 0xf6, 0xe3)), "a light Mac theme is the chat's ground on a dark phone, got \(solarized)")

        // Back to a Mac at its defaults, so later tests start from the stock chat.
        _ = try ground(fixture: "default")
    }

    /// Launches the chat under `fixture`, attaches a screenshot, and returns the color at the left
    /// margin (2% of the width) at `sampleY` of the height.
    @MainActor
    private func ground(fixture: String, sampleY: CGFloat = 0.5) throws -> (Int, Int, Int) {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "disclosure-chat",
                                "-cmux-mobile-mac-appearance", fixture]
        app.launch()
        defer { app.terminate() }
        let more = app.navigationBars.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 30), "the pushed agent chat opens\n\(app.debugDescription)")
        // The picture decodes off the main actor; give it its frame.
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "settle")], timeout: 1.5)
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "chat-mac-look-\(fixture)"
        attachment.lifetime = .keepAlways
        add(attachment)
        return try XCTUnwrap(Self.pixel(shot.image, x: 0.02, y: sampleY), "the screenshot has pixels")
    }

    private static func pixel(_ image: UIImage, x: CGFloat, y: CGFloat) -> (Int, Int, Int)? {
        guard let cg = image.cgImage else { return nil }
        let px = min(cg.width - 1, max(0, Int(CGFloat(cg.width) * x)))
        let py = min(cg.height - 1, max(0, Int(CGFloat(cg.height) * y)))
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: -px, y: -(cg.height - 1 - py), width: cg.width, height: cg.height))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    private static func near(_ a: (Int, Int, Int), _ b: (Int, Int, Int), tolerance: Int = 10) -> Bool {
        abs(a.0 - b.0) <= tolerance && abs(a.1 - b.1) <= tolerance && abs(a.2 - b.2) <= tolerance
    }
}
