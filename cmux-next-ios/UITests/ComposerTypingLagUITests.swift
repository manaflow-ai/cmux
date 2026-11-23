import XCTest

/// Typing into a long terminal composer draft after two pictures were attached
/// and removed, in the app's Low Power path (Leo, 2026-11-23: "ios keyboard
/// typing lag gets to multi second im currently in low power mode typing in the
/// composer in the tui interface and i attached two pictures then removed them
/// and it is a long text thing"; ask-59e410c353).
///
/// Each test opens the zsh tab with N characters of prose in the composer and
/// two photos attached (`ws-terminal-composer`, `CMUX_MOBILE_DEMO_COMPOSER=chars:N`),
/// removes both photos with their badges, then types 44 keys at the end of the
/// draft. The app's trace (`InputLatencyTrace`) reports per key:
/// - `terminal.composer.field_key_commit`: key to its frame committed (ms), the
///   app's own work for the key;
/// - `terminal.composer.field_key_frame`: key to the next frame presented (ms),
///   which adds the wait for vsync (up to 16.7 ms at 60 Hz);
/// - `terminal.composer.field_key_layout_units`: UTF-16 units laid out to
///   measure the field's height for the key.
///
/// The gate: commit p95 under 16 ms, and the text laid out per key bounded by
/// the field's size (it holds 14 lines), not the draft's length: the cost of a
/// key is the same for 500, 5,000 and 20,000 characters. A phone in Low Power
/// Mode runs at a fraction of the simulator Mac's speed, so a per-key cost that
/// grows with the draft is the failure even where the Mac hides it.
///
///     cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA \
///       --arg test --arg ui=ComposerTypingLagUITests --artifact artifacts/ios-sim/evidence.zip
final class ComposerTypingLagUITests: XCTestCase {
    static let field = "terminal.composer.field"
    /// Text laid out per key may cover the field's 14 lines and some slack, never the draft.
    static let maxLayoutUnitsPerKey = 4_096.0
    /// SwiftUI asks a field's size a few times per pass (several widths); a key is one pass.
    static let maxSizeQuestionsPerKey = 8.0
    static let keys = "the quick brown fox jumps over the lazy dog "

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor func testTyping5000CharactersAfterAttachments() throws { try typing(chars: 5_000) }
    @MainActor func testTyping500CharactersAfterAttachments() throws { try typing(chars: 500) }
    @MainActor func testTyping20000CharactersAfterAttachments() throws { try typing(chars: 20_000) }
    /// Controls for Leo's trigger: no photos attached and removed; Low Power path off.
    @MainActor func testTyping5000CharactersNoAttachments() throws { try typing(chars: 5_000, attachments: false) }
    @MainActor func testTyping5000CharactersNotLowPower() throws { try typing(chars: 5_000, lowPower: false) }
    /// The same flows with base's measure (`-cmux-mobile-composer-measure-whole`, which runs
    /// base's code path: the whole draft through the view's own sizeThatFits, one answer
    /// kept): the before rows, reported, not asserted.
    @MainActor func testBefore5000Characters() throws { try typing(chars: 5_000, wholeDraft: true) }
    @MainActor func testBefore500Characters() throws { try typing(chars: 500, wholeDraft: true) }
    @MainActor func testBefore20000Characters() throws { try typing(chars: 20_000, wholeDraft: true) }
    @MainActor func testBefore5000CharactersNoAttachments() throws { try typing(chars: 5_000, wholeDraft: true, attachments: false) }
    @MainActor func testBefore5000CharactersNotLowPower() throws { try typing(chars: 5_000, wholeDraft: true, lowPower: false) }

