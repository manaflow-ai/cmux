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

    @MainActor
    private func run(name: String, extra: [String]) throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-CmuxMobileFloodBench", "-CmuxMobileFloodBenchMode", "agent",
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
        // Every key was echoed and drawn: none waits past the run.
        XCTAssertGreaterThan(flood["keyCount"] as? Int ?? 0, 40, "keys typed while streaming")
        XCTAssertGreaterThan(flood["echoCount"] as? Int ?? 0, 40, "echoes drawn while streaming")
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
