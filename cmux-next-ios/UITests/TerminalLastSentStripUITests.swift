import CoreGraphics
import XCTest

/// Leo, 2026-11-23: "i want to be able to click (tap) the top bit of the
/// terminal in phone to jump to that last sent bit. making it clickable would
/// be good cuz then i can properly use the phone to examine stuff", and
/// "making the jump to bottom be more clickable and having that click not also
/// register as me somehow tapping into that chat box of the terminal".
///
/// On a workspace's zsh tab with the mock session: send `cargo build` from the
/// composer, scroll away from it, tap the strip at the top, land on its row
/// (marked for a moment). Jump to bottom: a bigger target, and neither its tap
/// nor a second tap where it was focuses the terminal or the composer.
final class TerminalLastSentStripUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTapTopStripJumpsToLastSentLine() throws {
        let app = launch()
        send(app, "cargo build")
        let strip = app.buttons["terminal.lastSentStrip"]
        // The build log may push the prompt above the page already; else scroll away from it.
        if !strip.waitForExistence(timeout: 3) {
            XCTAssertTrue(scroll(app, up: true, until: strip), "away from the sent line: the top strip shows\n\(app.debugDescription)")
        }
        XCTAssertTrue(strip.label.contains("cargo build"), "the strip shows the sent line: \(strip.label)")
        let window = app.windows.firstMatch.frame
        XCTAssertLessThan(strip.frame.minY, window.height * 0.2, "the strip is the top bit of the terminal: \(strip.frame)")
        XCTAssertGreaterThanOrEqual(strip.frame.height, 44, "a 44 pt target at least: \(strip.frame)")
        attach(app, "strip-shown")

