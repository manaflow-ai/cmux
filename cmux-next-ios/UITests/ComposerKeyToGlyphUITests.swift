import XCTest

/// Composer key to glyph, chat and terminal, under three models of the Mac
/// (`HostLoadSim`, `CMUX_MOBILE_HOST_LOAD`): idle, heavy (a busy Mac's
/// workspace pushes, terminal output and chat status at 20 Hz, with a ten-push
/// backlog once a second) and cut (the link dropped, nothing arriving).
///
/// Each test types 40 single keys into the composer, one at a time, and reads
/// the app's stamps (`ComposerKeyStamp` through `InputLatencyTrace`):
/// `<field>_key_glyph` (key to the display-link present of its frame) and
/// `<field>_view_update` (SwiftUI updates of the field; one per key is the
/// key's own, the rest came from something else). It prints
/// `KEYGLYPH {json}`: flow, load, keys, view updates while typing and the
/// trace's summary.
///
/// Run on the fleet:
///     cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA \
///       --arg test --arg ui=ComposerKeyToGlyphUITests --artifact artifacts/ios-sim/evidence.zip
final class ComposerKeyToGlyphUITests: XCTestCase {
    static let keys = 40
    static let terminalField = "terminal.composer.field"
    static let chatField = "chat.composer.field"

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor func testTerminalIdle() throws { try terminal(load: "idle") }
    @MainActor func testTerminalHeavy() throws { try terminal(load: "heavy") }
    @MainActor func testTerminalCut() throws { try terminal(load: "cut") }
    @MainActor func testChatIdle() throws { try chat(load: "idle") }
    @MainActor func testChatHeavy() throws { try chat(load: "heavy") }
    @MainActor func testChatCut() throws { try chat(load: "cut") }

    // MARK: Flows

    @MainActor
    private func terminal(load: String) throws {
        let app = Self.app(load: load)
        app.launch()
        open(InputLatencyUITests.terminalWorkspace, in: app)
        let field = app.textViews[Self.terminalField]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "the terminal composer\n\(app.debugDescription)")
        field.tap()
        type(into: field, id: Self.terminalField, flow: "terminal", load: load, app: app)
    }

    @MainActor
    private func chat(load: String) throws {
        let app = Self.app(load: load)
        app.launch()
        open(InputLatencyUITests.chatWorkspace, in: app)
        let field = app.textViews[Self.chatField]
        // A chat that opens on a question card folds the composer into "Reply to Claude".
        let reply = app.buttons["Reply to Claude"].firstMatch
        let deadline = Date().addingTimeInterval(30)
        while !field.exists, !reply.exists, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        if !field.exists, reply.exists { reply.tap() }
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the chat composer\n\(app.debugDescription)")
        field.tap()
        type(into: field, id: Self.chatField, flow: "chat", load: load, app: app)
    }

    @MainActor
    private func type(into field: XCUIElement, id: String, flow: String, load: String, app: XCUIApplication) {
        // Let the keyboard settle and the load run a moment before the first key.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let updatesBefore = count(summary(app), "\(id)_view_update")
        let glyphsBefore = count(summary(app), "\(id)_key_glyph")
        let letters = Array("qwertyuiopasdfghjklzxcvbnm")
        for index in 0 ..< Self.keys {
            field.typeText(String(letters[index % letters.count]))
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        _ = waitFor(app, timeout: 10) { self.count($0, "\(id)_key_glyph") >= glyphsBefore + Self.keys }
        let after = summary(app)
        let updates = count(after, "\(id)_view_update") - updatesBefore
        let glyphs = count(after, "\(id)_key_glyph") - glyphsBefore
        let probe = app.staticTexts["debug.input-latency"]
        let line = #"KEYGLYPH {"flow":"\#(flow)","load":"\#(load)","keys":\#(Self.keys),"glyphs":\#(glyphs),"view_updates":\#(updates),"summary":\#(probe.label)}"#
        print(line)
        let attachment = XCTAttachment(string: line)
        attachment.name = "keyglyph-\(flow)-\(load)"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let file = InputLatencyUITests.traceFile(), let text = try? String(contentsOf: file, encoding: .utf8) {
            let log = XCTAttachment(string: text)
            log.name = "keyglyph-\(flow)-\(load).jsonl"
            log.lifetime = .keepAlways
            add(log)
        }
        XCTAssertGreaterThanOrEqual(glyphs, Self.keys / 2, "key-to-glyph samples for \(id)\n\(line)")
    }

    // MARK: Helpers

    @MainActor
    static func app(load: String) -> XCUIApplication {
        let app = InputLatencyUITests.listApp()
        app.launchEnvironment["CMUX_MOBILE_HOST_LOAD"] = load
        return app
    }

    @MainActor
    private func open(_ id: String, in app: XCUIApplication) {
        let row = app.buttons[id]
        XCTAssertTrue(app.buttons[InputLatencyUITests.chatWorkspace].waitForExistence(timeout: 60), "the list\n\(app.debugDescription)")
        for _ in 0 ..< 12 where !(row.exists && row.isHittable) {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(row.exists && row.isHittable, "\(row) in the list\n\(app.debugDescription)")
        row.tap()
    }

    private func count(_ summary: [String: Any], _ kind: String) -> Int {
        (summary[kind] as? [String: Any]).flatMap { $0["n"] as? Int } ?? 0
    }

    @MainActor
    private func summary(_ app: XCUIApplication) -> [String: Any] {
        let probe = app.staticTexts["debug.input-latency"]
        guard probe.exists, let data = probe.label.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    @MainActor
    private func waitFor(_ app: XCUIApplication, timeout: TimeInterval, _ done: ([String: Any]) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if done(summary(app)) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return false
    }
}
