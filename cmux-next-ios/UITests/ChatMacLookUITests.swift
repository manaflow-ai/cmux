import XCTest

/// The agent chat's ground under a Mac's appearance frame (`-cmux-mobile-mac-appearance`,
/// ChatLookFixture.swift), read from the screenshot in the left margin beside the transcript of the
/// shipping app's offline DEBUG agent chat (`-cmux-mobile-demo disclosure-chat`). For now every
/// background is black (2026-11-25; the options were PR #53342): whatever the Mac shows (its
/// defaults, a dark theme, a picture behind its window, a light theme), the chat on a phone in dark
/// mode sits on black.
final class ChatMacLookUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTheAgentChatStaysOnBlackWhateverTheMacShows() throws {
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.appearance = .dark

        for fixture in ["default", "mocha", "mocha-wallpaper", "solarized-bubbles"] {
            let ground = try ground(fixture: fixture, sampleY: fixture == "mocha-wallpaper" ? 0.30 : 0.5)
            XCTAssertTrue(Self.near(ground, (0, 0, 0)), "the chat's ground is black under \(fixture), got \(ground)")
        }
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
