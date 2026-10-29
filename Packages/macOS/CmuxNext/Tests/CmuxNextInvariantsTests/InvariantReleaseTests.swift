import CmuxNextInvariants
import Testing

/// Release has no check code path (plans/cmux-next/invariants-DESIGN.md section 2.1): only the ids, keys, subjects
/// and the probe compile there, and the probe holds nothing, so its calls are empty and inlined. Run in a Release
/// test build (`swift test -c release`), this file is the compile-time proof: it names no registry type there. The
/// symbol check of the shipped binary is scripts/cmux-next/check-invariants-release-symbols.sh.
@MainActor
struct InvariantReleaseTests {
    @Test func theProbeHoldsNothingInRelease() {
        #if DEBUG || CMUX_BENCH_HOOKS
        #expect(MemoryLayout<InvariantProbe>.size > 0, "a Debug or bench probe holds its registry")
        #else
        #expect(MemoryLayout<InvariantProbe>.size == 0, "a Release probe must hold nothing: its calls compile to nothing")
        #endif
    }

    @Test func aProbeCallCompilesInEveryBuild() {
        let probe = InvariantProbe()
        probe.touch(.tabs, .pane("p1"))
        probe.fail("M1", .app, "never built in Release")
        #expect(InvariantID(stringLiteral: "W10").rawValue == "W10")
    }
}