    @MainActor
    private func typing(chars: Int, wholeDraft: Bool = false, attachments: Bool = true, lowPower: Bool = true) throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_INPUT_LATENCY"] = "1"
        app.launchEnvironment["CMUX_MOBILE_DEMO_COMPOSER"] = attachments ? "chars:\(chars)" : "chars:\(chars):bare"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "ws-terminal-composer",
                                "-cmux-mobile-term-no-intro"]
        if lowPower { app.launchArguments.append("-cmux-mobile-low-power") }
        if wholeDraft { app.launchArguments.append("-cmux-mobile-composer-measure-whole") }
        app.launch()
        let field = app.textViews[Self.field]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "the terminal composer\n\(app.debugDescription)")
        // Two pictures attached, then removed (each with its badge).
        for name in attachments ? ["Photo 1.png", "Photo 2.png"] : [] {
            let remove = app.buttons["Remove \(name)"]
            XCTAssertTrue(remove.waitForExistence(timeout: 15), "the remove badge of \(name)\n\(app.debugDescription)")
            // By its point: XCUITest calls the badge not hittable (it pokes out of the
            // strip, over the thumbnail's corner), yet a finger on its x removes the photo.
            remove.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let gone = NSPredicate(format: "exists == false")
            XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: gone, evaluatedWith: remove)], timeout: 10), .completed,
                           "\(name) removed by its badge\n\(app.debugDescription)")
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        }
        XCTAssertFalse(app.buttons["Remove Photo 1.png"].exists || app.buttons["Remove Photo 2.png"].exists, "both photos removed")
        if !app.keyboards.firstMatch.exists { field.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the keyboard\n\(app.debugDescription)")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let resizesBefore = stats(summary(app), "terminal_resize_sent")["n"] ?? 0
        let relayoutsBefore = stats(summary(app), "terminal_composer_relayout")["n"] ?? 0
        app.typeText(Self.keys)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        let board = summary(app)
        // A keystroke sends the Mac no resize, and relays out the page only when the line count changes.
        let resizes = (stats(board, "terminal_resize_sent")["n"] ?? 0) - resizesBefore
        let relayouts = (stats(board, "terminal_composer_relayout")["n"] ?? 0) - relayoutsBefore
        let line = #"TYPINGLAG {"chars":\#(chars),"before":\#(wholeDraft),"attachments":\#(attachments),"lowPower":\#(lowPower),"resizes_while_typing":\#(Int(resizes)),"relayouts_while_typing":\#(Int(relayouts)),"summary":\#(app.staticTexts["debug.input-latency"].label)}"#
        print(line)
        let name = "\(chars)\(wholeDraft ? "-before" : "")\(attachments ? "" : "-bare")\(lowPower ? "" : "-nolpm")"
        let attachment = XCTAttachment(string: line)
        attachment.name = "typing-lag-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let file = InputLatencyUITests.traceFile(), let text = try? String(contentsOf: file, encoding: .utf8) {
            let log = XCTAttachment(string: text)
            log.name = "typing-lag-\(name).jsonl"
            log.lifetime = .keepAlways
            add(log)
            for row in text.split(separator: "\n").filter({ $0.contains(#""type":"hitch""#) }).prefix(6) {
                print("TYPINGLAG_HITCH \(chars) \(row.prefix(4_000))")
            }
        }

        guard !wholeDraft else { return }
        XCTAssertEqual(resizes, 0, "resizes sent to the Mac while typing: \(line)")
        // Gated on what the app does per key, measured in the app: its main thread's CPU from
        // the key to the frame committed, the composer bodies built and the size questions
        // asked. Wall times (key to commit, key to next frame) are reported, not gated: on a
        // shared simulator host they carry the host's load and XCUITest's key queue.
        let cpu = stats(board, "\(Self.field)_key_cpu")
        let units = stats(board, "\(Self.field)_key_layout_units")
        let bodies = stats(board, "\(Self.field)_key_composer_body")
        let questions = stats(board, "\(Self.field)_key_size_questions")
        XCTAssertGreaterThanOrEqual(cpu["n"] ?? 0, 30, "keys measured: \(line)")
        XCTAssertLessThan(cpu["p95"] ?? .infinity, 16, "main-thread CPU from key to frame committed, p95 (ms), \(chars) characters: \(line)")
        XCTAssertLessThanOrEqual(units["max"] ?? .infinity, Self.maxLayoutUnitsPerKey,
                                 "text laid out to measure the field for one key, \(chars) characters: \(line)")
        XCTAssertLessThanOrEqual(bodies["p95"] ?? 0, 1, "composer bodies built per key: \(line)")
        XCTAssertLessThanOrEqual(questions["p95"] ?? 0, Self.maxSizeQuestionsPerKey, "field size questions per key: \(line)")
    }

    @MainActor
    private func summary(_ app: XCUIApplication) -> [String: Any] {
        let probe = app.staticTexts["debug.input-latency"]
        guard probe.waitForExistence(timeout: 5), let data = probe.label.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    private func stats(_ summary: [String: Any], _ kind: String) -> [String: Double] {
        guard let entry = summary[kind] as? [String: Any] else { return [:] }
        return entry.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }
}
