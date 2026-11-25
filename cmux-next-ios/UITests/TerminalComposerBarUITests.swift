import XCTest

/// Aziz, 2026-11-23, on the terminal's composer bar: "theres a missing
/// shortcut in the composer scroll here, must bring back and fix. the
/// horizontal scroll's scroll edge effect also feels off and manually done
/// [...] someone also changed the composer bar input field and + button to not
/// have a border and not look as glassy anymore, undo that."
///
/// Every key of the key row is on screen somewhere along the scroll, Paste
/// (a system `UIPasteControl`, which draws nothing when it judges itself
/// covered) draws its glyph, and a screenshot of each state is attached: dark
/// and light, keyboard down and up, the row at its start, middle and end, the
/// field empty and filled.
final class TerminalComposerBarUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testComposerBarDark() throws {
        try walk(look: "dark", appearance: .dark)
    }

    @MainActor
    func testComposerBarLight() throws {
        try walk(look: "light", appearance: .light)
    }

    /// The keys the row's scroller must show, by accessibility identifier
    /// (`KeyBarKey.identifier`), every one of the default layout.
    private static let scrollerKeys = [
        "control", "alt", "command", "shift", "paste", "tab", "escape", "return", "ctrl-c", "ctrl-d",
        "up", "down", "left", "right", "launcher-claude", "launcher-codex", "launcher-ollama", "ctrl-l",
        "ctrl-z", "home", "end", "page-up", "page-down", "wide", "zoom-out", "zoom-in", "hide-chrome",
    ]

    @MainActor
    private func walk(look: String, appearance: XCUIDevice.Appearance) throws {
        XCUIDevice.shared.appearance = appearance
        defer { XCUIDevice.shared.appearance = .dark }
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "ws-terminal-idle"]
        app.launch()
        defer { app.terminate() }

        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "composer field\n\(app.debugDescription)")
        let keyboardKey = app.buttons["terminal.key.keyboard"]
        XCTAssertTrue(keyboardKey.waitForExistence(timeout: 10), "the key row's keyboard key")
        Thread.sleep(forTimeInterval: 1.5)

        // Keyboard down, empty field: the row at its start, middle and end.
        var seen = Set<String>()
        try rowStates(app, keyRowY: keyboardKey.frame.midY, name: "\(look)-kbd-down-empty", seen: &seen)
        let missing = Self.scrollerKeys.filter { !seen.contains($0) }
        XCTAssertTrue(missing.isEmpty, "\(look): keys never on screen along the row: \(missing)")

        // Keyboard up, empty.
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the keyboard comes up")
        Thread.sleep(forTimeInterval: 1)
        try rowStates(app, keyRowY: keyboardKey.frame.midY, name: "\(look)-kbd-up-empty", seen: &seen)

        // Keyboard up, filled.
        field.typeText("git status --short && ls -la ~/Development")
        Thread.sleep(forTimeInterval: 0.8)
        try rowStates(app, keyRowY: keyboardKey.frame.midY, name: "\(look)-kbd-up-filled", seen: &seen)

        // Keyboard down, filled: the key row's keyboard key hides it.
        keyboardKey.tap()
        Thread.sleep(forTimeInterval: 1.2)
        try rowStates(app, keyRowY: keyboardKey.frame.midY, name: "\(look)-kbd-down-filled", seen: &seen)
    }

    /// Scrolls the key row back to its start, then shoots start, middle and
    /// end; checks Paste draws at the start and records every key seen.
    @MainActor
    private func rowStates(_ app: XCUIApplication, keyRowY: CGFloat, name: String, seen: inout Set<String>) throws {
        let window = app.windows.firstMatch.frame
        func drag(_ fromX: CGFloat, _ toX: CGFloat) {
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: fromX, dy: keyRowY))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: toX, dy: keyRowY)),
                       withVelocity: .default, thenHoldForDuration: 0.3)
        }
        func record() {
            for key in Self.scrollerKeys {
                let element = app.descendants(matching: .any)["terminal.key.\(key)"]
                if element.exists, element.isHittable, window.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) {
                    seen.insert(key)
                }
            }
        }
        for _ in 0..<4 { drag(window.width * 0.35, window.width * 0.95) }
        Thread.sleep(forTimeInterval: 0.6)
        record()
        shoot(app, "\(name)-start")
        try checkPasteDraws(app, name: "\(name)-start")

        drag(window.width * 0.9, window.width * 0.45)
        Thread.sleep(forTimeInterval: 0.6)
        record()
        shoot(app, "\(name)-middle")

        for _ in 0..<5 { drag(window.width * 0.95, window.width * 0.3) }
        Thread.sleep(forTimeInterval: 0.6)
        record()
        shoot(app, "\(name)-end")
        // Back to the start for the next state.
        for _ in 0..<5 { drag(window.width * 0.35, window.width * 0.95) }
        Thread.sleep(forTimeInterval: 0.4)
    }

    /// Paste draws its glyph: its cap is not one flat color (a blank
    /// `UIPasteControl` is its background alone).
    @MainActor
    private func checkPasteDraws(_ app: XCUIApplication, name: String) throws {
        let paste = app.descendants(matching: .any)["terminal.key.paste"]
        XCTAssertTrue(paste.exists, "\(name): Paste is in the row")
        guard paste.exists, paste.frame.width > 4 else { return }
        let shot = app.screenshot()
        let inner = paste.frame.insetBy(dx: paste.frame.width * 0.2, dy: paste.frame.height * 0.2)
        let spread = try Self.lumaSpread(shot.image, in: inner)
        let numbers = XCTAttachment(string: "paste \(name) frame=\(paste.frame) lumaSpread=\(String(format: "%.1f", spread))")
        numbers.name = "\(name)-paste-numbers"
        numbers.lifetime = .keepAlways
        add(numbers)
        XCTAssertGreaterThan(spread, 40, "\(name): Paste draws its glyph (luma spread \(spread))")
    }

    @MainActor
    private func shoot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Max minus min Rec. 709 luma (0-255) of `rect` (points) in a screenshot.
    private static func lumaSpread(_ image: UIImage, in rect: CGRect) throws -> Double {
        let cg = try XCTUnwrap(image.cgImage)
        let scale = CGFloat(cg.width) / image.size.width
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
        let crop = try XCTUnwrap(cg.cropping(to: pixels))
        let width = crop.width, height = crop.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn)
        var low = 255.0, high = 0.0
        for index in stride(from: 0, to: data.count, by: 4) {
            let luma = 0.2126 * Double(data[index]) + 0.7152 * Double(data[index + 1]) + 0.0722 * Double(data[index + 2])
            low = min(low, luma)
            high = max(high, luma)
        }
        return high - low
    }
}
