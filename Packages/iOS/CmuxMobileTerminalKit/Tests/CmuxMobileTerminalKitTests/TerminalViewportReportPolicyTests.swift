import Testing
import CmuxMobileTerminalKit

@Suite("Terminal viewport report policy")
struct TerminalViewportReportPolicyTests {
    @Test("a pending reassert does not mint another report")
    func coalescesSameCapacityReassert() {
        #expect(!TerminalViewportReportPolicy(
            naturalGridChanged: false,
            shouldReassertNaturalSize: true,
            effectiveMatchesNatural: false,
            viewportReportPending: true
        ).shouldReport)
    }

    @Test("a real capacity change supersedes a pending report")
    func preservesNaturalGridChanges() {
        #expect(TerminalViewportReportPolicy(
            naturalGridChanged: true,
            shouldReassertNaturalSize: true,
            effectiveMatchesNatural: false,
            viewportReportPending: true
        ).shouldReport)
    }

    @Test("a settled mismatch can still reassert")
    func allowsSettledReassert() {
        #expect(TerminalViewportReportPolicy(
            naturalGridChanged: false,
            shouldReassertNaturalSize: true,
            effectiveMatchesNatural: false,
            viewportReportPending: false
        ).shouldReport)
    }
}
