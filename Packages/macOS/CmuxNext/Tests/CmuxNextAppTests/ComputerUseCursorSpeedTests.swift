import Foundation
import Testing
@testable import CmuxNextApp
@testable import CmuxNextComputerUse

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
        let argv = ComputerUseHelperDaemon.arguments(socketPath: "/tmp/cua.sock", ownerPID: 42, motion: true)
        let glide = try value(of: "--glide-ms", in: argv)
        // 0 is the helper's speed-based default: a long move then takes seconds.
        #expect(glide >= 50, "a glide under 50 ms is not visible, and 0 is the slow speed-based default")
        #expect(glide <= 200, "a glide over 200 ms makes each click slow")
    }

    @Test func theHelperWaitsOnlyBrieflyAfterAClick() throws {
        let argv = ComputerUseHelperDaemon.arguments(socketPath: "/tmp/cua.sock", ownerPID: 42, motion: true)
        let dwell = try value(of: "--dwell-ms", in: argv)
        #expect(dwell >= 0)
        #expect(dwell <= 50, "the 80 ms default dwell is added to every click of a batch")
    }

    /// The pinned helper (cmux-cua 0.8.12) takes the motion flags but does not
    /// list `serve.motion`; an older one, or one with no readable version, gets none.
    @Test func theMotionCapabilityComesFromTheListOrAKnownVersion() throws {
        let parse = { (json: String) in try #require(CuaHelperManifestReader.parse(Data(json.utf8))) }
        #expect(try parse(#"{"binary_version":"0.8.12","capabilities":["serve.owner-pid"]}"#).contains("serve.motion"))
        #expect(try parse(#"{"binary_version":"0.9.0"}"#).contains("serve.motion"))
        #expect(try parse(#"{"binary_version":"1.0.0-rc.1"}"#).contains("serve.motion"))
        #expect(try !parse(#"{"binary_version":"0.8.11","capabilities":["serve.owner-pid"]}"#).contains("serve.motion"))
        #expect(try !parse(#"{"binary_version":"0.8","capabilities":[]}"#).contains("serve.motion"))
        #expect(try !parse(#"{"binary_version":"dev"}"#).contains("serve.motion"))
        #expect(try parse(#"{"capabilities":["serve.motion"]}"#).contains("serve.motion"))
        #expect(CuaHelperManifestReader.parse(Data("not json".utf8)) == nil)
    }

    /// A helper whose manifest does not list `serve.motion` may not know the
    /// flags and would exit at launch: it gets none and keeps its own motion.
    @Test func aHelperWithoutTheMotionCapabilityGetsNoMotionFlags() {
        let argv = ComputerUseHelperDaemon.arguments(socketPath: "/tmp/cua.sock", ownerPID: 42, motion: false)
        #expect(!argv.contains("--glide-ms"), "\(argv)")
        #expect(!argv.contains("--dwell-ms"), "\(argv)")
    }
}
