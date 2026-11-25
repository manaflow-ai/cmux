import XCTest

/// User report 2026-11-16 (iPhone, video): "it turns pale in the composer
/// after 3 lines". A composer keeps its colours as its draft grows: the glass
/// at one line and at five lines reads the same. Samples the card's glass on
/// its bottom row, 40 % across: right of the draft's "one" at one line, and
/// the empty glass between + and the trailing controls once the draft wraps
/// above them. The card's bottom edge stays put as it grows
/// (ComposerGrowUpUITests), so every sample sits over the same backdrop. Both
/// composers are the one ComposerCard; the terminal's sets its theme fill,
/// which keeps the shade (Leo, 2026-11-21: "the composer brightening up when
/// you have >3 lines").
final class ComposerGlassColorUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    private static let line = "a longer line for the agent"

    @MainActor
    func testTerminalComposerKeepsItsColorAsItGrows() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "ws-terminal-idle"]
        app.launch()
        defer { app.terminate() }
        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "composer field\n\(app.debugDescription)")
        field.tap()
        try compare(app, field, card: app.descendants(matching: .any)["terminal.composer.card"], "terminal")
    }

    @MainActor
    func testChatComposerKeepsItsColorAsItGrows() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "kbd-chat"]
        app.launch()
        defer { app.terminate() }
        let field = app.textViews["chat.composer.field"]
        if !field.waitForExistence(timeout: 30) { app.buttons["Reply to Claude"].firstMatch.tap() }
        XCTAssertTrue(field.waitForExistence(timeout: 10), "chat composer field\n\(app.debugDescription)")
        if !app.keyboards.firstMatch.exists { field.tap() }
        try compare(app, field, card: app.descendants(matching: .any)["chat.composer.card"], "chat")
    }

    /// The glass colour at one line, then at three and five lines: each is
    /// within a few levels of the first.
    @MainActor
    private func compare(_ app: XCUIApplication, _ field: XCUIElement, card: XCUIElement, _ name: String) throws {
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the keyboard comes up")
        XCTAssertTrue(card.waitForExistence(timeout: 5), "\(name) composer card\n\(app.debugDescription)")
        field.typeText("one")
        let one = try sample(app, card, "\(name)-glass-1-line")
        for count in 2...5 {
            field.typeText("\n\(Self.line) \(count)")
            guard count == 3 || count == 5 else { continue }
            let grown = try sample(app, card, "\(name)-glass-\(count)-lines")
            print("composer-glass \(name) lines=1 rgb=\(one) lines=\(count) rgb=\(grown)")
            XCTAssertTrue(Self.near(one, grown), "\(name): the glass at \(count) lines \(grown) reads as at one line \(one)")
        }
    }

    /// Waits for the glass to settle, attaches a screenshot and returns the
    /// mean colour of a 5x5 pt patch on the card's bottom row (the 48 pt
    /// one-line card's middle, 24 pt above its bottom), 40 % across.
    @MainActor
    private func sample(_ app: XCUIApplication, _ card: XCUIElement, _ name: String) throws -> RGB {
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "settle")], timeout: 1.5)
        let frame = card.frame
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let window = app.windows.firstMatch.frame
        let point = CGPoint(x: frame.minX + frame.width * 0.4, y: frame.maxY - 24)
        return try XCTUnwrap(Self.mean(shot.image, at: point, in: window.size), "the screenshot has pixels")
    }

    struct RGB: CustomStringConvertible {
        let r: Int, g: Int, b: Int
        var description: String { "(\(r), \(g), \(b))" }
    }

    private static func mean(_ image: UIImage, at point: CGPoint, in size: CGSize) -> RGB? {
        guard let cg = image.cgImage, size.width > 0, size.height > 0 else { return nil }
        let scale = CGFloat(cg.width) / size.width
        let side = max(1, Int((5 * scale).rounded()))
        let px = min(cg.width - side, max(0, Int(point.x * scale) - side / 2))
        let py = min(cg.height - side, max(0, Int(point.y * scale) - side / 2))
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &bytes, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: -px, y: -(cg.height - side - py), width: cg.width, height: cg.height))
        var sum = (0, 0, 0)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            sum.0 += Int(bytes[i]); sum.1 += Int(bytes[i + 1]); sum.2 += Int(bytes[i + 2])
        }
        let n = side * side
        return RGB(r: sum.0 / n, g: sum.1 / n, b: sum.2 / n)
    }

    private static func near(_ a: RGB, _ b: RGB, tolerance: Int = 8) -> Bool {
        abs(a.r - b.r) <= tolerance && abs(a.g - b.g) <= tolerance && abs(a.b - b.b) <= tolerance
    }
}
