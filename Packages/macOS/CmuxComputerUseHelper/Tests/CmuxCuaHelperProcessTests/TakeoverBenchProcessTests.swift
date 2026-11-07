// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

/// The takeover detector on a real window server: `cmux-cua-helper
/// --takeover-bench` (TakeoverBench.swift). It posts only harmless input, so
/// it runs only on a step routed to a display worker:
///   cmux-ci run --class light --display --script scripts/ci/package-test-lane.sh --ref SHA \
///     --arg=suite --arg=Packages/macOS/CmuxComputerUseHelper --arg=TakeoverBenchProcessTests
/// It prints one CUA-TAKEOVER line with the bench's JSON.
@Suite struct TakeoverBenchProcessTests {
    static var displayRouted: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["CMUX_CI_DISPLAY_ROUTED"] == "1" || env["CMUX_TEST_REQUIRE_GUI"] == "1"
    }

    @Test(.enabled(if: Self.displayRouted, "needs a display: posts input on the console session"),
          .timeLimit(.minutes(3)))
    func agentInputNeverTakesOverAndThePersonIsSeen() throws {
        let executable = try #require(HelperSocketProcessTests.helperExecutable(), "the built cmux-cua-helper")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--takeover-bench", "--events", "300"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        print("CUA-TAKEOVER \(text)")
        try #require(process.terminationStatus == 0, "the bench could not start its tap: \(text)")
        let report = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let agent = try #require(report["agent"] as? [String: Any])
        let person = try #require(report["person"] as? [String: Any])
        #expect(agent["false_takeovers"] as? Int == 0, "\(text)")
        #expect((person["seen"] as? Int ?? 0) > 0, "\(text)")
        #expect((person["takeovers"] as? Int ?? 0) >= 1, "\(text)")
    }
}
