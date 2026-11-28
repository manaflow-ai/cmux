import XCTest

/// Leo, 2026-11-23: "stop playing the ... slow ... animation when new lines are there in the
/// composer ... We can very easily just have this be one good motion and feeling nigh instant."
/// A line the agent chat's draft gains or loses moves the composer and the transcript above it
/// together on `ComposerLineMotion` (150 ms), not the stack's 0.35 s spring that left the newest
/// turn sliding up after the composer for about half a second.
///
/// The app reports each settled stack motion on the DEBUG `chat.stackMotion` element
/// (`-cmux-mobile-motion-probe`): its kind and the time from the stack's first changed frame
/// to the transcript's spring completing.
final class ComposerLineMotionUITests: XCTestCase {
    /// Each step's probe reading, attached as `line-motion-settled.txt` (a UI test's print never
    /// reaches the step's artifact; an attachment does).
    @MainActor private var readings: [String] = []

    /// A 150 ms critically damped spring settles in about 1.1 x its length on the screen
    /// (under half a point left) and UIKit calls its completion a little later; 0.35 s took
    /// about 520 ms. 300 ms holds the first and fails the second on any simulator.
    static let settledBudgetMs = 300

    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testANewLineMovesComposerAndTranscriptInOneFastMotion() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "kbd-chat",
                                "-cmux-mobile-motion-probe"]
        app.launch()
        defer { app.terminate() }

        let field = app.textViews["chat.composer.field"]
        if !field.waitForExistence(timeout: 30) { app.buttons["agentChat.composer.collapsed"].firstMatch.tap() }
        XCTAssertTrue(field.waitForExistence(timeout: 10), "chat composer field\n\(app.debugDescription)")
        if !app.keyboards.firstMatch.exists { field.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the keyboard comes up")
        field.typeText("one")
        let oneLine = field.frame

        let probe = app.descendants(matching: .any)["chat.stackMotion"]
        // Grow: three new lines, one at a time.
        for step in 1...3 {
            field.typeText("\nline \(step)")
            assertLineMotion(probe, "growing to \(step + 1) lines")
        }
        XCTAssertGreaterThan(field.frame.height, oneLine.height + 20, "the composer grew")
        attach(app, "grown-4-lines")
        // Shrink: delete the last line.
        for _ in 0..<"\nline 3".count { field.typeText(XCUIKeyboardKey.delete.rawValue) }
        assertLineMotion(probe, "shrinking to 3 lines")
        attach(app, "shrunk-3-lines")
        attachText("line-motion-settled", readings.joined(separator: "\n"))
    }

    @MainActor
    private func assertLineMotion(_ probe: XCUIElement, _ when: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "\(when): the app reported no stack motion (chat.stackMotion)",
                      file: file, line: line)
        let value = probe.value as? String ?? ""
        readings.append("\(when): \(value)")
        let fields = Dictionary(uniqueKeysWithValues: value.split(separator: " ").compactMap { pair -> (String, String)? in
            let parts = pair.split(separator: "=", maxSplits: 1)
            return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
        })
        XCTAssertEqual(fields["kind"], "line", "\(when): the stack moved on its line motion (\(value))", file: file, line: line)
        let settled = Int(fields["settled_ms"] ?? "") ?? .max
        XCTAssertLessThanOrEqual(settled, Self.settledBudgetMs,
                                 "\(when): composer and transcript settled in \(settled) ms (\(value))", file: file, line: line)
    }

    @MainActor
    private func attachText(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// The gallery behind `ComposerLineMotion.defaultSeconds`: the same three-line grow and one-line
/// shrink at each candidate length (`-cmux-mobile-line-motion-ms`), 0 (no motion) through 350
/// (the old stack spring), with a screenshot mid-motion and the settled time per step attached as
/// `line-motion-gallery` (`LINEMOTION ms=N step=... settled_ms=N` per line). Run on demand with `video`:
///   cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA --arg test \
///     --arg ui=ComposerLineMotionGalleryUITests --arg video --artifact artifacts/ios-sim/evidence.zip
final class ComposerLineMotionGalleryUITests: XCTestCase {
    @MainActor
    func testVariants() throws {
        XCUIDevice.shared.orientation = .portrait
        var lines: [String] = []
        defer {
            let table = XCTAttachment(string: lines.joined(separator: "\n"))
            table.name = "line-motion-gallery"
            table.lifetime = .keepAlways
            add(table)
        }
        for ms in [0, 100, 150, 200, 350] {
            let app = XCUIApplication()
            app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
            app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "kbd-chat",
                                    "-cmux-mobile-motion-probe", "-cmux-mobile-line-motion-ms", String(ms)]
            app.launch()
            let field = app.textViews["chat.composer.field"]
            if !field.waitForExistence(timeout: 30) { app.buttons["agentChat.composer.collapsed"].firstMatch.tap() }
            guard field.waitForExistence(timeout: 10) else { XCTFail("no composer at \(ms) ms"); app.terminate(); continue }
            if !app.keyboards.firstMatch.exists { field.tap() }
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 10)
            field.typeText("one")
            let probe = app.descendants(matching: .any)["chat.stackMotion"]
            for step in 1...3 {
                field.typeText("\nline \(step)")
                let value = probe.waitForExistence(timeout: 5) ? (probe.value as? String ?? "") : "none"
                lines.append("LINEMOTION ms=\(ms) step=grow\(step) \(value)")
            }
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "line-motion-\(ms)ms-4-lines"
            shot.lifetime = .keepAlways
            add(shot)
            for _ in 0..<"\nline 3".count { field.typeText(XCUIKeyboardKey.delete.rawValue) }
            let value = probe.waitForExistence(timeout: 5) ? (probe.value as? String ?? "") : "none"
            lines.append("LINEMOTION ms=\(ms) step=shrink \(value)")
            app.terminate()
        }
    }
}
