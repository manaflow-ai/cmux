import XCTest

/// Typing into a terminal while an agent CLI streams (user report 2026-11-18: in cmux NEXT
/// iOS, typing into a terminal running Claude Code sometimes feels like keyboard lag).
///
/// The flood bench's agent workload (`TerminalFloodBench`, `-CmuxMobileFloodBenchMode agent`,
/// DEBUG): the real terminal screen, `DaemonClient` and `DaemonTerminalSession` attached to a
/// fake Mac that draws an agent CLI the way Claude Code does (its live area erased and redrawn
/// 30 times a second, the cursor parked in its input box) and echoes each key as a redraw with
/// the key in the box. The terminal has the keyboard; keys go through the surface's
/// `insertText`, as the software keyboard types them, 8 a second. Prints one `TYPING_BENCH`
/// line of JSON: per phase (idle, while it streams, after), each key's main-thread time,
/// key-to-echo latency (the key to the first frame presented with its echo), main-queue
/// latency, and, while it streams, the display link's frame intervals and the screen's
/// main-thread work per frame by signpost.
final class TerminalTypingWhileStreamingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    /// The terminal has the keyboard, as when a person types: the software keyboard and UIKit's
    /// text system are in the loop for each key.
    @MainActor
    func testTypingWhileAnAgentStreams() throws {
        try run(name: "focused", extra: ["-CmuxMobileFrameLog"])
    }

    /// The same keys without the keyboard: what UIKit's text system adds is the difference.
    @MainActor
    func testTypingWithoutTheKeyboard() throws {
        try run(name: "unfocused", extra: ["-CmuxMobileFloodBenchNoFocus", "-CmuxMobileFrameLog"])
    }

    /// The keyboard, no frame log: what the log's writes add is the difference.
    @MainActor
    func testTypingWithoutTheFrameLog() throws {
        try run(name: "focused-nolog", extra: [])
    }

    /// The flood bench's own byte-rate workload under this test runner, for a run that draws nothing.
    @MainActor
    func testRateWorkloadUnderTheTestRunner() throws {
        try run(name: "rate", extra: [], mode: "rate", checks: false)
    }

    /// Whether this test process launched the bench once already: the first launch on a fresh
    /// simulator draws nothing for its first seconds (``AgentCLIHybridBenchUITests``).
    @MainActor private static var warmedUp = false

    @MainActor
    private func run(name: String, extra: [String], mode: String = "agent", checks: Bool = true) throws {
        if !Self.warmedUp {
            Self.warmedUp = true
            let warm = XCUIApplication()
            warm.launchArguments += ["-CmuxMobileFloodBench", "-CmuxMobileFloodBenchSeconds", "1"]
            warm.launch()
            _ = warm.staticTexts["flood-bench.result"].waitForExistence(timeout: 120)
            warm.terminate()
        }
        let app = XCUIApplication()
        app.launchArguments += [
            "-CmuxMobileFloodBench", "-CmuxMobileFloodBenchMode", mode,
            "-CmuxMobileFloodBenchSeconds", "10",
        ] + extra
        app.launch()
        // Attach, 2 s settle, 3 s idle, then the stream: a shot in the middle of it.
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "the agent streams")], timeout: 10)
        attach(app, "typing-while-streaming-\(name)")
        let result = app.staticTexts["flood-bench.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 120), "no bench result")
        print("TYPING_BENCH \(name) \(result.label)")
        let summary = XCTAttachment(string: result.label)
        summary.name = "typing-bench-result-\(name)"
        summary.lifetime = .keepAlways
        add(summary)
        attach(app, "after-stream-\(name)")
        let flood = try XCTUnwrap(Self.phase("flood", in: result.label), "no flood phase in \(result.label)")
        guard checks else { return app.terminate() }
        // Every key was echoed and drawn: none waits past the run.
        XCTAssertGreaterThan(flood["keyCount"] as? Int ?? 0, 40, "keys typed while streaming")
        XCTAssertGreaterThan(flood["echoCount"] as? Int ?? 0, 40, "echoes drawn while streaming")
        // The lag (2026-11-18): with the keyboard, each key cost about 11 ms of main thread
        // while the agent streamed (UIKit re-read the whole document after every insert);
        // without it, 0.2 ms.
        if !extra.contains("-CmuxMobileFloodBenchNoFocus") {
            let p50 = flood["keyMainP50ms"] as? Double ?? .infinity
            XCTAssertLessThan(p50, 1.5, "main-thread ms of a typed key while the agent streams, p50")
        }
        app.terminate()
    }

    private static func phase(_ name: String, in label: String) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(label.utf8)) as? [String: Any] else { return nil }
        return object[name] as? [String: Any]
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
