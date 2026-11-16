import XCTest

/// The agent CLI hybrid bench (`AgentCLIHybridBench`, DEBUG): each recorded session (Claude Code,
/// Codex, opencode; `verify/agent-cli-hybrid/`, exported by cmux-tui's
/// `export_sessions_for_the_phone_bench`) replayed into the real terminal screen as PTY bytes
/// and as `agent-cli-frame` cell changes. Prints one `HYBRID_BENCH` line of JSON per run (wire
/// bytes per second, first frame on attach, cell parity with the Mac's screen) and keeps a
/// screenshot of each run's attach and end.
class AgentCLIHybridBenchUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    /// Claude Code and opencode; Codex runs in its own suite (``AgentCLIHybridBenchCodexUITests``),
    /// so a recording of this one shows only these two.
    class var sessions: [String] { ["claude-code-2.1.310", "opencode-1.19.5"] }
    /// How the fake Mac sends each session: today's PTY bytes, then cell changes.
    class var modes: [String] { ["pty", "hybrid"] }

    private func fixture(_ name: String) -> String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("verify/agent-cli-hybrid/\(name).json").path
    }

    @MainActor
    func testReplaysEachSessionAsPTYBytesAndAsCellChanges() throws {
        for name in Self.sessions {
            let path = fixture(name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "missing \(path)")
            for mode in Self.modes {
                let app = XCUIApplication()
                app.launchArguments += [
                    "-CmuxMobileHybridBench", "-CmuxMobileHybridBenchFile", path,
                    "-CmuxMobileHybridBenchMode", mode,
                ]
                app.launch()
                let result = app.staticTexts["hybrid-bench.result"]
                // The attach is drawn within a few seconds; the rest plays at the recorded pace.
                _ = XCTWaiter.wait(for: [XCTestExpectation(description: "the attach is drawn")], timeout: 4)
                attach(app, "\(name)-\(mode)-attach")
                XCTAssertTrue(result.waitForExistence(timeout: 180), "\(name) \(mode): no result")
                print("HYBRID_BENCH \(name) \(mode) \(result.label)")
                let summary = XCTAttachment(string: result.label)
                summary.name = "\(name)-\(mode)-result"
                summary.lifetime = .keepAlways
                add(summary)
                attach(app, "\(name)-\(mode)-end")
                XCTAssertFalse(result.label.contains("\"error\""), result.label)
                app.terminate()
            }
        }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

/// The Codex session of the bench, apart, so the main suite's recording leaves it out.
final class AgentCLIHybridBenchCodexUITests: AgentCLIHybridBenchUITests {
    override class var sessions: [String] { ["codex-0.164.0"] }
}

/// Claude Code and opencode as cell changes only: a short recording of the new path.
final class AgentCLIHybridBenchHybridOnlyUITests: AgentCLIHybridBenchUITests {
    override class var modes: [String] { ["hybrid"] }
}
