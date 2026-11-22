import XCTest

/// Typing in a composer never waits on the Mac or its link (Leo, 2026-11-22: "it kinda seems like
/// my ios typing inside the composer on ios is somehow coupled to the mac's cpu or connection?").
///
/// Each test types a message, at a person's pace and ending in an `@` mention, into the mock
/// chat's or mock terminal's composer while the "Mac" streams frames in, with the mock link
/// (`CMUX_MOBILE_MOCK_LINK`, `MockLinkCondition`) healthy, slow (frames held and released in
/// bursts every 600 ms, sends a burst late) or down (disconnected; nothing arrives). From the
/// app's trace (`InputLatencyTrace`, the typing window) it reports per-key main-thread time
/// (`<field>_key_frame`: key to the frame that draws it, p50/p99), main-thread iterations of
/// 8 ms and more while typing, and the work counted while typing:
///
/// - `draft_file_write_main`: draft files written on the main thread (`ComposerDraftStore`);
/// - `mention_scan`: whole-transcript scans for `@` candidates (`MentionIndex`);
/// - `chat_composer_body`: the chat composer's re-renders.
///
/// It asserts that typing does no file I/O on the main thread and that frames streaming in do
/// not re-render the composer or rescan the transcript per frame: the same in every link state.
/// Each test prints `COMPOSERLINK {json}`.
///
/// Run on the fleet:
///     cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA \
///       --arg test --arg ui=ComposerLinkUITests --artifact artifacts/ios-sim/evidence.zip
final class ComposerLinkUITests: XCTestCase {
    /// What is typed: words, then a mention, in chunks a person types between frames.
    static let chunks: [String] = ["the ", "link ", "should ", "never ", "be ", "felt ", "while ", "typing ", "this ", "@"]
        + "Sources/CmuxMobile".map { String($0) }
    static var keys: Int { chunks.reduce(0) { $0 + $1.count } }

    override func setUp() {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor func testChatHealthy() throws { try chat(.healthy) }
    @MainActor func testChatSlow() throws { try chat(.slow) }
    @MainActor func testChatDown() throws { try chat(.down) }
    @MainActor func testTerminalHealthy() throws { try terminal(.healthy) }
    @MainActor func testTerminalSlow() throws { try terminal(.slow) }
    @MainActor func testTerminalDown() throws { try terminal(.down) }

    enum Link: String { case healthy, slow, down }

    // MARK: Flows

    @MainActor
    private func chat(_ link: Link) throws {
        let app = Self.app(link)
        app.launch()
        open(InputLatencyUITests.chatWorkspace, in: app)
        let field = app.textViews["chat.composer.field"]
        let reply = app.buttons["Reply to Claude"].firstMatch
        openChatField(field, reply: reply, app: app)
        // A prompt starts the long streamed answer (CMUX_MOBILE_LIST_STREAM=1); down, it never arrives.
        field.typeText("go")
        let send = app.buttons["Send"].firstMatch
        if send.waitForExistence(timeout: 5), send.isEnabled { send.tap() }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        openChatField(field, reply: reply, app: app)
        type(into: field, link: link, flow: "chat", app: app)
    }

    @MainActor
    private func terminal(_ link: Link) throws {
        let app = Self.app(link)
        app.launch()
        open(InputLatencyUITests.terminalWorkspace, in: app)
        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "the terminal composer\n\(app.debugDescription)")
        field.tap()
        // The shell streams a row every 16 ms meanwhile; down, the command never reaches it.
        field.typeText("stream 100000 16")
        app.buttons["terminal.composer.send"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        type(into: field, link: link, flow: "terminal", app: app)
    }

    @MainActor
    private func type(into field: XCUIElement, link: Link, flow: String, app: XCUIApplication) {
        // The typing window of the setup keys closes; what is counted from here is this typing.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let before = summary(app)
        for chunk in Self.chunks {
            field.typeText(chunk)
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        }
        // The window's tail (0.5 s), then read it.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let after = summary(app)
        let fieldID = flow == "chat" ? "chat.composer.field" : "terminal.composer.field"
        let keyFrame = after["\(fieldID)_key_frame"] as? [String: Any] ?? [:]
        func delta(_ name: String) -> Int { (after[name] as? Int ?? 0) - (before[name] as? Int ?? 0) }
        let result: [String: Any] = [
            "flow": flow, "link": link.rawValue, "keys": Self.keys,
            "key_frame_p50": keyFrame["p50"] ?? 0, "key_frame_p99": keyFrame["p99"] ?? 0, "key_frame_max": keyFrame["max"] ?? 0,
            "typing_hitches_8ms": delta("typing_hitches_8ms"), "typing_iterations_4ms": delta("typing_iterations_4ms"),
            "typing_max_iteration_ms": after["typing_max_iteration_ms"] ?? 0,
            "draft_file_write_main": delta("typing_draft_file_write_main"),
            "mention_scan": delta("typing_mention_scan"),
            "chat_composer_body": delta("typing_chat_composer_body"),
        ]
        let json = (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        print("COMPOSERLINK \(json)")
        let attachment = XCTAttachment(string: "COMPOSERLINK \(json)\nsummary: \(after)")
        attachment.name = "composer-link-\(flow)-\(link.rawValue)"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertEqual(delta("typing_draft_file_write_main"), 0, "typing wrote the draft file on the main thread: \(json)")
        // Rescans follow the transcript at most about once a second, not per streamed frame.
        XCTAssertLessThanOrEqual(delta("typing_mention_scan"), 6, "the @ candidates rescanned the transcript per frame: \(json)")
        // A re-render per key (and its echo) at most; never one per frame streamed in.
        XCTAssertLessThanOrEqual(delta("typing_chat_composer_body"), Self.keys * 3, "frames re-rendered the composer: \(json)")
    }

    // MARK: Helpers

    @MainActor
    static func app(_ link: Link) -> XCUIApplication {
        let app = InputLatencyUITests.listApp()
        app.launchEnvironment["CMUX_MOBILE_MOCK_LINK"] = link.rawValue
        app.launchEnvironment["CMUX_MOBILE_LIST_STREAM"] = "1"
        return app
    }

    @MainActor
    private func openChatField(_ field: XCUIElement, reply: XCUIElement, app: XCUIApplication) {
        // A chat that opens on a question card, or a running turn, folds the composer into
        // "Reply to Claude" (InputLatencyUITests): tap it until the field opens.
        let deadline = Date().addingTimeInterval(30)
        while !field.exists, Date() < deadline {
            if reply.exists, reply.isHittable { reply.tap() }
            _ = field.waitForExistence(timeout: 1)
        }
        XCTAssertTrue(field.exists, "the chat composer\n\(app.debugDescription)")
        field.tap()
    }

    @MainActor
    private func open(_ id: String, in app: XCUIApplication) {
        let row = app.buttons[id]
        XCTAssertTrue(app.buttons[InputLatencyUITests.chatWorkspace].waitForExistence(timeout: 60), "the stress list\n\(app.debugDescription)")
        for _ in 0 ..< 12 where !(row.exists && row.isHittable) {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(row.exists && row.isHittable, "\(row) in the list\n\(app.debugDescription)")
        row.tap()
    }

    @MainActor
    private func summary(_ app: XCUIApplication) -> [String: Any] {
        let probe = app.staticTexts["debug.input-latency"]
        guard probe.waitForExistence(timeout: 5), let data = probe.label.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}
