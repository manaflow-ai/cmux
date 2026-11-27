import AppKit
@testable import CmuxNextTerminal
import Testing

/// NIGHTLY capture 8a8630f01b864f2724297967 typed into the saved chat snapshot in all eight chat rounds,
/// 222–297 ms before the live page installed its input watch. No round reported a composer echo.
@MainActor @Suite(.serialized) struct LaunchTypeProbeTests {
    @Test func savedSnapshotDoesNotConsumeTheLiveChatProbe() async throws {
        _ = NSApplication.shared
        var listener: (@Sendable (String) -> Void)?
        var marks: [String] = []
        LaunchTypeProbe.armChat(environment: ["CMUX_NEXT_LAUNCH_TYPE_PROBE_CHAT": "1"],
                                listen: { listener = $0 }, mark: { marks.append($0) })
        let hear = try #require(listener)
        hear("agent_pane.painted") // inert saved copy, before the composer exists
        hear("agent_pane.newtab_painted")
        for _ in 0..<20 { await Task.yield() }
        #expect(marks.isEmpty)

        hear("agent_pane.page_painted")
        for _ in 0..<50 where marks.isEmpty { await Task.yield() }
        // A headless test has no key window; either outcome proves the live page triggered the attempt.
        let attempts = marks.filter { $0 == "chat.probe_key_typed" || $0 == "chat.probe_no_key_window" }
        #expect(attempts.count == 1)
        let firstAttempt = marks
        hear("agent_pane.page_painted")
        hear("agent_pane.painted")
        for _ in 0..<20 { await Task.yield() }
        #expect(marks == firstAttempt, "later paints must not type again")
    }

    @Test func ordinaryLaunchDoesNotInstallAChatProbe() {
        var installed = false
        LaunchTypeProbe.armChat(environment: [:], listen: { _ in installed = true }, mark: { _ in })
        #expect(!installed)
    }
}