        strip.tap()
        Thread.sleep(forTimeInterval: 0.15)
        attach(app, "strip-gliding")
        XCTAssertTrue(strip.waitForNonExistence(timeout: 5), "landed on the sent line: the strip hides")
        let mark = app.descendants(matching: .any)["terminal.lastSentHighlight"]
        XCTAssertTrue(mark.waitForExistence(timeout: 2), "the landed row is marked\n\(app.debugDescription)")
        XCTAssertGreaterThan(mark.frame.height, 4, "the mark is a row: \(mark.frame)")
        XCTAssertLessThan(mark.frame.minY, window.height * 0.35, "the sent line lands near the top: \(mark.frame)")
        XCTAssertGreaterThan(mark.frame.minY, strip.frame.minY - 60, "under the status bar: \(mark.frame)")
        attach(app, "landed-on-sent-line")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "the strip's tap is not a tap into the terminal")
    }

    @MainActor
    func testJumpToBottomTapNeverFocusesComposerOrTerminal() throws {
        let app = launch()
        let jump = app.buttons["terminal.jumpToBottom"]
        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(scroll(app, up: true, until: jump), "scrolled up: Jump to bottom shows\n\(app.debugDescription)")
        XCTAssertGreaterThanOrEqual(jump.frame.height, 60, "a bigger target than the 56 pt before: \(jump.frame)")
        let spot = jump.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        attach(app, "pill-before-tap")
        spot.tap()
        // A second tap where the pill was, as a person does when the first felt missed.
        spot.tap()
        XCTAssertTrue(jump.waitForNonExistence(timeout: 5), "the tap went to the bottom")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(app.keyboards.firstMatch.exists, "no keyboard: neither tap went into the terminal or the composer")
        XCTAssertNotEqual(field.value(forKey: "hasKeyboardFocus") as? Bool, true, "the composer did not take the focus")
        attach(app, "after-double-tap")

        // A near miss just above the pill is not a tap into the terminal either.
        XCTAssertTrue(scroll(app, up: true, until: jump), "scrolled up again")
        jump.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: -8)).tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(app.keyboards.firstMatch.exists, "a near miss above the pill shows no keyboard")
        XCTAssertNotEqual(field.value(forKey: "hasKeyboardFocus") as? Bool, true, "a near miss does not focus the composer")
    }

    /// Leo, 2026-11-23: "it seems like y'all have added an additional row of
    /// blanking? ... bring it back down to where it was". With the pill
    /// shown, the page's rows still draw beside it, down to the key row: no
    /// blank band the pill's height above the key row.
    @MainActor
    func testJumpToBottomTakesNoRowOfThePage() throws {
        let app = launch()
        send(app, "cargo build")
        let jump = app.buttons["terminal.jumpToBottom"]
        XCTAssertTrue(scroll(app, up: true, until: jump), "scrolled up: Jump to bottom shows\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 0.5)
        let shot = app.screenshot()
        attach(app, "pill-over-rows")
        let window = app.windows.firstMatch.frame
        let visible = Self.visiblePill(in: jump.frame)
        // Left of the pill, over the band its target covers: the rows there are drawn.
        let band = CGRect(x: window.minX + 2, y: jump.frame.minY - window.minY, width: visible.minX - window.minX - 8, height: jump.frame.height)
        let lit = try Self.brightPixels(shot, in: band, scale: CGFloat(try XCTUnwrap(shot.image.cgImage).height) / window.height)
        XCTAssertGreaterThan(lit, 20, "rows draw beside the pill (\(lit) lit pixels in \(band)): no blank row for Jump to bottom")
    }

    /// Leo, 2026-11-23: "theres also these weird dead zones in the jump to
    /// bottom in terminal". Every part of the drawn pill takes the tap: its
    /// four corners (3 pt in) and its middle each go to the bottom.
    @MainActor
    func testEveryPartOfTheDrawnPillJumps() throws {
        let app = launch()
        let jump = app.buttons["terminal.jumpToBottom"]
        let origin = app.coordinate(withNormalizedOffset: .zero)
        XCTAssertTrue(scroll(app, up: true, until: jump), "scrolled up: Jump to bottom shows")
        let pill = Self.visiblePill(in: jump.frame).insetBy(dx: 3, dy: 3)
        let spots = [("top left", CGPoint(x: pill.minX, y: pill.minY)), ("top right", CGPoint(x: pill.maxX, y: pill.minY)),
                     ("middle", CGPoint(x: pill.midX, y: pill.midY)),
                     ("bottom left", CGPoint(x: pill.minX, y: pill.maxY)), ("bottom right", CGPoint(x: pill.maxX, y: pill.maxY))]
        for (name, spot) in spots {
            if !jump.exists { XCTAssertTrue(scroll(app, up: true, until: jump), "scrolled up again for the \(name)") }
            origin.withOffset(CGVector(dx: spot.x, dy: spot.y)).tap()
            XCTAssertTrue(jump.waitForNonExistence(timeout: 4), "a tap on the pill's \(name) (\(spot)) went to the bottom: no dead zone")
            Thread.sleep(forTimeInterval: 0.7)
            XCTAssertFalse(app.keyboards.firstMatch.exists, "the \(name) tap showed no keyboard")
        }
    }

    // MARK: Helpers

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "ws-terminal-idle"]
        app.launch()
        XCTAssertTrue(app.textViews["terminal.composer.field"].waitForExistence(timeout: 20), "composer field\n\(app.debugDescription)")
        return app
    }

    @MainActor
    private func send(_ app: XCUIApplication, _ text: String) {
        let field = app.textViews["terminal.composer.field"]
        field.tap()
        field.typeText(text)
        app.buttons["terminal.composer.send"].tap()
        if app.keyboards.firstMatch.waitForExistence(timeout: 2) {
            app.descendants(matching: .any)["terminal.key.keyboard"].tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "the keyboard went down")
        }
        // The build log runs for a few seconds.
        Thread.sleep(forTimeInterval: 4)
    }

    @MainActor
    private func scroll(_ app: XCUIApplication, up: Bool, until target: XCUIElement) -> Bool {
        let (from, to): (CGFloat, CGFloat) = up ? (0.3, 0.7) : (0.7, 0.3)
        for _ in 0..<12 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)))
            if target.waitForExistence(timeout: 1) { return true }
        }
        return false
    }

    /// The pill as drawn inside its tap target (`TerminalJumpToBottomRow`:
    /// 44 pt each side, 28 pt tall, 8 pt above the target's bottom).
    private static func visiblePill(in target: CGRect) -> CGRect {
        CGRect(x: target.minX + 44, y: target.maxY - 8 - 28, width: target.width - 88, height: 28)
    }

    /// Pixels well above the terminal's black in `rect` (points).
    @MainActor
    private static func brightPixels(_ shot: XCUIScreenshot, in rect: CGRect, scale: CGFloat) throws -> Int {
        let image = try XCTUnwrap(shot.image.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var lit = 0
        for y in Int(rect.minY * scale)..<min(height, Int(rect.maxY * scale)) {
            for x in max(0, Int(rect.minX * scale))..<min(width, Int(rect.maxX * scale)) where pixels[y * width + x] > 110 {
                lit += 1
            }
        }
        return lit
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
