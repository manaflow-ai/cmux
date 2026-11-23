import XCTest

/// At the bottom of an agent transcript, a short scroll up and back down glides onto the newest turn without a
/// jump. Leo, iPhone, 2026-11-23: "ios, bottom of the agent transcript, i scroll a bit up then down. it jumps at
/// the bottom. that has existed for way too fucking long as a bug."
///
/// The app's transcript trace (`-cmux-mobile-kbd-trace`) follows the row in the middle of the screen on every
/// display frame while the transcript moves on its own (the glide after the release and its bounce), and counts
/// the frames where its speed changed by more than a glide can (`debug.transcript-glide`, `GlideMeter`). Each
/// round drags up a little, holds, then flings back down into the bottom; once with the keyboard down and once
/// with it up.
final class AgentBottomScrollJumpUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testScrollUpThenDownAtBottomGlidesWithoutJump() {
        let app = launch()
        defer { app.terminate() }
        flingRounds(app, label: "keyboard down")
        assertNoJump(app, "keyboard down")
    }

    @MainActor
    func testScrollUpThenDownAtBottomWithKeyboardUpGlidesWithoutJump() {
        let app = launch()
        defer { app.terminate() }
        let field = app.textViews["chat.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the composer field\n\(app.debugDescription)")
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the keyboard is up")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        flingRounds(app, label: "keyboard up", from: 0.25, upTo: 0.48)
        XCTAssertTrue(app.keyboards.firstMatch.exists, "the keyboard stayed up through the scrolls")
        assertNoJump(app, "keyboard up")
    }

    @MainActor
    private func launch() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "disclosure-chat", "-cmux-mobile-kbd-trace"]
        app.launch()
        XCTAssertTrue(app.navigationBars.buttons["More"].firstMatch.waitForExistence(timeout: 30),
                      "the pushed agent chat opens\n\(app.debugDescription)")
        XCTAssertTrue(app.otherElements["debug.transcript-glide"].firstMatch.waitForExistence(timeout: 10)
                      || app.staticTexts["debug.transcript-glide"].firstMatch.waitForExistence(timeout: 5),
                      "the transcript glide probe (-cmux-mobile-kbd-trace)")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        return app
    }

    /// Four rounds at the bottom: a short drag up (released at rest, then with a little momentum), then a fling
    /// back down into the bottom, released at speed so the glide meets the end of the transcript.
    @MainActor
    private func flingRounds(_ app: XCUIApplication, label: String, from top: CGFloat = 0.5, upTo flingEnd: CGFloat = 0.75) {
        let x: CGFloat = 0.5
        for round in 1...4 {
            // Up a little: the finger moves down 12% of the screen.
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: top))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: top + 0.12))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: XCUIGestureVelocity(round.isMultiple(of: 2) ? 1200 : 400),
                        thenHoldForDuration: round.isMultiple(of: 2) ? 0 : 0.2)
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            // Back down: the finger flings up, released moving.
            let down = app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: flingEnd))
            let downEnd = app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: flingEnd - 0.3))
            down.press(forDuration: 0.05, thenDragTo: downEnd, withVelocity: XCUIGestureVelocity(round <= 2 ? 1500 : 3000),
                       thenHoldForDuration: 0)
            RunLoop.current.run(until: Date().addingTimeInterval(1.6))
            attach(app, "\(label) round \(round)")
        }
    }

    @MainActor
    private func assertNoJump(_ app: XCUIApplication, _ label: String) {
        let probe = app.descendants(matching: .any)["debug.transcript-glide"].firstMatch
        let line = probe.value as? String ?? ""
        print("transcript-glide \(label): \(line)")
        XCTContext.runActivity(named: "glide (\(label)): \(line)") { _ in }
        let values = Dictionary(line.split(separator: " ").compactMap { pair -> (String, String)? in
            let kv = pair.split(separator: "=", maxSplits: 1)
            return kv.count == 2 ? (String(kv[0]), String(kv[1])) : nil
        }, uniquingKeysWith: { _, last in last })
        let frames = values["frames"].flatMap { Int($0) } ?? 0
        XCTAssertGreaterThan(frames, 30, "the probe saw the transcript glide (\(line))")
        XCTAssertEqual(values["jumps"].flatMap { Int($0) }, 0,
                       "\(label): the transcript jumped while it glided: largest speed change \(values["largest"] ?? "?") pt in a frame; t:before>after \(values["log"] ?? "?")")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
