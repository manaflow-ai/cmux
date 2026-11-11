@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// `agent.chat.perf` (`cmux app chat perf`) measures the person's own Release or Nightly app, so it
/// is registered outside every `#if` (a `debug.` method or a DEBUG-only registration never reaches
/// that build), and it takes a capture of 1 to 60 whole seconds.
@Suite struct AgentChatPerfControlTests {
    @Test func theMethodIsRegisteredInEveryBuild() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/CmuxNextApp")
        let text = try String(contentsOf: sources.appendingPathComponent("Control/AppControl.swift"), encoding: .utf8)
        var depth = 0
        var registrations = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("#if ") { depth += 1 } else if line == "#endif" { depth -= 1 }
            guard line.contains("AgentChatPerfControl.controlMethod") else { continue }
            registrations += 1
            #expect(depth == 0, "AppControl.swift registers agent.chat.perf inside an #if: \(line)")
        }
        #expect(registrations == 1)
        #expect(!AgentChatPerfControl.method.hasPrefix("debug."))
    }

    @Test func secondsAreWholeAndFromOneToSixty() throws {
        #expect(try AgentChatPerfControl.seconds([:]) == AgentChatPerfControl.defaultSeconds)
        #expect(try AgentChatPerfControl.seconds(["seconds": 1]) == 1)
        #expect(try AgentChatPerfControl.seconds(["seconds": 60]) == 60)
        for bad: JSONValue in [0, 61, .number(2.5), "5", -1] {
            #expect(throws: ControlError.self) { try AgentChatPerfControl.seconds(["seconds": bad]) }
        }
    }
}
