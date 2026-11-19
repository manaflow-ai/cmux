import XCTest

/// User report 2026-11-16 (iPhone, video): "it turns pale in the composer
/// after 3 lines". A composer keeps its colours as its draft grows: the glass
/// at one line and at five lines reads the same. Samples the glass inside the
/// field's leading edge, a few points above its bottom (the bottom edge stays
/// put as the field grows, so both samples sit over the same backdrop), in the
/// terminal composer and the agent chat's.
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
        // The field sits 14 pt inside its glass container; 7 pt in from the
        // container's edge and 10 pt above its bottom is inside its 20 pt corner.
        try compare(app, field, "terminal", dx: -7, dy: -10)
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
        // The field sits 16 pt inside the card's glass.
        try compare(app, field, "chat", dx: -8, dy: -4)
    }

    /// The glass colour at one line, then at three and five lines: each is
    /// within a few levels of the first.
    @MainActor
    private func compare(_ app: XCUIApplication, _ field: XCUIElement, _ name: String, dx: CGFloat, dy: CGFloat) throws {
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the keyboard comes up")
        field.typeText("one")
        let one = try sample(app, field, "\(name)-glass-1-line", dx: dx, dy: dy)
        for count in 2...5 {
            field.typeText("\n\(Self.line) \(count)")
            guard count == 3 || count == 5 else { continue }
            let grown = try sample(app, field, "\(name)-glass-\(count)-lines", dx: dx, dy: dy)
            print("composer-glass \(name) lines=1 rgb=\(one) lines=\(count) rgb=\(grown)")
            XCTAssertTrue(Self.near(one, grown), "\(name): the glass at \(count) lines \(grown) reads as at one line \(one)")
        }
    }

    /// Waits for the glass to settle, attaches a screenshot and returns the
    /// mean colour of a 5x5 pt patch at the field's bottom-leading corner
    /// offset by (dx, dy).
    @MainActor
    private func sample(_ app: XCUIApplication, _ field: XCUIElement, _ name: String, dx: CGFloat, dy: CGFloat) throws -> RGB {
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "settle")], timeout: 1.5)
        let frame = field.frame
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let window = app.windows.firstMatch.frame
        let point = CGPoint(x: frame.minX + dx, y: frame.maxY + dy)
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
