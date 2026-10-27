import Foundation
import Testing
@testable import CmuxNextApp

/// Computer use felt slow: the helper's cursor flew at its speed-based
/// default, so the first click of a run (the cursor crossing to the app on
/// the other display) took 3.3 to 3.6 s and each later click 0.2 to 0.9 s.
/// A short fixed glide keeps the cursor visible and makes every move quick.
struct ComputerUseCursorSpeedTests {
    private func value(of flag: String, in argv: [String]) throws -> Double {
        let at = try #require(argv.firstIndex(of: flag), "the helper must get \(flag): \(argv)")
        let text = try #require(argv.dropFirst(at + 1).first, "\(flag) needs a value: \(argv)")
        return try #require(Double(text), "\(flag) value is not a number: \(text)")
    }

    @Test func theHelperGlidesTheCursorInAShortFixedTime() throws {
        let argv = ComputerUseHelperDaemon.arguments(socketPath: "/tmp/cua.sock", ownerPID: 42)
        let glide = try value(of: "--glide-ms", in: argv)
        // 0 is the helper's speed-based default: a long move then takes seconds.
        #expect(glide >= 50, "a glide under 50 ms is not visible, and 0 is the slow speed-based default")
        #expect(glide <= 200, "a glide over 200 ms makes each click slow")
    }

    @Test func theHelperWaitsOnlyBrieflyAfterAClick() throws {
        let argv = ComputerUseHelperDaemon.arguments(socketPath: "/tmp/cua.sock", ownerPID: 42)
        let dwell = try value(of: "--dwell-ms", in: argv)
        #expect(dwell >= 0)
        #expect(dwell <= 50, "the 80 ms default dwell is added to every click of a batch")
    }
}
