import XCTest

/// User report 2026-11-12 (iPhone): a multi-line draft in the terminal's
/// "Message" composer ran below the rounded field, caret line outside it, and
/// "it go down when i y". Every composer grows upward from a fixed bottom edge
/// a line at a time, then keeps its height and scrolls inside. Screenshots at
/// one, three, six and nine lines in the terminal composer and the agent
/// chat's composer (before/after evidence for the fix).
final class ComposerGrowUpUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    private static let line = "this is a longer message for the agent"

    @MainActor
    func testTerminalComposerGrowsUpAndScrolls() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "ws-terminal-idle"]
        app.launch()
        defer { app.terminate() }
        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "composer field\n\(app.debugDescription)")
        field.tap()
        try grow(app, field, "terminal")
    }

    @MainActor
    func testChatComposerGrowsUpAndScrolls() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "kbd-chat"]
        app.launch()
        defer { app.terminate() }
        let field = app.textViews["chat.composer.field"]
        if !field.waitForExistence(timeout: 30) { app.buttons["Reply to Claude"].firstMatch.tap() }
        XCTAssertTrue(field.waitForExistence(timeout: 10), "chat composer field\n\(app.debugDescription)")
        if !app.keyboards.firstMatch.exists { field.tap() }
        try grow(app, field, "chat")
    }

    /// Types nine lines; the field's bottom edge stays put while it grows, and
    /// past its maximum the height stops changing.
    @MainActor
    private func grow(_ app: XCUIApplication, _ field: XCUIElement, _ name: String) throws {
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the keyboard comes up")
        field.typeText("one")
        let oneLine = field.frame
        attach(app, "\(name)-1-line")
        var frames: [Int: CGRect] = [1: oneLine]
        assertInsideBox(app, field, name, lines: 1)
        for count in 2...9 {
            field.typeText("\n\(Self.line)")
            frames[count] = field.frame
            assertInsideBox(app, field, name, lines: count)
            if [3, 6, 9].contains(count) { attach(app, "\(name)-\(count)-lines") }
        }
        // A keystroke on the last line, as in the report ("when i y").
        field.typeText("y")
        let afterKey = field.frame
        attach(app, "\(name)-9-lines-plus-y")
        for (count, frame) in frames.sorted(by: { $0.key < $1.key }) {
            print("composer-grow \(name) lines=\(count) frame=\(frame)")
            XCTAssertEqual(frame.maxY, oneLine.maxY, accuracy: 1, "\(name): the bottom edge stays put at \(count) lines")
        }
        let nine = try XCTUnwrap(frames[9]), six = try XCTUnwrap(frames[6]), three = try XCTUnwrap(frames[3])
        XCTAssertGreaterThan(three.height, oneLine.height, "\(name): grows with its lines")
        XCTAssertEqual(nine.height, six.height, accuracy: 1, "\(name): stops growing at six lines and scrolls")
        XCTAssertEqual(afterKey.minY, nine.minY, accuracy: 0.5, "\(name): a key on the same line moves nothing")
        XCTAssertEqual(afterKey.height, nine.height, accuracy: 0.5, "\(name): a key on the same line keeps the height")
    }

    /// User report 2026-11-13 (iPhone, terminal composer): the last line and
    /// the send circle drew below the rounded glass field, and stayed there.
    /// The text and the send circle stay inside the terminal's field.
    @MainActor
    private func assertInsideBox(_ app: XCUIApplication, _ field: XCUIElement, _ name: String, lines: Int) {
        guard name == "terminal" else { return }
        let box = app.otherElements["terminal.composer.box"].firstMatch
        XCTAssertTrue(box.waitForExistence(timeout: 5), "the composer's field box\n\(app.debugDescription)")
        let outer = box.frame.insetBy(dx: -0.5, dy: -0.5)
        let send = app.buttons["terminal.composer.send"].firstMatch.frame
        print("composer-box \(name) lines=\(lines) box=\(box.frame) text=\(field.frame) send=\(send)")
        XCTAssertTrue(outer.contains(field.frame), "\(name): the text \(field.frame) stays inside its field \(box.frame) at \(lines) lines")
        XCTAssertTrue(outer.contains(send), "\(name): the send circle \(send) stays inside its field \(box.frame) at \(lines) lines")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
